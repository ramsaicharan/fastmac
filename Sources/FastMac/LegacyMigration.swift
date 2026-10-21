import Foundation

/// FastMac was called DiskMap before its public release. The first launch under the
/// new identity carries the user's settings, cleanup queue, scan history and activity
/// history across, once, before anything reads settings or opens storage.
///
/// Nothing is deleted. ~/.diskmap is copied rather than moved because the companion
/// command-line tool still uses it; the activity store is moved because only the app
/// reads it and it can be large.
enum LegacyMigration {
    static let legacyBundleID = "local.diskmap.app"
    static let completedKey = "FastMac.MigratedFromDiskMap"

    /// Files FastMac owns inside ~/.diskmap. The CLI's reports and scans stay put.
    static let stateItems = ["queue.json", "cleanup.log", "history"]

    @discardableResult
    static func run(defaults: UserDefaults = .standard,
                    legacyDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyBundleID),
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        guard !defaults.bool(forKey: completedKey) else { return [] }
        var log: [String] = []

        for (key, value) in legacyDefaults ?? [:] {
            guard let renamed = renamedKey(key), defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
            log.append("setting \(renamed)")
        }

        let fm = FileManager.default
        let oldState = home.appendingPathComponent(".diskmap", isDirectory: true)
        let newState = home.appendingPathComponent(".fastmac", isDirectory: true)
        for item in stateItems {
            let source = oldState.appendingPathComponent(item)
            let target = newState.appendingPathComponent(item)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: newState, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                log.append("copied ~/.diskmap/\(item)")
            } catch {
                log.append("could not copy ~/.diskmap/\(item): \(error.localizedDescription)")
            }
        }

        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let oldSupport = support.appendingPathComponent("DiskMap", isDirectory: true)
        let newSupport = support.appendingPathComponent("FastMac", isDirectory: true)
        if fm.fileExists(atPath: oldSupport.path), !fm.fileExists(atPath: newSupport.path) {
            do {
                try fm.moveItem(at: oldSupport, to: newSupport)
                log.append("moved Application Support/DiskMap")
            } catch {
                log.append("could not move Application Support/DiskMap: \(error.localizedDescription)")
            }
        }

        defaults.set(true, forKey: completedKey)
        return log
    }

    /// "DiskMap.X" → "FastMac.X" and "diskmap.settings.X" → "fastmac.settings.X".
    /// AppKit's own keys (window frames, panel state) are left behind.
    static func renamedKey(_ key: String) -> String? {
        if key.hasPrefix("DiskMap.") { return "FastMac." + key.dropFirst("DiskMap.".count) }
        if key.hasPrefix("diskmap.") { return "fastmac." + key.dropFirst("diskmap.".count) }
        return nil
    }
}

enum LegacyMigrationSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(name)") }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("fastmac-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let suite = "com.fastmac.migrationcheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["FAIL  migration defaults suite"] }
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldState = home.appendingPathComponent(".diskmap", isDirectory: true)
        let oldActivity = home.appendingPathComponent("Library/Application Support/DiskMap/Activity", isDirectory: true)
        try? fm.createDirectory(at: oldState.appendingPathComponent("history"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: oldActivity, withIntermediateDirectories: true)
        try? Data("[]".utf8).write(to: oldState.appendingPathComponent("queue.json"))
        try? Data("cli".utf8).write(to: oldState.appendingPathComponent("report-baseline.html"))
        try? Data("{}".utf8).write(to: oldActivity.appendingPathComponent("samples.json"))
        defaults.set(false, forKey: "FastMac.StartInMenuBar")

        let log = LegacyMigration.run(defaults: defaults,
            legacyDefaults: ["DiskMap.OnboardingCompleted": true, "DiskMap.StartInMenuBar": true,
                             "diskmap.settings.bigFileThresholdMB": 250, "NSWindow Frame DiskMapMain": "0 0 1 1"],
            home: home)
        let newState = home.appendingPathComponent(".fastmac", isDirectory: true)

        check("DiskMap settings carry over under FastMac keys",
              defaults.bool(forKey: "FastMac.OnboardingCompleted")
              && defaults.integer(forKey: "fastmac.settings.bigFileThresholdMB") == 250)
        check("a FastMac setting already chosen is not overwritten",
              defaults.object(forKey: "FastMac.StartInMenuBar") as? Bool == false)
        check("AppKit window state is not copied",
              defaults.object(forKey: "NSWindow Frame DiskMapMain") == nil)
        check("cleanup queue and scan history are copied, CLI files stay behind",
              fm.fileExists(atPath: newState.appendingPathComponent("queue.json").path)
              && fm.fileExists(atPath: newState.appendingPathComponent("history").path)
              && !fm.fileExists(atPath: newState.appendingPathComponent("report-baseline.html").path))
        check("~/.diskmap is copied, never removed",
              fm.fileExists(atPath: oldState.appendingPathComponent("queue.json").path))
        check("activity history moves to Application Support/FastMac",
              fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/FastMac/Activity/samples.json").path)
              && !fm.fileExists(atPath: oldActivity.path))
        check("migration reports what it did", log.count >= 5)
        check("migration runs only once", LegacyMigration.run(defaults: defaults, legacyDefaults: ["DiskMap.MenuBarEnabled": false], home: home).isEmpty
              && defaults.object(forKey: "FastMac.MenuBarEnabled") == nil)
        check("restoring an item disabled before the rename uses its old suffix",
              Privileged.restoreLaunchItem(path: "/Library/LaunchDaemons/com.example.helper.plist", label: "helper",
                  exists: { $0.hasSuffix(".diskmap-disabled") })?.shell.contains(".diskmap-disabled") == true)
        check("new disables use the FastMac suffix",
              Privileged.disableLaunchItem(path: "/Library/LaunchDaemons/com.example.helper.plist", label: "helper")?
                  .shell.contains(".fastmac-disabled") == true)
        return lines
    }
}
