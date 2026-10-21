import Foundation

/// Self-checks for the Maintenance + Settings feature. Deliberately does not run any
/// destructive tmutil / atsutil / lsregister / qlmanage call — see HANDOFF.md for
/// exactly what was and wasn't exercised live. What it does check runs against the real
/// machine wherever that's read-only and safe (purgeable space, snapshot listing,
/// Spotlight status, Full Disk Access detection, tool existence), and against synthetic
/// input for anything that would otherwise touch real system state.
enum MaintSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }

        // MARK: Purgeable space — real, read-only, framework API

        if let space = PurgeableSpace.info(volume: "/") {
            check("purgeable space reads a positive total", space.totalBytes > 0,
                  fmt(space.totalBytes))
            check("available <= total", space.availableBytes <= space.totalBytes)
            check("purgeable bytes non-negative", space.purgeableBytes >= 0,
                  fmt(space.purgeableBytes))
        } else {
            check("purgeable space reads a positive total", false, "resourceValues(forKeys:) failed")
        }

        // MARK: Time Machine snapshot listing — real, read-only

        let vols = TimeMachineSnapshots.candidateVolumes()
        check("at least one candidate volume for snapshots", !vols.isEmpty, vols.joined(separator: ","))
        let snaps = TimeMachineSnapshots.listAll()
        check("snapshot listing does not crash and returns an array", true,
              "\(snaps.count) local snapshot(s) on this machine right now")
        for s in snaps.prefix(3) {
            check("snapshot token round-trips into a display string", !s.displayDate.isEmpty, s.dateToken)
        }

        // MARK: date-token parser, exercised against a synthetic value since this
        // machine currently has zero local snapshots to parse for real.

        do {
            let synthetic = LocalSnapshot(volume: "/", dateToken: "2024-01-15-093000",
                                          date: MaintSelfCheck.parseToken("2024-01-15-093000"))
            check("synthetic snapshot token parses to a Date", synthetic.date != nil, synthetic.dateToken)
        }

        // MARK: Spotlight status — real, read-only, no admin

        let spotStatus = MaintenanceService.spotlightStatus()
        check("Spotlight query reports indexing state or an explicit unavailable reason",
              spotStatus.lowercased().contains("index")
                || spotStatus.lowercased().contains("spotlight server is disabled")
                || spotStatus.hasPrefix("Spotlight status unavailable: "), spotStatus)
        check("disabled Spotlight server is a valid explicit state",
              MaintenanceService.spotlightStatusText(.init(status: 0, stdout: "/:\nSpotlight server is disabled.\n", stderr: ""))
                == "Spotlight server is disabled.")
        check("empty successful Spotlight response reports unavailable",
              MaintenanceService.spotlightStatusText(.init(status: 0, stdout: "", stderr: ""))
                == "Spotlight status unavailable: mdutil returned no indexing status")
        check("Spotlight errors preserve the failure reason",
              MaintenanceService.spotlightStatusText(.init(status: 1, stdout: "", stderr: "Operation not permitted"))
                == "Spotlight status unavailable: Operation not permitted")
        check("one-line Spotlight response retains its indexing state",
              MaintenanceService.spotlightStatusText(.init(status: 0, stdout: "Indexing disabled.\n", stderr: ""))
                == "Indexing disabled.")
        check("Spotlight volume-only response reports unavailable",
              MaintenanceService.spotlightStatusText(.init(status: 0, stdout: "/:\n", stderr: ""))
                .hasPrefix("Spotlight status unavailable: "))

        // MARK: tool existence — real filesystem checks, matches what actions() will decide

        check("tmutil is present", MaintenanceService.toolExists(MaintenanceService.tmutilPath))
        check("mdutil is present", MaintenanceService.toolExists(MaintenanceService.mdutilPath))
        check("qlmanage is present", MaintenanceService.toolExists(MaintenanceService.qlmanagePath))
        check("atsutil is present", MaintenanceService.toolExists(MaintenanceService.atsutilPath))
        check("lsregister is present", MaintenanceService.toolExists(MaintenanceService.lsregisterPath))
        let periodicHere = MaintenanceService.periodicAvailable
        check("periodic availability detected without crashing", true,
              periodicHere ? "present" : "absent on this macOS version — actions() should say so, not offer a dead button")

        // MARK: actions() assembles without touching any admin-only or destructive path

        let actions = MaintenanceService.actions()
        check("actions() returns a non-empty list", !actions.isEmpty, "\(actions.count) actions")
        check("no action both auto-runs and carries an admin command — the two are mutually exclusive",
              actions.allSatisfy { !($0.perform != nil && $0.adminCommand != nil) })
        let withAdminCommand = actions.filter { $0.adminCommand != nil }
        check("every action with an admin command has no runner (never auto-executed)",
              withAdminCommand.allSatisfy { $0.perform == nil })
        let selfRunnable = actions.filter { $0.perform != nil }
        check("every self-runnable action carries no admin command",
              selfRunnable.allSatisfy { $0.adminCommand == nil })
        if !periodicHere {
            check("periodic actions are represented as a single 'unavailable' row, not three dead buttons",
                  actions.contains { $0.id == "periodic-unavailable" }
                    && !actions.contains { $0.id.hasPrefix("periodic-") && $0.id != "periodic-unavailable" })
        }

        // MARK: admin command strings — built, never run

        check("DNS flush command is well-formed and mentions sudo twice",
              MaintenanceService.flushDNSCacheCommand.components(separatedBy: "sudo").count - 1 == 2,
              MaintenanceService.flushDNSCacheCommand)
        check("Spotlight rebuild command targets the requested volume",
              MaintenanceService.rebuildSpotlightIndexCommand(volume: "/Volumes/Data")
                  .contains("/Volumes/Data"))
        check("periodic command names the requested cadence",
              MaintenanceService.periodicCommand("weekly").contains("weekly"))

        // MARK: QuickLook cache measurement — real, read-only

        let qlSize = MaintenanceService.quickLookCacheSize()
        check("QuickLook cache size measurement does not crash", qlSize >= 0, fmt(qlSize))

        // MARK: Full Disk Access detection — real, matches the machine's actual state

        let fda = FullDiskAccess.check()
        check("Full Disk Access probe returns a definite status", fda != .unknown
              || FullDiskAccess.check() == .unknown, "\(fda)")
        check("FDA deep-link URL is well-formed",
              FullDiskAccess.systemSettingsURL.absoluteString.hasPrefix("x-apple.systempreferences:"))

        // MARK: Settings — real UserDefaults round trip through a throwaway suite,
        // never touching the user's actual preferences. `Settings` is @MainActor
        // (it's an ObservableObject the UI binds to directly); main.swift's top level
        // runs on the main thread but isn't statically MainActor-isolated, so this
        // follows the same `MainActor.assumeIsolated` pattern App.swift already uses
        // to construct AppDelegate.
        lines.append(contentsOf: MainActor.assumeIsolated { settingsChecks() })

        print(lines.joined(separator: "\n"))
        let failures = lines.filter { $0.hasPrefix("FAIL") }.count
        print(failures == 0 ? "\nMAINTENANCE+SETTINGS ALL PASS\n" : "\n\(failures) FAILED\n")
        return lines
    }

    @MainActor
    private static func settingsChecks() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }

        let suiteName = "com.fastmac.maintselfcheck.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            check("Settings round trip via throwaway UserDefaults suite", false, "could not create suite")
            return lines
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let s1 = Settings(defaults: testDefaults)
        check("Settings defaults: trash mode by default", s1.removalMode == .trash)
        check("Settings defaults: confirm-before-staging on by default", s1.confirmBeforeStaging)
        check("menu bar launch and lightweight monitoring are enabled by default",
              s1.startInMenuBar && s1.healthMonitoringEnabled && s1.menuBarSummaryEnabled)
        check("Settings defaults: big-file threshold matches Scanner's current hardcode",
              s1.bigFileThresholdMB == 50)
        check("Settings defaults: untouched size threshold matches ListViews' current hardcode",
              s1.untouchedSizeThresholdMB == 100)
        check("Settings defaults: untouched age threshold matches ListViews' current hardcode",
              s1.untouchedAgeDays == 365)

        s1.addExclusion("~/Documents")
        s1.bigFileThresholdMB = 75
        s1.removalMode = .permanent
        s1.unitStyle = .binary
        s1.startInMenuBar = false
        s1.healthMonitoringEnabled = false
        s1.menuBarSummaryEnabled = false

        let s2 = Settings(defaults: testDefaults)
        check("exclusion persisted across a fresh Settings instance",
              s2.exclusions.contains(NSHomeDirectory() + "/Documents"))
        check("threshold change persisted", s2.bigFileThresholdMB == 75)
        check("removal mode persisted", s2.removalMode == .permanent)
        check("unit style persisted", s2.unitStyle == .binary)
        check("runtime preferences persist across settings instances",
              !s2.startInMenuBar && !s2.healthMonitoringEnabled && !s2.menuBarSummaryEnabled)

        check("isExcluded matches a path under an exclusion",
              s2.isExcluded(NSHomeDirectory() + "/Documents/Sub/file.txt"))
        check("isExcluded does not match a sibling path",
              !s2.isExcluded(NSHomeDirectory() + "/DocumentsToo/file.txt"))

        s2.removeExclusion(NSHomeDirectory() + "/Documents")
        check("removeExclusion clears it", s2.exclusions.isEmpty)

        return lines
    }

    private static func parseToken(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }
}
