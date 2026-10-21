import ApplicationServices
import Darwin
import Foundation

/// Pure fixtures; no application messages, permission prompts or quit requests.
enum QuickActionsSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(label)") }
        let now = Date(timeIntervalSince1970: 20_000)
        let identity = ProcessIdentity(pid: 99_900, uid: 501, startedSeconds: 19_000,
            startedMicroseconds: 3, path: "/Applications/Fixture.app/Contents/MacOS/Fixture")
        let app = QuickActionApp(name: "Fixture", bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"),
                                 icon: nil, identity: identity)
        func eligible(_ value: ProcessIdentity?, regular: Bool = true, exited: Bool = false,
                      bundle: String? = "test.fixture") -> Bool {
            QuickActionsPolicy.isEligible(identity: value, isRegular: regular, isTerminated: exited,
                                           bundleID: bundle, currentUID: 501, currentPID: 123)
        }
        func changed(pid: pid_t = 99_900, uid: uid_t = 501, started: UInt64 = 19_000,
                     path: String = identity.path) -> ProcessIdentity {
            ProcessIdentity(pid: pid, uid: uid, startedSeconds: started, startedMicroseconds: 3, path: path)
        }
        check("quick actions include an owned regular app", eligible(identity))
        check("quick actions omit background and accessory apps", !eligible(identity, regular: false))
        check("quick actions omit exited apps", !eligible(identity, exited: true))
        check("quick actions require readable stable identity", !eligible(nil) && !eligible(changed(started: 0)))
        check("quick actions exclude other users", !eligible(changed(uid: 502)))
        check("quick actions exclude FastMac itself", !eligible(changed(pid: 123)))
        check("quick actions exclude PID zero and launchd", !eligible(changed(pid: 0)) && !eligible(changed(pid: 1)))
        check("quick actions require executable identity", !eligible(changed(path: "")))
        check("quick actions protect Finder and desktop services", !eligible(identity, bundle: "com.apple.finder")
            && !eligible(identity, bundle: "com.apple.dock") && !eligible(identity, bundle: "com.apple.loginwindow"))
        check("ordinary Apple apps remain eligible", eligible(identity, bundle: "com.apple.Safari"))
        check("bundle-less regular app remains eligible", eligible(identity, bundle: nil))

        let measured = ActivityAppSnapshot(id: app.appKey, name: "Fixture", cpuPercent: 150,
                                           rss: 900_000_000, processCount: 4)
        var snapshot = ActivitySnapshot(sampledAt: now, sessionID: "fixture", cpuPercent: 20,
            memoryUsed: 1, memoryTotal: 2, swapUsed: 0, memoryPressure: "normal", diskFree: 1,
            diskTotal: 2, diskReadRate: nil, diskWriteRate: nil, networkDownloadRate: nil,
            networkUploadRate: nil, networkScope: "fixture", batteryPercent: nil,
            gpuPercent: nil, thermalState: "nominal", readableProcesses: 4, listedProcesses: 4, apps: [measured])
        let populated = QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot, now: now)
        check("quick metrics match stable bundle path", populated.residentBytes == 900_000_000 && populated.processCount == 4)
        check("quick app CPU retains one-core values above 100 percent", populated.cpuPercent == 150)
        check("shared app memory explicitly includes helpers", populated.memoryIncludesHelpers)
        check("missing sample keeps CPU and memory unavailable", QuickActionsPolicy.applyMetrics(to: populated, snapshot: nil, now: now).residentBytes == nil)
        var mainOnly = app
        mainOnly.mainResidentBytes = 300_000_000
        mainOnly.mainResidentAt = now
        let fallback = QuickActionsPolicy.applyMetrics(to: mainOnly, snapshot: nil, now: now)
        check("fresh main-app RSS remains useful without a shared leading-app sample", fallback.residentBytes == 300_000_000)
        check("main-only memory scope does not imply helpers", !fallback.memoryIncludesHelpers && fallback.cpuPercent == nil)
        check("helper total replaces rather than adds to main RSS", QuickActionsPolicy.applyMetrics(to: mainOnly, snapshot: snapshot, now: now).residentBytes == 900_000_000)
        check("duplicate bundle instances avoid duplicating aggregate metrics", QuickActionsPolicy.applyMetrics(to: mainOnly,
            snapshot: snapshot, duplicateAppKeys: [app.appKey], now: now).residentBytes == 300_000_000)
        let staleAt = now.addingTimeInterval(QuickActionsPolicy.metricsMaximumAge + 1)
        check("stale shared metrics become unavailable", QuickActionsPolicy.applyMetrics(to: populated, snapshot: snapshot, now: staleAt).cpuPercent == nil)
        check("stale main RSS becomes unavailable", QuickActionsPolicy.applyMetrics(to: mainOnly, snapshot: nil, now: staleAt).residentBytes == nil)
        snapshot.sampledAt = now.addingTimeInterval(60)
        check("future samples are not shown as live measurements", QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot, now: now).cpuPercent == nil)
        snapshot.sampledAt = Date(timeIntervalSince1970: 18_999)
        check("an older app launch's sample is not mapped to its replacement", QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot,
            now: Date(timeIntervalSince1970: 19_001)).residentBytes == nil)
        snapshot.sampledAt = now
        snapshot.apps = [ActivityAppSnapshot(id: "/Elsewhere/Fixture.app", name: "Fixture", cpuPercent: 30, rss: 20, processCount: 1)]
        check("same-name app copies never borrow metrics", QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot, now: now).residentBytes == nil)
        snapshot.apps = [ActivityAppSnapshot(id: app.appKey, name: "Fixture", cpuPercent: 0, rss: 0, processCount: 1)]
        let idle = QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot, now: now)
        check("measured zero remains distinct from unavailable", idle.cpuPercent == 0 && idle.residentBytes == 0)
        snapshot.apps = [ActivityAppSnapshot(id: app.appKey, name: "Fixture", cpuPercent: .infinity, rss: -1, processCount: 0)]
        let invalid = QuickActionsPolicy.applyMetrics(to: app, snapshot: snapshot, now: now)
        check("invalid metric values stay unavailable", invalid.cpuPercent == nil && invalid.residentBytes == nil && invalid.processCount == nil)

        check("a successful role reply is recorded", QuickActionsPolicy.classify([(.success, 0.01)], identityValid: true) == .responded)
        check("a reused or exited PID invalidates even a successful reply", QuickActionsPolicy.classify([(.success, 0.01)], identityValid: false) == .unavailable)
        check("one timeout is not classified as non-response", QuickActionsPolicy.classify([(.cannotComplete, 0.26)], identityValid: true) == .unavailable)
        check("two quick messaging failures stay unknown", QuickActionsPolicy.classify([(.cannotComplete, 0.01), (.cannotComplete, 0.01)], identityValid: true) == .unavailable)
        check("two slow failures produce carefully scoped non-response", QuickActionsPolicy.classify([(.cannotComplete, 0.26), (.cannotComplete, 0.26)], identityValid: true) == .didNotRespond)
        check("a reply after retry clears the timeout suspicion", QuickActionsPolicy.classify([(.cannotComplete, 0.26), (.success, 0.01)], identityValid: true) == .responded)
        check("mixed slow and quick failures remain unknown", QuickActionsPolicy.classify([(.cannotComplete, 0.26), (.cannotComplete, 0.01)], identityValid: true) == .unavailable)
        for error in [AXError.apiDisabled, .attributeUnsupported, .noValue, .invalidUIElement, .notImplemented, .failure] {
            check("Accessibility failure \(error.rawValue) remains unknown", QuickActionsPolicy.classify([(error, 0.26), (error, 0.26)], identityValid: true) == .unavailable)
        }
        check("the status never calls an app frozen", !QuickAppResponse.didNotRespond.label.lowercased().contains("frozen"))
        var highMemory = populated
        highMemory.name = "High memory"
        var missed = app
        missed.identity = changed(pid: 99_901)
        missed.response = .didNotRespond
        let sorted = QuickActionsPolicy.sorted([highMemory, app, missed])
        check("apps missing two replies appear before high-memory apps", sorted.first?.id == missed.id)
        check("known memory sorts above unknown memory", sorted.dropFirst().first?.residentBytes == 900_000_000)
        var relaunched = app
        relaunched.identity = changed(started: 19_999)
        check("row identity changes across PID reuse", relaunched.id != app.id)
        check("a high-CPU or high-memory app is never automatically marked frozen", populated.response == .unchecked)
        missed.responseCheckedAt = now.addingTimeInterval(-61)
        let expired = QuickActionsPolicy.applyMetrics(to: missed, snapshot: nil, now: now)
        check("an old response check does not leave Force Quit as the suggested action", expired.response == .unchecked && expired.responseCheckedAt == nil)
        missed.responseCheckedAt = now.addingTimeInterval(60)
        check("a response timestamp from a clock jump is not considered current", QuickActionsPolicy.applyMetrics(to: missed,
            snapshot: nil, now: now).response == .unchecked)
        check("a bounded check has a positive per-app and total budget", QuickActionsPolicy.requestTimeout > 0
            && QuickActionsPolicy.maximumCheckDuration <= 8 && QuickActionsPolicy.maximumCheckedApps <= 32)
        return lines
    }
}
