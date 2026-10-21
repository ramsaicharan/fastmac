import Foundation

/// Headless checks for the menu-bar / alerts / history / onboarding / export feature
/// set. Returns "PASS …" / "FAIL …" lines rather than asserting, so a caller (see
/// main.swift's `--shellcheck`) can print everything and decide the exit code once.
///
/// What this CAN verify by actually running it: the pure decision logic (alert
/// edge-triggering and rate limiting), history persistence and diffing including
/// malformed-file tolerance, export byte-building, and the wall-clock cost of the
/// menu bar's per-tick sampling work.
///
/// What this CANNOT verify headlessly, and does not pretend to: that the
/// NSStatusItem actually renders, that a real UNUserNotificationCenter authorization
/// prompt appears and a real system notification is delivered, or that the
/// onboarding sheet displays correctly. Those were checked by reading the code and
/// by compiling it, not by exercising them — see HANDOFF.md's self-critique.
enum ShellSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        checkAlerts(&lines)
        checkHistory(&lines)
        checkExporter(&lines)
        checkFDA(&lines)
        checkMenuBarCost(&lines)
        return lines
    }

    private static func record(_ lines: inout [String], _ ok: Bool, _ label: String, _ detail: String = "") {
        let tag = ok ? "PASS" : "FAIL"
        lines.append("\(tag) \(label)" + (detail.isEmpty ? "" : " — \(detail)"))
    }

    // MARK: Alerts

    private static func checkAlerts(_ lines: inout [String]) {
        var ev = AlertEvaluator(freeDiskThresholdBytes: 10 << 30, memoryPressureThreshold: 80,
                                sustainedSeconds: 300, rateLimit: 6 * 3600)
        let t0 = Date()

        // Plenty of free space, low pressure: silence.
        var fires = ev.evaluate(diskFree: 50 << 30, pressure: 20, now: t0)
        record(&lines, fires.isEmpty, "alerts: quiet when healthy")

        // Disk drops below threshold: fires exactly once on the transition.
        fires = ev.evaluate(diskFree: 5 << 30, pressure: 20, now: t0.addingTimeInterval(1))
        record(&lines, fires == [.disk], "alerts: disk fires on transition into low space")
        fires = ev.evaluate(diskFree: 4 << 30, pressure: 20, now: t0.addingTimeInterval(2))
        record(&lines, fires.isEmpty, "alerts: disk does not nag while still low")

        // Recovers, then drops again after the rate limit: fires again.
        fires = ev.evaluate(diskFree: 50 << 30, pressure: 20, now: t0.addingTimeInterval(3))
        record(&lines, fires.isEmpty, "alerts: disk recovery fires nothing")
        fires = ev.evaluate(diskFree: 4 << 30, pressure: 20, now: t0.addingTimeInterval(3600 * 7))
        record(&lines, fires == [.disk], "alerts: disk re-fires after recovery + rate limit elapsed")

        // Rate limit blocks a same-day repeat even across a fresh transition.
        fires = ev.evaluate(diskFree: 50 << 30, pressure: 20, now: t0.addingTimeInterval(3600 * 7 + 10))
        fires = ev.evaluate(diskFree: 4 << 30, pressure: 20, now: t0.addingTimeInterval(3600 * 7 + 20))
        record(&lines, fires.isEmpty, "alerts: disk rate limit blocks a too-soon repeat")

        // Memory: a brief spike below the sustained window must not alert.
        var mv = AlertEvaluator(freeDiskThresholdBytes: 1, memoryPressureThreshold: 80,
                                sustainedSeconds: 300, rateLimit: 6 * 3600)
        fires = mv.evaluate(diskFree: 999, pressure: 90, now: t0)
        fires.append(contentsOf: mv.evaluate(diskFree: 999, pressure: 40, now: t0.addingTimeInterval(60)))
        record(&lines, fires.isEmpty, "alerts: memory spike shorter than sustain window is silent")

        // Sustained past the window fires once, then latches quiet while it persists.
        fires = mv.evaluate(diskFree: 999, pressure: 90, now: t0.addingTimeInterval(200))
        record(&lines, fires.isEmpty, "alerts: memory not yet sustained long enough")
        fires = mv.evaluate(diskFree: 999, pressure: 90, now: t0.addingTimeInterval(200 + 301))
        record(&lines, fires == [.memory], "alerts: memory fires once sustained past the window")
        fires = mv.evaluate(diskFree: 999, pressure: 95, now: t0.addingTimeInterval(200 + 400))
        record(&lines, fires.isEmpty, "alerts: memory does not nag while still sustained-bad")
    }

    // MARK: History

    private static func checkHistory(_ lines: inout [String]) {
        // Exercise the production persistence code in an isolated temporary repository.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastmac-history-selfcheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            record(&lines, false, "history: creates an isolated test repository", error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = HistoryEntry(id: "selftest-a", root: "/tmp/selftest", bytes: 1000, files: 10,
                             dirs: 2, elapsed: 1, scannedAt: Date(timeIntervalSince1970: 1000),
                             diskFreeAtScan: 500, diskTotalAtScan: 2000,
                             children: [HistoryChild(name: "x", path: "/tmp/selftest/x", bytes: 600),
                                        HistoryChild(name: "y", path: "/tmp/selftest/y", bytes: 400)])
        let b = HistoryEntry(id: "selftest-b", root: "/tmp/selftest", bytes: 1500, files: 12,
                             dirs: 2, elapsed: 1, scannedAt: Date(timeIntervalSince1970: 2000),
                             diskFreeAtScan: 300, diskTotalAtScan: 2000,
                             children: [HistoryChild(name: "x", path: "/tmp/selftest/x", bytes: 900),
                                        HistoryChild(name: "z", path: "/tmp/selftest/z", bytes: 600)])
        History.write(a, directory: directory)
        History.write(b, directory: directory)
        let loaded = History.loadAll(directory: directory)
        let gotA = loaded.first { $0.id == "selftest-a" }
        let gotB = loaded.first { $0.id == "selftest-b" }
        record(&lines, loaded.count == 2 && gotA?.bytes == 1000 && gotB?.bytes == 1500,
               "history: round-trips saved entries")
        record(&lines, loaded.map(\.id) == [a.id, b.id], "history: loads oldest scan first")

        let diff = History.diff(a, b)
        let x = diff.first { $0.path == "/tmp/selftest/x" }
        let y = diff.first { $0.path == "/tmp/selftest/y" }
        let z = diff.first { $0.path == "/tmp/selftest/z" }
        record(&lines, x?.status == .grew && x?.delta == 300, "history diff: grew folder detected")
        record(&lines, y?.status == .vanished, "history diff: vanished folder detected")
        record(&lines, z?.status == .appeared, "history diff: appeared folder detected")

        // Malformed / truncated file must be skipped, never crash loadAll().
        let garbageURL = directory.appendingPathComponent("selftest-garbage.json")
        do {
            try Data("{ not json".utf8).write(to: garbageURL, options: .atomic)
            try Data().write(to: directory.appendingPathComponent("selftest-empty.json"), options: .atomic)
        } catch {
            record(&lines, false, "history: writes malformed test fixtures", error.localizedDescription)
            return
        }
        let survivedLoad = History.loadAll(directory: directory)
        record(&lines, survivedLoad.count == 2 && survivedLoad.contains { $0.id == a.id },
               "history: skips malformed and empty files alongside good ones")

        var future = a
        future.id = "selftest-future"
        future.version = HistoryEntry.currentVersion + 1
        History.write(future, directory: directory)
        record(&lines, History.loadAll(directory: directory).count == 2,
               "history: skips future-version entries")
        History.delete(a, directory: directory)
        let afterDelete = History.loadAll(directory: directory)
        record(&lines, afterDelete.count == 1 && afterDelete.first?.id == b.id,
               "history: deletes only the selected entry")
    }

    // MARK: Export

    private static func checkExporter(_ lines: inout [String]) {
        let root = FSNode(name: "root", path: "/tmp/selftest-export", isDir: true)
        root.size = 300; root.logical = 300; root.files = 2; root.dirs = 1
        let child = FSNode(name: "child", path: "/tmp/selftest-export/child", isDir: true)
        child.size = 100; child.logical = 100; child.files = 1; child.dirs = 0
        child.parent = root
        root.children = [child]
        let result = ScanResult(root: root, bytes: 300, files: 2, dirs: 1, errors: 0,
                                elapsed: 0.5, bigFiles: [], bySize: [:])

        let csv = Exporter.buildCSV(result)
        record(&lines, csv.contains("/tmp/selftest-export/child") && csv.hasPrefix("path,name,"),
              "export: CSV includes every directory row")

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = Exporter.buildJSON(result),
           let payload = try? dec.decode(Exporter.ExportPayload.self, from: data) {
            record(&lines, payload.directories.count == 2 && payload.bytes == 300,
                  "export: JSON round-trips the scan tree")
        } else {
            record(&lines, false, "export: JSON round-trips the scan tree", "encode/decode failed")
        }
    }

    // MARK: FDA

    private static func checkFDA(_ lines: inout [String]) {
        // Can only confirm it runs to completion without crashing or throwing — the
        // true/false answer is a property of this machine's actual TCC grant, which
        // a headless check cannot control.
        _ = FDACheck.hasFullDiskAccess()
        record(&lines, true, "onboarding: FDA probe completes without crashing")
    }

    // MARK: Menu bar cost

    private static func checkMenuBarCost(_ lines: inout [String]) {
        let iterations = 50
        var total: Double = 0
        var minV = Double.greatestFiniteMagnitude
        var maxV: Double = 0
        for _ in 0..<iterations {
            let t0 = DispatchTime.now()
            _ = MenuBarStats.sample()
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            total += dt
            minV = min(minV, dt); maxV = max(maxV, dt)
        }
        let avg = total / Double(iterations)
        // Generous bound: this is two syscalls (host_statistics64 + statfs) with no
        // filesystem walk. A regression into real I/O would blow well past this.
        record(&lines, avg < 20, "menubar: per-tick sample cost is cheap",
              String(format: "avg %.3fms  min %.3fms  max %.3fms  over %d ticks", avg, minV, maxV, iterations))
    }
}
