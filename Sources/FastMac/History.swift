import Foundation

struct HistoryChild: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let bytes: Int64
    var id: String { path }
}

/// A scan summary, not a saved filesystem tree. Optional metadata preserves access
/// to version-one summaries while exposing unreadable items and truncation honestly.
struct HistoryEntry: Codable, Identifiable, Hashable {
    static let currentVersion = 2

    var version: Int = HistoryEntry.currentVersion
    var id: String
    var root: String
    var bytes: Int64
    var files: Int
    var dirs: Int
    var elapsed: Double
    var scannedAt: Date
    var diskFreeAtScan: Int64?
    var diskTotalAtScan: Int64?
    var children: [HistoryChild]
    var errors: Int? = nil
    var childrenComplete: Bool? = true

    var partial: Bool { (errors ?? 0) > 0 }
    var canInferMissingChildren: Bool { childrenComplete == true && !partial }
}

struct HistoryDiffRow: Identifiable, Hashable {
    enum Status: String { case grew, shrank, appeared, vanished, unchanged }
    let name: String
    let path: String
    let before: Int64
    let after: Int64
    var wasPresent = true
    var isPresent = true
    var id: String { path }
    var delta: Int64 { after - before }
    var status: Status {
        if !wasPresent && isPresent { return .appeared }
        if wasPresent && !isPresent { return .vanished }
        if delta > 0 { return .grew }
        if delta < 0 { return .shrank }
        return .unchanged
    }
}

enum History {
    static let retentionCount = 200
    static let didChange = Notification.Name("FastMacScanHistoryDidChange")
    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".fastmac", isDirectory: true)
        .appendingPathComponent("history", isDirectory: true)
    private static let lock = NSLock()

    private static func ensureDir(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func fileURL(for id: String, directory: URL) -> URL {
        let safe = String(id.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-"
        })
        return directory.appendingPathComponent(safe + ".json")
    }

    /// Cancelled scans never replace a previous summary. UUIDs keep scans of the
    /// same root in the same second distinct; the previous timestamp/hash ID did not.
    @discardableResult
    static func record(_ result: ScanResult, directory: URL = History.dir,
                       retentionCount: Int = History.retentionCount,
                       disk: (free: Int64, total: Int64)? = nil) -> HistoryEntry? {
        guard !result.cancelled else { return nil }
        let children = result.root.children.sorted { $0.size > $1.size }.prefix(40)
            .map { HistoryChild(name: $0.name, path: $0.path, bytes: $0.size) }
        let reading = disk ?? MemoryProbe.diskFree()
        let available = reading.total > 0 && reading.free >= 0 && reading.free <= reading.total
        let entry = HistoryEntry(id: UUID().uuidString, root: result.root.path,
                                 bytes: result.bytes, files: result.files, dirs: result.dirs,
                                 elapsed: result.elapsed, scannedAt: result.scannedAt,
                                 diskFreeAtScan: available ? reading.free : nil,
                                 diskTotalAtScan: available ? reading.total : nil,
                                 children: Array(children), errors: result.errors,
                                 childrenComplete: result.root.children.count <= 40)
        return write(entry, directory: directory, retentionCount: retentionCount) ? entry : nil
    }

    /// Atomic files and a serial repository transaction prevent concurrent writers
    /// from racing retention. Retain at most the latest 200 summaries by default.
    @discardableResult
    static func write(_ entry: HistoryEntry, directory: URL = History.dir,
                      retentionCount: Int = History.retentionCount) -> Bool {
        lock.lock()
        let saved: Bool
        do {
            try ensureDir(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(for: entry.id, directory: directory), options: .atomic)
            let entries = readEntries(directory: directory)
            for old in entries.prefix(max(0, entries.count - max(1, retentionCount))) {
                try? FileManager.default.removeItem(at: fileURL(for: old.id, directory: directory))
            }
            saved = true
        } catch {
            saved = false
        }
        lock.unlock()
        if saved { NotificationCenter.default.post(name: didChange, object: nil) }
        return saved
    }

    /// Oldest first, skipping damaged, oversized, or future-version files. The
    /// decoded shape stays bounded even if a repository contains unrelated files.
    static func loadAll(directory: URL = History.dir) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(readEntries(directory: directory).suffix(retentionCount))
    }

    private static func readEntries(directory: URL) -> [HistoryEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [HistoryEntry] = []
        var ids = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 && size <= 1_048_576,
                  let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data),
                  entry.version >= 1 && entry.version <= HistoryEntry.currentVersion,
                  !entry.id.isEmpty && entry.id.count <= 240,
                  entry.bytes >= 0 && entry.files >= 0 && entry.dirs >= 0,
                  entry.children.count <= 1000,
                  entry.children.allSatisfy({ $0.bytes >= 0 }),
                  ids.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        return entries.sorted {
            $0.scannedAt == $1.scannedAt ? $0.id < $1.id : $0.scannedAt < $1.scannedAt
        }
    }

    static func delete(_ entry: HistoryEntry, directory: URL = History.dir) {
        lock.lock()
        try? FileManager.default.removeItem(at: fileURL(for: entry.id, directory: directory))
        lock.unlock()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// A folder omitted from a largest-40 or partial summary is not proof that it
    /// vanished. Infer missing folders only from a complete summary of the same root.
    static func diff(_ before: HistoryEntry, _ after: HistoryEntry) -> [HistoryDiffRow] {
        guard before.root == after.root else { return [] }
        var beforeMap: [String: HistoryChild] = [:]
        for child in before.children { beforeMap[child.path] = child }
        var afterMap: [String: HistoryChild] = [:]
        for child in after.children { afterMap[child.path] = child }
        let paths = Set(beforeMap.keys).union(afterMap.keys)
        return paths.compactMap { path -> HistoryDiffRow? in
            let b = beforeMap[path], a = afterMap[path]
            if b == nil && !before.canInferMissingChildren { return nil }
            if a == nil && !after.canInferMissingChildren { return nil }
            return HistoryDiffRow(name: a?.name ?? b?.name ?? (path as NSString).lastPathComponent,
                                  path: path, before: b?.bytes ?? 0, after: a?.bytes ?? 0,
                                  wasPresent: b != nil, isPresent: a != nil)
        }.sorted { abs($0.delta) > abs($1.delta) }
    }
}
