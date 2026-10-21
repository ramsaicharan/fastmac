import Foundation

/// Isolated synthetic scan summaries; no user folders are read or scanned.
enum HistorySelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(label)") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastmac-history-reliability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = FSNode(name: "fixture", path: "/fixture/history", isDir: true)
        let child = FSNode(name: "child", path: "/fixture/history/child", isDir: true)
        child.size = 100; root.children = [child]; root.size = 100
        var result = ScanResult(root: root, bytes: 100, files: 1, dirs: 1, errors: 0,
                                elapsed: 0.1, bigFiles: [], bySize: [:])
        result.scannedAt = Date(timeIntervalSince1970: 1000)
        let a = History.record(result, directory: directory, disk: (0, 0))
        let b = History.record(result, directory: directory, disk: (0, 1000))
        check("same-second scans have unique summaries", a != nil && b != nil && a?.id != b?.id
              && History.loadAll(directory: directory).count == 2)
        check("unavailable disk data stays nil; known empty disk stays zero",
              a?.diskFreeAtScan == nil && b?.diskFreeAtScan == 0)
        result.cancelled = true
        check("cancelled scan is never persisted", History.record(result, directory: directory) == nil
              && History.loadAll(directory: directory).count == 2)
        result.cancelled = false
        result.errors = 2
        let partial = History.record(result, directory: directory, disk: (50, 100))
        check("unreadable scan items remain visible in summary metadata", partial?.partial == true && partial?.errors == 2)
        if var before = a, var after = b {
            before.children = [HistoryChild(name: "child", path: child.path, bytes: 100)]
            after.children = []
            after.childrenComplete = false
            check("truncated summary does not falsely mark a folder vanished", History.diff(before, after).isEmpty)
            after.childrenComplete = true
            check("complete summary can detect a vanished folder", History.diff(before, after).first?.status == .vanished)
            after.root = "/fixture/other-root"
            check("summaries of different roots cannot be compared", History.diff(before, after).isEmpty)
            after.root = before.root
            before.children = [HistoryChild(name: "child", path: child.path, bytes: 0)]
            after.children = [HistoryChild(name: "child", path: child.path, bytes: 100)]
            check("an existing empty folder that grows is not marked as newly appeared", History.diff(before, after).first?.status == .grew)
        } else { check("fixture summaries saved before comparison", false) }
        result.errors = 0
        for i in 1...6 {
            result.scannedAt = Date(timeIntervalSince1970: Double(1000 + i))
            History.record(result, directory: directory, retentionCount: 3, disk: (50, 100))
        }
        let retained = History.loadAll(directory: directory)
        check("retention keeps the latest requested number of summaries", retained.count == 3
              && retained.first?.scannedAt == Date(timeIntervalSince1970: 1004))
        return lines
    }
}
