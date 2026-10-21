import Foundation
import Combine
import AppKit

struct ActivityAppSnapshot: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var cpuPercent: Double?
    var rss: Int64?
    var processCount: Int
    var footprint: Int64?
}

struct ActivitySnapshot: Codable, Identifiable, Sendable {
    var version = 1
    var sampledAt: Date
    var sessionID: String
    var cpuPercent: Double?
    var memoryUsed: Int64?
    var memoryTotal: Int64?
    var swapUsed: Int64?
    var memoryPressure: String
    var diskFree: Int64?
    var diskTotal: Int64?
    var diskReadRate: Double?
    var diskWriteRate: Double?
    var networkDownloadRate: Double?
    var networkUploadRate: Double?
    var networkScope: String
    var batteryPercent: Int?
    var gpuPercent: Double?
    var thermalState: String
    var readableProcesses: Int
    var listedProcesses: Int
    var apps: [ActivityAppSnapshot]
    // Optional additions keep existing daily logs readable. Old CPU records did
    // not declare their normalization; never silently reinterpret those values.
    var appCPUUnit: String? = "percentOfOneCore"
    var appCPUMeasurementVersion: Int? = 2
    var compressedBytes: Int64?
    var swapInRate: Double?
    var swapOutRate: Double?
    var hasComparableAppCPU: Bool { appCPUUnit == "percentOfOneCore" && appCPUMeasurementVersion == 2 }
    var id: String { sessionID + "-" + String(sampledAt.timeIntervalSince1970) }
}

struct ActivityBookmark: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var note: String
    var snapshot: ActivitySnapshot
}

