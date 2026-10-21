import Foundation

/// Lifecycle and UI mutation fixtures. Sampling is injected and every repository
/// lives under a temporary directory; these checks never change app preferences.
enum ActivityMonitorSelfCheck {
    private final class SamplerFixture: @unchecked Sendable {
        private let lock = NSLock()
        private let firstGate = DispatchSemaphore(value: 0)
        private let blocksFirst: Bool
        private var requests: [String] = []
        private var finished = 0

        init(blocksFirst: Bool) { self.blocksFirst = blocksFirst }
        var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
        var completed: Int { lock.lock(); defer { lock.unlock() }; return finished }
        var sessions: [String] { lock.lock(); defer { lock.unlock() }; return requests }
        func releaseFirst() { firstGate.signal() }
        func sample(_ session: String) -> (ActivitySnapshot, Double) {
            lock.lock()
            requests.append(session)
            let number = requests.count
            lock.unlock()
            if blocksFirst && number == 1 { _ = firstGate.wait(timeout: .now() + 4) }
            let result = ActivityMonitorSelfCheck.snapshot(
                at: Date(timeIntervalSince1970: 1_800_000_000 + Double(number * 60)),
                session: session, cpu: Double(number))
            lock.lock(); finished += 1; lock.unlock()
            return (result, 0.75)
        }
    }

    private static func snapshot(at: Date, session: String = "fixture-session", cpu: Double = 10) -> ActivitySnapshot {
        ActivitySnapshot(sampledAt: at, sessionID: session,
            cpuPercent: cpu, memoryUsed: 1024, memoryTotal: 4096, swapUsed: 0,
            memoryPressure: "normal", diskFree: 50, diskTotal: 100,
            diskReadRate: nil, diskWriteRate: nil, networkDownloadRate: nil,
            networkUploadRate: nil, networkScope: "fixture", batteryPercent: nil,
            gpuPercent: nil, thermalState: "Nominal", readableProcesses: 1, listedProcesses: 1,
            apps: [ActivityAppSnapshot(id: "fixture.app", name: "Fixture App",
                                       cpuPercent: cpu, rss: 1024, processCount: 1)])
    }

