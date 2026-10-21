import SwiftUI

// Public runtime APIs only. Loopback addresses are fixed; no discovery over LAN,
// inference requests with prompts, auto-loading, model downloads or disk deletion.
enum LocalModelRuntime: String, CaseIterable, Identifiable, Codable {
    case ollama, lmStudio
    var id: String { rawValue }
    var title: String { self == .ollama ? "Ollama" : "LM Studio" }
    var port: Int { self == .ollama ? 11434 : 1234 }
    var listPath: String { self == .ollama ? "/api/ps" : "/api/v1/models" }
    var unloadPath: String { self == .ollama ? "/api/generate" : "/api/v1/models/unload" }
}

struct LoadedLocalModel: Identifiable, Equatable {
    let runtime: LocalModelRuntime
    let name: String
    let instance: String
    let fingerprint: String
    let memoryBytes: Int64?
    let gpuBytes: Int64?
    let quantization: String?
    var id: String { runtime.rawValue + ":" + instance }
}

enum LocalModelError: LocalizedError {
    case invalid, tooLarge, http(Int), changed, token
    var errorDescription: String? {
        switch self {
        case .invalid: "The runtime response was not recognized. No model status was inferred."
        case .tooLarge: "The runtime response exceeded the 1 MB or 256-model limit."
        case .http(let code): code == 401 || code == 403 ? "The runtime requires an API token. Supply its token for this session." : "The runtime returned HTTP \(code). Check its server and API version."
        case .changed: "The reviewed model is no longer loaded with the same identity. Refresh before trying again."
        case .token: "The API token contains unsupported characters."
        }
    }
}