/// Serial, bounded daily logs. A torn final line is ignored on read; bookmarks use atomic writes.
/// No command arguments, environment, file inventory, or project folders are recorded.
final class ActivityRepository: @unchecked Sendable {
    static let maximumBytes = 100 * 1_024 * 1_024
    static let maximumBookmarks = 100
    let directory: URL
    private let queue = DispatchQueue(label: "FastMac.activity-history", qos: .utility)
    private var lastMinuteSession: String?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FastMac/Activity", isDirectory: true)) {
        self.directory = directory
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func dayName(_ date: Date) -> String {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#,
                                                options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func append(_ snapshot: ActivitySnapshot, retentionDays: Int,
                completion: @escaping (String?) -> Void = { _ in }) {
        queue.async {
            do {
                try self.ensureDirectory()
                let minute = Int64(snapshot.sampledAt.timeIntervalSince1970 / 60)
                let minuteSession = "\(minute):\(snapshot.sessionID)"
                if self.lastMinuteSession != minuteSession {
                    var bounded = snapshot
                    bounded.apps = Array(snapshot.apps.prefix(12))
                    var data = try Self.encoder().encode(bounded)
                    data.append(0x0A)
                    let file = self.directory.appendingPathComponent(self.dayName(snapshot.sampledAt) + ".jsonl")
                    if !FileManager.default.fileExists(atPath: file.path) {
                        _ = FileManager.default.createFile(atPath: file.path, contents: nil,
                                                           attributes: [.posixPermissions: 0o600])
                    }
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    let length = try handle.seekToEnd()
                    // Preserve the fresh record after an interrupted previous append.
                    if length > 0 {
                        let reader = try FileHandle(forReadingFrom: file)
                        try reader.seek(toOffset: length - 1)
                        let tail = try reader.read(upToCount: 1)
                        try reader.close()
                        if tail?.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
                    }
                    try handle.write(contentsOf: data)
                    self.lastMinuteSession = minuteSession
                }
                try self.prune(now: snapshot.sampledAt, retentionDays: retentionDays)
                completion(nil)
            } catch { completion("History could not be saved: " + error.localizedDescription) }
        }
    }

    private func prune(now: Date, retentionDays: Int) throws {
        let cutoffDate = now.addingTimeInterval(-Double(max(1, min(30, retentionDays))) * 86_400)
        let cutoff = dayName(cutoffDate)
        var remaining: [URL] = []
        for file in files() {
            if String(file.lastPathComponent.prefix(10)) < cutoff {
                try FileManager.default.removeItem(at: file)
            } else { remaining.append(file) }
        }
        if let boundary = remaining.first, boundary.lastPathComponent.hasPrefix(cutoff) {
            // Daily log granularity must not silently add an extra day of retention.
            let contents = try Data(contentsOf: boundary)
            var kept = Data(), removed = false
            for line in contents.split(separator: 0x0A) {
                guard let sample = try? Self.decoder().decode(ActivitySnapshot.self, from: Data(line)),
                      sample.version == 1 else { removed = true; continue }
                if sample.sampledAt < cutoffDate { removed = true; continue }
                kept.append(contentsOf: line); kept.append(0x0A)
            }
            if removed { try kept.write(to: boundary, options: .atomic) }
        }
        var sizes = remaining.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var bytes = sizes.reduce(0, +)
        while bytes > Self.maximumBytes, !remaining.isEmpty {
            bytes -= sizes.removeFirst()
            try FileManager.default.removeItem(at: remaining.removeFirst())
        }
    }

    func enforceRetention(days: Int, completion: @escaping (String?) -> Void = { _ in }) {
        queue.async {
            do { try self.prune(now: Date(), retentionDays: days); completion(nil) }
            catch { completion("Retention could not be applied: " + error.localizedDescription) }
        }
    }

    /// Streams each log instead of decoding the entire retention window into memory.
    func load(from: Date, until: Date = Date(), limit: Int = 1_500,
              completion: @escaping ([ActivitySnapshot], String?) -> Void) {
        let limit = max(1, min(10_000, limit))
        queue.async {
            var output: [ActivitySnapshot] = []
            var bucketWidth = max(60, until.timeIntervalSince(from) / Double(max(1, limit - 1)))
            if !bucketWidth.isFinite { bucketWidth = 60 }
            var lastBucket: Int?
            var lastSession: String?
            var errorText: String?
            do {
                for file in self.files() where String(file.lastPathComponent.prefix(10)) >= self.dayName(from)
                    && String(file.lastPathComponent.prefix(10)) <= self.dayName(until) {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    var pending = Data()
                    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = pending.prefix(upTo: newline)
                            pending.removeSubrange(...newline)
                            guard line.count <= 65_536,
                                  let sample = try? Self.decoder().decode(ActivitySnapshot.self, from: line),
                                  sample.version == 1, sample.sampledAt >= from, sample.sampledAt <= until else { continue }
                            let bucket = Int(sample.sampledAt.timeIntervalSince(from) / bucketWidth)
                            if bucket != lastBucket || sample.sessionID != lastSession {
                                output.append(sample)
                            } else if !output.isEmpty {
                                output[output.count - 1] = sample
                            }
                            lastBucket = bucket
                            lastSession = sample.sessionID
                        }
                        if pending.count > 65_536 { pending.removeAll() }
                    }
                }
            } catch { errorText = "History could not be read: " + error.localizedDescription }
            // Sessions can exceed the graph's bound after frequent stop/start cycles.
            if output.count > limit {
                let stride = Double(output.count - 1) / Double(max(1, limit - 1))
                output = (0..<limit).map { output[Int(Double($0) * stride)] }
            }
            completion(output, errorText)
        }
    }

    func bookmarks(completion: @escaping ([ActivityBookmark], String?) -> Void) {
        queue.async {
            let file = self.directory.appendingPathComponent("bookmarks.json")
            guard FileManager.default.fileExists(atPath: file.path) else { completion([], nil); return }
            do {
                let values = try Self.decoder().decode([ActivityBookmark].self, from: Data(contentsOf: file))
                completion(Array(values.suffix(Self.maximumBookmarks)), nil)
            } catch { completion([], "Saved moments could not be read: " + error.localizedDescription) }
        }
    }

    func saveBookmarks(_ values: [ActivityBookmark], completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.ensureDirectory()
                let file = self.directory.appendingPathComponent("bookmarks.json")
                try Self.encoder().encode(Array(values.suffix(Self.maximumBookmarks)))
                    .write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                completion(nil)
            } catch { completion("Saved moments could not be saved: " + error.localizedDescription) }
        }
    }

    func clear(completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                for file in self.files() { try FileManager.default.removeItem(at: file) }
                let bookmarks = self.directory.appendingPathComponent("bookmarks.json")
                if FileManager.default.fileExists(atPath: bookmarks.path) {
                    try FileManager.default.removeItem(at: bookmarks)
                }
                self.lastMinuteSession = nil
                completion(nil)
            } catch { completion("History could not be cleared: " + error.localizedDescription) }
        }
    }

    static func csv(_ samples: [ActivitySnapshot], includeAppNames: Bool) -> String {
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        func bytes(_ value: Int64?) -> String { value.map(String.init) ?? "" }
        let header = "timestamp,cpu_whole_machine_percent,memory_bytes,memory_total_bytes,swap_bytes,macos_memory_pressure,disk_free_bytes,disk_total_bytes,readable_process_disk_read_bytes_per_second,readable_process_disk_write_bytes_per_second,network_download_bytes_per_second,network_upload_bytes_per_second,network_scope,battery_percent,gpu_percent,thermal_state,readable_processes,listed_processes,top_app_names,compressed_bytes,swap_in_bytes_per_second,swap_out_bytes_per_second"
        let format = ISO8601DateFormatter()
        let rows = samples.map { sample in
            [cell(format.string(from: sample.sampledAt)), number(sample.cpuPercent), bytes(sample.memoryUsed),
             bytes(sample.memoryTotal), bytes(sample.swapUsed), cell(sample.memoryPressure), bytes(sample.diskFree),
             bytes(sample.diskTotal), number(sample.diskReadRate), number(sample.diskWriteRate),
             number(sample.networkDownloadRate), number(sample.networkUploadRate), cell(sample.networkScope),
             sample.batteryPercent.map(String.init) ?? "", number(sample.gpuPercent), cell(sample.thermalState),
             String(sample.readableProcesses), String(sample.listedProcesses),
             cell(includeAppNames ? sample.apps.map(\.name).joined(separator: "; ") : ""),
             bytes(sample.compressedBytes), number(sample.swapInRate), number(sample.swapOutRate)].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

enum ActivitySamplingContinuity {
    static func elapsed(currentUptime: TimeInterval, currentAt: Date,
                        previousUptime: TimeInterval?, previousAt: Date?,
                        maximumGap: TimeInterval = 75) -> TimeInterval? {
        guard let previousUptime, let previousAt else { return nil }
        let uptimeDelta = currentUptime - previousUptime
        let wallDelta = currentAt.timeIntervalSince(previousAt)
        guard uptimeDelta.isFinite, uptimeDelta > 0, uptimeDelta <= maximumGap,
              wallDelta.isFinite, wallDelta > 0, wallDelta <= maximumGap,
              abs(wallDelta - uptimeDelta) <= 5 else { return nil }
        return uptimeDelta
    }
}

private final class ActivitySampler: @unchecked Sendable {
    private var previous = PerfProbe.CPUState()
    private var previousNetwork: NetworkCounterSnapshot?
    private var previousDisk: [ProcessIdentity: (read: Int64, write: Int64)] = [:]
    private var previousUptime: TimeInterval?
    private var previousAt: Date?
    private var previousMemory: MemorySample?
    private var gapID = UUID().uuidString
    func reset() {
        previous = PerfProbe.CPUState()
        previousNetwork = nil
        previousDisk = [:]
        previousUptime = nil
        previousAt = nil
        previousMemory = nil
        gapID = UUID().uuidString
    }
    func sample(session: String) -> (ActivitySnapshot, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let at = Date()
        let elapsed = ActivitySamplingContinuity.elapsed(currentUptime: start, currentAt: at,
            previousUptime: previousUptime, previousAt: previousAt)
        // A missed interval is a gap, not activity to interpolate through.
        if previousUptime != nil, elapsed == nil {
            previous = PerfProbe.CPUState()
            previousNetwork = nil
            previousDisk = [:]
            previousMemory = nil
            gapID = UUID().uuidString
        }
        let baseline = previous.at != .distantPast
        let priorState = previous
        let result = PerfProbe.sweep(previous: previous)
        previous = result.newState
        let health = HealthProbe.sample()
        let swapRates = ActivityMemoryRates.make(current: health.memory,
                                                previous: previousMemory, elapsed: elapsed)
        previousMemory = health.memory
        let network = ResourceProbe.networkCounters()
        let rate = ResourceProbe.networkRate(current: network, previous: previousNetwork, maximumGap: 75)
        previousNetwork = network
        let battery = ResourceProbe.battery()
        let gpu = ResourceProbe.gpu()
        var nextDisk: [ProcessIdentity: (read: Int64, write: Int64)] = [:]
        var read = 0.0, write = 0.0, known = false
        for process in result.procs {
            guard let identity = process.identity, let r = process.diskRead, let w = process.diskWrite else { continue }
            nextDisk[identity] = (r, w)
            if let prior = previousDisk[identity], r >= prior.read, w >= prior.write {
                read += Double(r - prior.read)
                write += Double(w - prior.write)
                known = true
            }
        }
        previousDisk = nextDisk
        previousUptime = start
        previousAt = at
        let validInterval = elapsed.map { $0 > 0 && $0 <= 75 } ?? false
        let duration = max(0.001, elapsed ?? 1)
        let processesByPID = Dictionary(result.procs.map { ($0.pid, $0) }, uniquingKeysWith: { _, newer in newer })
        let groups = ActivityAppSelection.leading(result.groups)
        let snapshot = ActivitySnapshot(sampledAt: health.sampledAt, sessionID: session + "-" + gapID,
            cpuPercent: baseline && validInterval && result.system.cpuAvailable
                ? result.system.systemUserPercent + result.system.systemSystemPercent : nil,
            memoryUsed: health.memoryAvailable ? health.memory.used : nil,
            memoryTotal: health.memoryAvailable ? health.memory.total : nil,
            swapUsed: health.swapAvailable ? health.memory.swapUsed : nil,
            memoryPressure: health.memoryPressure.rawValue,
            diskFree: health.diskAvailable ? health.diskFree : nil,
            diskTotal: health.diskAvailable ? health.diskTotal : nil,
            diskReadRate: known && validInterval ? read / duration : nil,
            diskWriteRate: known && validInterval ? write / duration : nil,
            networkDownloadRate: rate.downloadBytesPerSecond,
            networkUploadRate: rate.uploadBytesPerSecond, networkScope: network.scopeDescription,
            batteryPercent: battery.percent, gpuPercent: gpu.utilizationPercent,
            thermalState: health.thermalTitle, readableProcesses: result.pidsReadable,
            listedProcesses: result.pidsListed,
            apps: groups.map { group in
                let footprints = group.pids.compactMap { processesByPID[$0]?.footprint }
                return ActivityAppSnapshot(id: group.id, name: group.name,
                    cpuPercent: group.cpuAvailable && baseline && validInterval && group.pids.allSatisfy { pid in
                        guard let old = priorState.perPid[pid],
                              let current = processesByPID[pid] else { return false }
                        return old.identity != nil && old.identity == current.identity
                    } ? group.cpuPercent : nil,
                    rss: group.rss, processCount: group.count,
                    footprint: footprints.count == group.count ? footprints.reduce(0, +) : nil)
            }, compressedBytes: health.memoryAvailable ? health.memory.compressor : nil,
            swapInRate: swapRates.read, swapOutRate: swapRates.write)
        return (snapshot, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

/// All menu-bar/history/alert subscribers share this background process sampler.
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var latest: ActivitySnapshot?
    @Published private(set) var recent: [ActivitySnapshot] = []
    @Published private(set) var isMonitoring = false
    @Published private(set) var history: [ActivitySnapshot] = []
    @Published private(set) var bookmarks: [ActivityBookmark] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var probeMilliseconds: Double = 0
    let repository: ActivityRepository
    private let queue = DispatchQueue(label: "FastMac.activity-sampler", qos: .utility)
    private var timer: Timer?
    private var epoch = 0
    private var inFlight = false
    private var sessionID = UUID().uuidString
    private let sampler = ActivitySampler()
    private var queryID = 0
    private var bookmarkMutation = 0
    private let allowsPersistence: Bool
    private let sampleProvider: (@Sendable (String) -> (ActivitySnapshot, Double))?
    private let samplingInterval: TimeInterval

    init(repository: ActivityRepository = ActivityRepository(), allowsPersistence: Bool = true,
         initialHistory: [ActivitySnapshot] = [], initialBookmarks: [ActivityBookmark] = [],
         sampleProvider: (@Sendable (String) -> (ActivitySnapshot, Double))? = nil,
         samplingInterval: TimeInterval = 15) {
        self.repository = repository
        self.allowsPersistence = allowsPersistence
        self.sampleProvider = sampleProvider
        self.samplingInterval = samplingInterval.isFinite ? max(0.02, samplingInterval) : 15
        history = initialHistory
        latest = initialHistory.last
        bookmarks = initialBookmarks
        if allowsPersistence {
            reloadBookmarks()
            applyRetention(days: Settings.shared.activityRetentionDays)
        }
    }

    func start() {
        guard !isMonitoring else { return }
        epoch &+= 1
        sessionID = UUID().uuidString
        isMonitoring = true
        refresh()
        let generation = epoch
        let timer = Timer(timeInterval: samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMonitoring, self.epoch == generation else { return }
                self.refresh()
            }
        }
        timer.tolerance = min(3, samplingInterval / 5)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        epoch &+= 1
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        // Sampler state is owned exclusively by the serial queue.
        let worker = sampler
        queue.async { worker.reset() }
    }
    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let generation = epoch, session = sessionID, wasMonitoring = isMonitoring
        let worker = sampler
        let provider = sampleProvider
        queue.async {
            let (snapshot, cost) = provider?(session) ?? worker.sample(session: session)
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.epoch == generation else {
                    if self.isMonitoring { self.refresh() }
                    return
                }
                self.latest = snapshot
                self.recent.append(snapshot)
                self.recent = Array(self.recent.filter { snapshot.sampledAt.timeIntervalSince($0.sampledAt) <= 3600 }.suffix(240))
                self.probeMilliseconds = cost
                if self.allowsPersistence, wasMonitoring, Settings.shared.recordActivityHistory {
                    self.repository.append(snapshot, retentionDays: Settings.shared.activityRetentionDays) { message in
                        if let message { DispatchQueue.main.async { self.error = message } }
                    }
                }
            }
        }
    }
    func loadHistory(hours: Double) {
        guard allowsPersistence else { return }
        queryID &+= 1
        let request = queryID
        loading = true
        repository.load(from: Date().addingTimeInterval(-hours * 3600)) { samples, message in
            DispatchQueue.main.async {
                guard self.queryID == request else { return }
                self.history = samples
                self.loading = false
                self.error = message
            }
        }
    }
    func applyRetention(days: Int) {
        guard allowsPersistence else { return }
        repository.enforceRetention(days: days) { message in
            if let message { DispatchQueue.main.async { self.error = message } }
        }
    }
    func saveMoment(note: String, snapshot: ActivitySnapshot? = nil) {
        guard allowsPersistence, let sample = snapshot ?? latest else { return }
        var values = bookmarks
        values.append(ActivityBookmark(note: String(note.prefix(500)), snapshot: sample))
        values = Array(values.suffix(ActivityRepository.maximumBookmarks))
        persistBookmarks(values)
    }
    func deleteMoment(_ bookmark: ActivityBookmark) {
        guard allowsPersistence else { return }
        persistBookmarks(bookmarks.filter { $0.id != bookmark.id })
    }
    private func persistBookmarks(_ values: [ActivityBookmark]) {
        bookmarkMutation &+= 1
        let mutation = bookmarkMutation
        let prior = bookmarks
        bookmarks = values
        repository.saveBookmarks(values) { message in
            DispatchQueue.main.async {
                guard self.bookmarkMutation == mutation else { return }
                self.error = message
                if message != nil { self.bookmarks = prior }
            }
        }
    }
    func reloadBookmarks() {
        guard allowsPersistence else { return }
        let mutation = bookmarkMutation
        repository.bookmarks { values, message in
            DispatchQueue.main.async {
                guard self.bookmarkMutation == mutation else { return }
                self.bookmarks = values; self.error = message
            }
        }
    }
    func clearHistory() {
        guard allowsPersistence else { return }
        queryID &+= 1
        bookmarkMutation &+= 1
        let request = queryID, mutation = bookmarkMutation
        let priorHistory = history, priorBookmarks = bookmarks
        loading = false
        history = []
        bookmarks = []
        repository.clear { message in
            DispatchQueue.main.async {
                self.error = message
                if message != nil {
                    if self.queryID == request { self.history = priorHistory }
                    if self.bookmarkMutation == mutation { self.bookmarks = priorBookmarks }
                }
            }
        }
    }
    deinit { timer?.invalidate() }
}