    @MainActor
    static func run() async -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": " + detail)")
        }
        func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return predicate()
        }
        func moments(_ repository: ActivityRepository) async -> ([ActivityBookmark], String?) {
            await withCheckedContinuation { continuation in
                repository.bookmarks { continuation.resume(returning: ($0, $1)) }
            }
        }
        func append(_ repository: ActivityRepository, _ sample: ActivitySnapshot) async -> String? {
            await withCheckedContinuation { continuation in
                repository.append(sample, retentionDays: 30) { continuation.resume(returning: $0) }
            }
        }
        func store(_ repository: ActivityRepository, _ values: [ActivityBookmark]) async -> String? {
            await withCheckedContinuation { continuation in
                repository.saveBookmarks(values) { continuation.resume(returning: $0) }
            }
        }
        let preferenceKeys = [Settings.startInMenuBarKey, Settings.healthMonitoringEnabledKey,
            Settings.menuBarSummaryEnabledKey, Settings.menuBarMetricKey, Settings.recordActivityHistoryKey,
            Settings.activityRetentionDaysKey, Settings.notificationsEnabledKey]
        func preferences() -> [String: String] {
            Dictionary(uniqueKeysWithValues: preferenceKeys.map {
                ($0, UserDefaults.standard.object(forKey: $0).map { String(describing: $0) } ?? "<unset>")
            })
        }
        let initialPreferences = preferences()
        let continuityAt = Date(timeIntervalSince1970: 1_800_000_000)
        func interval(_ currentUptime: TimeInterval, _ seconds: TimeInterval,
                      priorUptime: TimeInterval? = 100, priorAt: Date? = nil) -> TimeInterval? {
            ActivitySamplingContinuity.elapsed(currentUptime: currentUptime,
                currentAt: continuityAt.addingTimeInterval(seconds), previousUptime: priorUptime,
                previousAt: priorAt ?? continuityAt)
        }
        check("first sample has no rate interval", interval(115, 15, priorUptime: nil) == nil)
        check("normal 15-second sampling preserves a monotonic rate interval", interval(115, 15) == 15)
        check("a missed 90-second interval breaks sampling continuity", interval(190, 90) == nil)
        check("sleep breaks continuity when uptime advances less than wall time", interval(115, 300) == nil)
        check("backwards wall clock breaks sampling continuity", interval(115, -15) == nil)
        check("backwards uptime breaks sampling continuity", interval(90, 15) == nil)
        check("a forward clock jump cannot distort rate continuity", interval(115, 30) == nil)
        check("non-finite uptime is unavailable", interval(.infinity, 15) == nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastmac-monitor-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func folder(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

        // Keep the periodic interval longer than this check: a successful resumed
        // sample must come from retrying the stale request, not waiting for a timer.
        let blocked = SamplerFixture(blocksFirst: true)
        defer { blocked.releaseFirst() }
        let isolated = ActivityRepository(directory: folder("no-persistence"))
        let resumed = ActivityMonitor(repository: isolated, allowsPersistence: false,
            sampleProvider: { blocked.sample($0) }, samplingInterval: 10)
        defer { resumed.stop() }
        resumed.start()
        let began = await waitUntil { blocked.count == 1 }
        check("monitor starts the injected sampler without kernel reads", began && resumed.isMonitoring)
        resumed.start()
        for _ in 0..<10 { resumed.refresh() }
        check("repeated start and refresh keep one sample in flight", blocked.count == 1)
        resumed.stop()
        check("pause immediately disables monitoring", !resumed.isMonitoring)
        resumed.start()
        blocked.releaseFirst()
        let recovered = await waitUntil { resumed.latest?.cpuPercent == 2 }
        check("resume retries immediately after discarding a paused in-flight sample", recovered && blocked.count == 2)
        check("resumed sampling uses a fresh collection session", blocked.sessions.count == 2
              && blocked.sessions[0] != blocked.sessions[1]
              && resumed.latest?.sessionID == blocked.sessions.last)
        check("sampler cost comes from the injected result", resumed.probeMilliseconds == 0.75)
        resumed.stop()

        let pausedFixture = SamplerFixture(blocksFirst: true)
        defer { pausedFixture.releaseFirst() }
        let paused = ActivityMonitor(repository: isolated, allowsPersistence: false,
            sampleProvider: { pausedFixture.sample($0) }, samplingInterval: 10)
        defer { paused.stop() }
        paused.start()
        _ = await waitUntil { pausedFixture.count == 1 }
        paused.stop()
        pausedFixture.releaseFirst()
        _ = await waitUntil { pausedFixture.completed == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("a pending sample cannot publish after pause", paused.latest == nil && pausedFixture.count == 1)

        let ticking = SamplerFixture(blocksFirst: false)
        let periodic = ActivityMonitor(repository: isolated, allowsPersistence: false,
            sampleProvider: { ticking.sample($0) }, samplingInterval: 0.02)
        defer { periodic.stop() }
        periodic.start()
        check("configured timer produces periodic fixture samples", await waitUntil { ticking.count >= 3 })
        periodic.stop()
        // Allow a sample already queued before pause to finish; the assertion is
        // that the invalidated timer cannot initiate additional work afterward.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let pausedCount = ticking.count
        try? await Task.sleep(nanoseconds: 120_000_000)
        check("timer callbacks do not sample after pause", ticking.count == pausedCount && !periodic.isMonitoring)
        resumed.loadHistory(hours: 24)
        resumed.reloadBookmarks()
        resumed.clearHistory()
        resumed.applyRetention(days: 1)
        resumed.saveMoment(note: "must not save")
        if let sample = resumed.latest { resumed.deleteMoment(ActivityBookmark(note: "fixture", snapshot: sample)) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        check("disabled persistence does not create or mutate its repository", !FileManager.default.fileExists(atPath: isolated.directory.path))

        let sample = snapshot(at: Date().addingTimeInterval(-60))
        let repository = ActivityRepository(directory: folder("moments"))
        check("mutation fixture history can be saved", await append(repository, sample) == nil)
        let monitor = ActivityMonitor(repository: repository, initialHistory: [sample])
        defer { monitor.stop() }
        // These occur before repository callbacks can update the main actor.
        monitor.saveMoment(note: "A")
        monitor.saveMoment(note: "B")
        check("rapid saved moments are visible optimistically", monitor.bookmarks.map(\.note) == ["A", "B"])
        let rapid = await moments(repository)
        check("rapid saved moments persist without overwriting one another", rapid.1 == nil && rapid.0.map(\.note) == ["A", "B"])
        check("a pending initial bookmark reload cannot overwrite newer moments", monitor.bookmarks.map(\.note) == ["A", "B"])
        if let first = monitor.bookmarks.first { monitor.deleteMoment(first) }
        monitor.saveMoment(note: "C")
        monitor.saveMoment(note: "D")
        let edited = await moments(repository)
        check("rapid deletion followed by saves preserves the final mutation", edited.1 == nil
              && edited.0.map(\.note) == ["B", "C", "D"] && monitor.bookmarks.map(\.note) == ["B", "C", "D"])

        monitor.saveMoment(note: "discard")
        monitor.reloadBookmarks()
        monitor.loadHistory(hours: 24)
        monitor.clearHistory()
        check("clear removes visible history and moments immediately", monitor.history.isEmpty && monitor.bookmarks.isEmpty && !monitor.loading)
        monitor.saveMoment(note: "after-clear", snapshot: sample)
        let cleared = await moments(repository)
        check("pending pre-clear callbacks cannot restore old history or moments", monitor.history.isEmpty
              && monitor.bookmarks.map(\.note) == ["after-clear"] && cleared.0.map(\.note) == ["after-clear"] && cleared.1 == nil)
        monitor.loadHistory(hours: 24)
        _ = await waitUntil { !monitor.loading }
        check("cleared history remains empty on a fresh read", monitor.history.isEmpty)

        // A regular file cannot become a repository directory. This is a reliable
        // I/O failure without reaching outside the temporary fixture namespace.
        do {
            let badPath = folder("not-a-directory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: badPath)
            let bad = ActivityMonitor(repository: ActivityRepository(directory: badPath), initialHistory: [sample])
            defer { bad.stop() }
            bad.saveMoment(note: "cannot persist")
            check("failed saved moment is initially represented optimistically", bad.bookmarks.count == 1)
            let rolledBack = await waitUntil { bad.error != nil && bad.bookmarks.isEmpty }
            check("failed bookmark write rolls back its matching mutation", rolledBack)
        } catch { check("bookmark failure fixture created", false, error.localizedDescription) }

        // Read/execute without directory write permission lets clear discover its
        // own files, then fail deletion, exercising restoration after an I/O error.
        do {
            let readOnly = folder("read-only")
            let repository = ActivityRepository(directory: readOnly)
            let prior = [ActivityBookmark(note: "keep on failed clear", snapshot: sample)]
            let savedHistory = await append(repository, sample)
            let savedMoments = await store(repository, prior)
            guard savedHistory == nil && savedMoments == nil else {
                check("clear rollback fixtures save", false)
                return lines
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
            if FileManager.default.isWritableFile(atPath: readOnly.path) {
                lines.append("SKIP  clear failure rollback: execution account bypasses fixture directory permissions")
            } else {
                let failed = ActivityMonitor(repository: repository, initialHistory: [sample], initialBookmarks: prior)
                defer { failed.stop() }
                failed.clearHistory()
                check("clear is optimistic before its repository result", failed.history.isEmpty && failed.bookmarks.isEmpty)
                let restored = await waitUntil { failed.error != nil && failed.history.count == 1 && failed.bookmarks.count == 1 }
                check("failed clear restores its matching prior history and moments", restored
                      && failed.bookmarks.first?.note == prior[0].note)
            }
        } catch { check("clear rollback fixture created", false, error.localizedDescription) }
        check("monitor lifecycle checks leave app preferences unchanged", preferences() == initialPreferences)
        lines.append("PASS  monitor lifecycle diagnostics use injected samples and isolated repositories only")
        return lines
    }
}
