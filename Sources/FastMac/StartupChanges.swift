import SwiftUI
import CryptoKit

struct StartupFact: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let owner: String
    let domain: String
    let program: String
    let fingerprint: String

    static func make(_ item: StartupItem) -> StartupFact? {
        guard !item.unreadable else { return nil }
        // Compare configuration, not mutable CPU/PID/loaded-state readings.
        let fields: [String: Any] = ["label": item.label, "domain": item.domain.rawValue,
            "program": item.programPath ?? "", "arguments": item.programArguments,
            "runAtLoad": item.runAtLoad, "keepAlive": item.keepAlive,
            "interval": item.startInterval ?? 0, "watches": item.watchesPaths,
            "disabled": item.legacyDisabledKey]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return .init(id: item.id, label: item.label, owner: item.owner, domain: item.domain.title,
                     program: item.programPath ?? "No program", fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

struct StartupChange: Identifiable, Sendable {
    let current: StartupFact
    let prior: StartupFact?
    var id: String { current.id }
    var title: String { prior == nil ? "Newly observed" : "Configuration changed" }
}

struct StartupBaseline: Codable, Sendable {
    var version = 1
    var accepted: [String: StartupFact] = [:]
    static func changes(current: [StartupFact], baseline: StartupBaseline) -> [StartupChange] {
        current.filter { baseline.accepted[$0.id]?.fingerprint != $0.fingerprint }
            .map { .init(current: $0, prior: baseline.accepted[$0.id]) }.sorted { $0.id < $1.id }
    }
}

struct StartupBaselineRepository: Sendable {
    var url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FastMac/startup-baseline.json")
    func read() throws -> StartupBaseline? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw CocoaError(.fileReadTooLarge) }
        let baseline = try JSONDecoder().decode(StartupBaseline.self, from: data)
        guard baseline.version == 1, baseline.accepted.count <= 2000 else { throw CocoaError(.fileReadCorruptFile) }
        return baseline
    }
    func write(_ baseline: StartupBaseline) throws {
        guard baseline.accepted.count <= 2000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let data = try JSONEncoder().encode(baseline)
        guard data.count <= 2_097_152 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class StartupChangesModel: ObservableObject {
    @Published private(set) var changes: [StartupChange] = []
    @Published private(set) var status = "A baseline is created after the first readable scan."
    @Published private(set) var busy = false
    private var facts: [StartupFact] = []
    private let repository: StartupBaselineRepository
    init(repository: StartupBaselineRepository = .init()) { self.repository = repository }
    func compare(_ items: [StartupItem]) {
        guard !busy else { return }
        facts = items.compactMap(StartupFact.make)
        guard !facts.isEmpty else { status = "No readable entries to compare; the previous baseline is preserved."; return }
        perform(acknowledge: nil)
    }
    func acknowledge(_ change: StartupChange) { guard !busy else { return }; perform(acknowledge: change.current) }
    private func perform(acknowledge: StartupFact?) {
        busy = true
        let current = facts, repo = repository
        Task {
            let result: Result<([StartupChange], String), Error> = await Task.detached(priority: .utility) {
                do {
                    if var baseline = try repo.read() {
                        if let fact = acknowledge {
                            baseline.accepted[fact.id] = fact
                            try repo.write(baseline)
                        }
                        return .success((StartupBaseline.changes(current: current, baseline: baseline), "Compared with your accepted configuration. Missing or unreadable entries are not reported as removed."))
                    }
                    var baseline = StartupBaseline()
                    for fact in current { baseline.accepted[fact.id] = fact }
                    try repo.write(baseline)
                    return .success(([], "Baseline saved. Future scans will flag new or changed readable configurations."))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let value): changes = value.0; status = value.1
            case .failure(let error): status = "Startup comparison unavailable: " + error.localizedDescription
            }
            busy = false
        }
    }
}

struct StartupChangesReview: View {
    @ObservedObject var model: StartupChangesModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup changes").font(.title2.bold())
            Text("Newly observed means absent from the accepted baseline, not proof of a recent installation. App ownership is inferred from labels and paths; it is not signature verification.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.changes) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(change.title, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(change.current.label).font(.headline)
                            Text("\(change.current.owner) · \(change.current.domain)").font(.caption)
                            Text(change.current.program).font(.caption.monospaced()).textSelection(.enabled)
                            if let prior = change.prior, prior.program != change.current.program {
                                Text("Previously: \(prior.program)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(change.current.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Expected — acknowledge this version") { model.acknowledge(change) }.disabled(model.busy)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 150, maxHeight: 360)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 610)
    }
}