enum LocalModelDecoder {
    static func decode(_ data: Data, runtime: LocalModelRuntime) throws -> [LoadedLocalModel] {
        guard data.count <= 1_048_576 else { throw LocalModelError.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { throw LocalModelError.invalid }
        guard rows.count <= 256 else { throw LocalModelError.tooLarge }
        var models: [LoadedLocalModel] = []
        for row in rows {
            if runtime == .ollama {
                guard let name = row["name"] as? String, !name.isEmpty, name.count <= 512,
                      let digest = row["digest"] as? String, !digest.isEmpty else { throw LocalModelError.invalid }
                let details = row["details"] as? [String: Any]
                models.append(.init(runtime: runtime, name: name, instance: name, fingerprint: digest,
                    memoryBytes: bytes(row["size"]), gpuBytes: bytes(row["size_vram"]), quantization: details?["quantization_level"] as? String))
            } else {
                guard let key = row["key"] as? String, !key.isEmpty,
                      let instances = row["loaded_instances"] as? [[String: Any]] else { throw LocalModelError.invalid }
                for instance in instances {
                    guard let id = instance["id"] as? String, !id.isEmpty, id.count <= 512 else { throw LocalModelError.invalid }
                    // size_bytes describes the model file, not current RAM. Never display it as RAM.
                    let config = try JSONSerialization.data(withJSONObject: instance["config"] as? [String: Any] ?? [:], options: [.sortedKeys])
                    models.append(.init(runtime: runtime, name: row["display_name"] as? String ?? key, instance: id,
                        fingerprint: key + ":" + config.base64EncodedString(), memoryBytes: nil, gpuBytes: nil,
                        quantization: (row["quantization"] as? [String: Any])?["name"] as? String))
                    guard models.count <= 256 else { throw LocalModelError.tooLarge }
                }
            }
        }
        guard Set(models.map(\.id)).count == models.count else { throw LocalModelError.invalid }
        return models.sorted { $0.id < $1.id }
    }
    static func bytes(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d < Double(Int64.max), d.rounded(.down) == d else { return nil }
        return Int64(d)
    }
    static func unloadBody(_ model: LoadedLocalModel) throws -> Data {
        let body: [String: Any] = model.runtime == .ollama
            ? ["model": model.instance, "keep_alive": 0, "stream": false]
            : ["instance_id": model.instance]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

private final class LoopbackOnlyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct LocalModelClient {
    var transport: ((LocalModelRuntime, String, String, Data?) async throws -> Data)?
    func request(runtime: LocalModelRuntime, path: String, token: String, body: Data? = nil) async throws -> Data {
        guard !token.contains(where: { $0.isNewline || $0.asciiValue == 0 }), token.count <= 4096 else { throw LocalModelError.token }
        guard [runtime.listPath, runtime.unloadPath].contains(path) else { throw LocalModelError.invalid }
        if let transport { return try await transport(runtime, path, token, body) }
        let url = URL(string: "http://127.0.0.1:\(runtime.port)\(path)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: LoopbackOnlyDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == "127.0.0.1" else { throw LocalModelError.invalid }
        guard (200..<300).contains(http.statusCode) else { throw LocalModelError.http(http.statusCode) }
        guard response.expectedContentLength <= 1_048_576 else { throw LocalModelError.tooLarge }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw LocalModelError.tooLarge }
            data.append(byte)
        }
        return data
    }
    func models(_ runtime: LocalModelRuntime, token: String) async throws -> [LoadedLocalModel] {
        try LocalModelDecoder.decode(await request(runtime: runtime, path: runtime.listPath, token: token), runtime: runtime)
    }
    func unload(_ model: LoadedLocalModel, token: String) async throws -> Bool {
        let current = try await models(model.runtime, token: token)
        guard current.contains(where: { $0.id == model.id && $0.fingerprint == model.fingerprint }) else { throw LocalModelError.changed }
        _ = try await request(runtime: model.runtime, path: model.runtime.unloadPath, token: token, body: LocalModelDecoder.unloadBody(model))
        let after = try await models(model.runtime, token: token)
        return !after.contains(where: { $0.id == model.id })
    }
}

@MainActor
final class LocalModelsService: ObservableObject {
    @Published private(set) var models: [LoadedLocalModel] = []
    @Published private(set) var status: [LocalModelRuntime: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var checkedAt: Date?
    @Published var actionMessage: String?
    @Published var lmToken = "" // Memory only; never stored, logged or exported.
    private var task: Task<Void, Never>?
    private var generation = 0
    private var acting = false
    func refresh() {
        guard !busy else { return }
        busy = true; generation += 1
        let epoch = generation, token = lmToken
        task = Task {
            var found: [LoadedLocalModel] = [], messages: [LocalModelRuntime: String] = [:]
            for runtime in LocalModelRuntime.allCases {
                do {
                    let values = try await LocalModelClient().models(runtime, token: runtime == .lmStudio ? token : "")
                    found += values
                    messages[runtime] = values.isEmpty ? "Connected · no loaded models" : "Connected · \(values.count) loaded instance(s)"
                } catch { messages[runtime] = "Unavailable · " + error.localizedDescription }
                guard !Task.isCancelled, generation == epoch else { return }
            }
            models = found; status = messages; busy = false; checkedAt = Date(); task = nil
        }
    }
    func cancelRead() {
        guard !acting else { return }
        generation += 1; task?.cancel(); task = nil; busy = false
    }
    func unload(_ model: LoadedLocalModel) {
        guard !busy, models.contains(model) else { return }
        busy = true; acting = true
        let token = model.runtime == .lmStudio ? lmToken : ""
        task = Task {
            do {
                let gone = try await LocalModelClient().unload(model, token: token)
                actionMessage = gone ? "The runtime no longer lists this instance. Its model files remain on disk." : "The unload request completed, but the instance is still listed or was loaded again."
                if gone { models.removeAll { $0.id == model.id } }
            } catch { actionMessage = "The unload result could not be confirmed: " + error.localizedDescription }
            acting = false; busy = false; task = nil
        }
    }
}

struct LocalModelsView: View {
    @ObservedObject var service: LocalModelsService
    @State private var pending: LoadedLocalModel?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Loaded AI models").font(.title2.bold())
                        Text("Active runtime instances, separate from downloaded model files.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(service.busy ? "Checking…" : "Check local runtimes") { service.refresh() }.disabled(service.busy)
                }
                Text("Checks Ollama on port 11434 and LM Studio v1 on port 1234, only on this Mac. Start the runtime's local API server first. Other runtimes and custom ports are not queried.").font(.callout).foregroundStyle(.secondary)
                SecureField("Optional LM Studio API token · kept only for this view session", text: $service.lmToken)
                    .textFieldStyle(.roundedBorder).disabled(service.busy)
                ForEach(LocalModelRuntime.allCases) { runtime in
                    Label("\(runtime.title): \(service.status[runtime] ?? "Not checked")", systemImage: "server.rack").font(.callout)
                }
                if service.busy { ProgressView() }
                ForEach(service.models) { model in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.name).font(.headline)
                            Spacer()
                            Button("Unload…") { pending = model }.disabled(service.busy)
                        }
                        Text("\(model.runtime.title) · \(model.quantization ?? "Quantization unavailable") · instance \(model.instance)").font(.caption).foregroundStyle(.secondary)
                        Text("Runtime-reported memory: \(model.memoryBytes.map(fmt) ?? "Unavailable") · GPU allocation: \(model.gpuBytes.map(fmt) ?? "Unavailable")").font(.callout).monospacedDigit()
                    }.padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("LM Studio's model file size is not a RAM reading. Loaded status does not establish whether inference is currently active. Unloading may interrupt clients; no tokens-per-second or memory-fit estimate is invented.").font(.caption).foregroundStyle(.secondary)
                if let date = service.checkedAt { Text("Last checked \(date.formatted()) · refresh before relying on this snapshot").font(.caption).foregroundStyle(.secondary) }
                if let message = service.actionMessage { Text(message).font(.callout).textSelection(.enabled) }
            }.padding(24)
        }
        .onDisappear { service.cancelRead() }
        .alert("Unload this model instance?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Unload", role: .destructive) { if let model = pending { service.unload(model) }; pending = nil }
        } message: {
            Text("\(pending?.name ?? "")\nThis can interrupt an app using this runtime. FastMac rechecks the instance, asks the runtime to unload it, then checks the result. Model files stay on disk and the next use may load them again.")
        }
    }
}
