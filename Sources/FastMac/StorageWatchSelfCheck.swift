import Foundation

/// The storage watch decides what to put in front of someone and, for the temp folder,
/// what to move. These checks pin both: the projection must not cry wolf, the detector
/// must never pick up a profile a browser is using, and a clear must re-validate.
enum StorageWatchSelfCheck {
    static func run() -> [String] {
        var out: [String] = []
        func check(_ ok: Bool, _ label: String) { out.append("\(ok ? "PASS" : "FAIL") storage watch: \(label)") }
        let gb: Int64 = 1_073_741_824
        let now = Date()

        // MARK: Trend

        var few = FreeSpaceTrend()
        few.record(free: 50 * gb, at: now.addingTimeInterval(-3_600))
        few.record(free: 40 * gb, at: now)
        check(few.declinePerDay(now: now) == nil, "two readings are not enough to project")

        var flat = FreeSpaceTrend()
        for h in stride(from: 48, through: 0, by: -2) { flat.record(free: 60 * gb, at: now.addingTimeInterval(-Double(h) * 3_600)) }
        check(flat.declinePerDay(now: now) == 0, "steady free space reports no decline")
        check(flat.daysUntil(floor: 5 * gb, currentFree: 60 * gb, now: now) == nil, "steady free space projects nothing")

        // Today's real shape: about 7 GB a day out of the temp folder.
        var leak = FreeSpaceTrend()
        for h in stride(from: 72, through: 0, by: -1) {
            leak.record(free: 10 * gb + Int64(Double(h) / 24 * 7 * Double(gb)), at: now.addingTimeInterval(-Double(h) * 3_600))
        }
        let decline = leak.declinePerDay(now: now) ?? 0
        check(abs(decline - 7 * Double(gb)) < 0.05 * 7 * Double(gb), "measures a 7 GB/day decline within 5%")
        let days = leak.daysUntil(floor: 5 * gb, currentFree: 10 * gb, now: now) ?? -1
        check(days > 0.6 && days < 0.8, "projects about 0.7 days to the 5 GB floor")
        check(StorageWatchPolicy.filling(trend: leak, free: 10 * gb, now: now)?.urgency == .critical,
              "a disk full within two days is critical")

        var slow = FreeSpaceTrend()
        for h in stride(from: 72, through: 0, by: -1) {
            slow.record(free: 80 * gb + Int64(Double(h) / 24 * 0.3 * Double(gb)), at: now.addingTimeInterval(-Double(h) * 3_600))
        }
        check(StorageWatchPolicy.filling(trend: slow, free: 80 * gb, now: now) == nil,
              "ordinary daily wobble below 1 GB/day raises nothing")

        // A big cleanup mid-window is growth, not a leak.
        var cleaned = FreeSpaceTrend()
        for h in stride(from: 72, through: 0, by: -1) {
            cleaned.record(free: (h > 36 ? 10 : 70) * gb, at: now.addingTimeInterval(-Double(h) * 3_600))
        }
        check(StorageWatchPolicy.filling(trend: cleaned, free: 70 * gb, now: now) == nil,
              "freeing space mid-window does not read as filling")

        var throttled = FreeSpaceTrend()
        throttled.record(free: 50 * gb, at: now.addingTimeInterval(-600))
        throttled.record(free: 49 * gb, at: now)
        check(throttled.points.count == 1, "readings closer than 30 minutes are merged")

        var aged = FreeSpaceTrend()
        aged.record(free: 50 * gb, at: now.addingTimeInterval(-20 * 86_400))
        aged.record(free: 50 * gb, at: now.addingTimeInterval(86_400 * 2))     // clock skew
        aged.record(free: 50 * gb, at: now)
        check(aged.points.count == 1, "drops readings older than 14 days and readings from the future")

        // MARK: Temp browser profiles, against a real fixture folder

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fastmac-storage-check-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let old = now.addingTimeInterval(-2 * 3_600)
        func profile(_ name: String, marker: String = "Local State", at date: Date, lockPID: pid_t? = nil, bytes: Int = 4_096) -> String {
            let path = root + "/" + name
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            fm.createFile(atPath: path + "/" + marker, contents: Data(count: bytes))
            if let lockPID { try? fm.createSymbolicLink(atPath: path + "/SingletonLock", withDestinationPath: "Rams-MacBook-\(lockPID)") }
            for p in [path + "/" + marker, path] { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: p) }
            return path
        }
        let idle = profile("fbp-idle", at: old, bytes: 200_000)
        let staleLock = profile("probe-stale", marker: "DevToolsActivePort", at: old, lockPID: 1_999_999_999)
        _ = profile("shots-recent", at: now)
        _ = profile("nib-live", at: old, lockPID: getpid())
        let notProfile = root + "/plain-old-folder"
        try? fm.createDirectory(atPath: notProfile, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: notProfile)
        try? fm.createSymbolicLink(atPath: root + "/link-to-idle", withDestinationPath: idle)
        fm.createFile(atPath: root + "/a-file", contents: Data(count: 10))

        let reading = TempBrowserProfiles.read(directory: root, now: now)
        check(Set(reading.idle) == Set([idle, staleLock]), "finds exactly the idle and stale-lock profiles")
        check(reading.active == 2, "counts a recent profile and a live-lock profile as in use")
        check(!reading.idle.contains(notProfile), "ignores folders that are not Chromium profiles")
        check(!reading.idle.contains(root + "/link-to-idle"), "ignores symlinks, even to a real profile")
        check(!reading.estimated && reading.bytes > 0, "measures sizes exactly when there are only a few")
        check(TempBrowserProfiles.lockHolderAlive(root + "/nib-live"), "a lock held by a live process means in use")
        check(!TempBrowserProfiles.lockHolderAlive(staleLock), "a lock from a dead process is stale")

        // Re-validation: a profile picked up again after the reading must be skipped.
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: staleLock + "/DevToolsActivePort")
        var removed: [String] = []
        let result = TempBrowserProfiles.clear(reading.idle, directory: root, now: now, log: false) { url in
            removed.append(url.path); try fm.removeItem(at: url)
        }
        check(result.moved == 1 && result.skipped == 1, "re-validates at clear time and skips a profile that became active")
        check(removed == [idle] && fm.fileExists(atPath: staleLock), "only the still-idle profile is moved")
        let outside = TempBrowserProfiles.clear([root, NSHomeDirectory() + "/Documents", "/tmp"],
                                                directory: root, now: now, log: false) { _ in removed.append("WRONG") }
        check(outside.moved == 0 && !removed.contains("WRONG"), "refuses anything that is not a direct child of the temp folder")

        let many = root + "/many"
        try? fm.createDirectory(atPath: many, withIntermediateDirectories: true)
        for i in 0..<7 {
            let p = many + "/fbp-\(i)"
            try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
            fm.createFile(atPath: p + "/Local State", contents: Data(count: 8_192))
            for q in [p + "/Local State", p] { try? fm.setAttributes([.modificationDate: old], ofItemAtPath: q) }
        }
        let sampled = TempBrowserProfiles.read(directory: many, now: now, sampleLimit: 3)
        check(sampled.idle.count == 7 && sampled.estimated, "estimates from a sample when there are many, and says so")

        // MARK: Policy

        let tiny = TempBrowserProfiles.Reading(idle: ["a", "b"], active: 0, bytes: 2 * 1_048_576)
        check(StorageWatchPolicy.tempProfiles(tiny) == nil, "a couple of small profiles raise nothing")
        let today = TempBrowserProfiles.Reading(idle: (0..<474).map { "p\($0)" }, active: 7, bytes: 21 * gb, estimated: true)
        let found = StorageWatchPolicy.tempProfiles(today)
        check(found?.urgency == .attention && found?.action == .clearTempProfiles, "today's 474 profiles are flagged with a one-click fix")
        check(found?.note.risk == .safe && found?.sizeText?.hasPrefix("about ") == true, "the fix is Safe and the estimate is labelled")

        let chrome = WatchedCache.all.first { $0.id == "chrome" }!
        check(StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: gb, previous: nil), blocked: nil) == nil,
              "a 1 GB cache is not worth mentioning")
        check(StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: 3 * gb, previous: nil), blocked: nil)?.urgency == .comfortable,
              "a 3 GB cache is listed but stays out of the popup")
        check(StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: 6 * gb, previous: nil), blocked: nil)?.urgency == .attention,
              "a 6 GB cache deserves attention")
        check(StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: 3 * gb, previous: gb / 2), blocked: nil)?.urgency == .attention,
              "a cache growing 2.5 GB a day deserves attention")
        check(StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: 6 * gb, previous: nil), blocked: "Quit Google Chrome first.")?.blockedReason
              == "Quit Google Chrome first.", "an open owning app blocks the one-click fix and says why")

        let day: TimeInterval = 86_400
        let apps = [
            AppUse(name: "Xcode", path: "/Applications/Xcode.app", bytes: 4 * gb, lastUsed: nil, installed: now.addingTimeInterval(-400 * day)),
            AppUse(name: "iMovie", path: "/Applications/iMovie.app", bytes: 4 * gb, lastUsed: nil, installed: now.addingTimeInterval(-400 * day)),
            AppUse(name: "Docker", path: "/Applications/Docker.app", bytes: 2 * gb, lastUsed: now.addingTimeInterval(-150 * day), installed: nil),
            AppUse(name: "Fresh", path: "/Applications/Fresh.app", bytes: 3 * gb, lastUsed: nil, installed: now.addingTimeInterval(-10 * day)),
            AppUse(name: "Daily", path: "/Applications/Daily.app", bytes: 3 * gb, lastUsed: now.addingTimeInterval(-day), installed: nil),
            AppUse(name: "Small", path: "/Applications/Small.app", bytes: gb / 4, lastUsed: nil, installed: now.addingTimeInterval(-900 * day)),
            AppUse(name: "Unknown", path: "/Applications/Unknown.app", bytes: 3 * gb, lastUsed: nil, installed: nil),
        ]
        let dormant = DormantApps.select(apps, now: now, excluding: ["/Applications/Xcode.app"]).map(\.name)
        check(dormant == ["iMovie", "Docker"], "flags large apps unused for 4+ months, and nothing else")
        check(!dormant.contains("Xcode"), "never flags the toolchain the command line is using")
        check(StorageWatchPolicy.dormant([])==nil && StorageWatchPolicy.dormant(apps.filter { dormant.contains($0.name) })?.isOpenAction == true,
              "dormant apps open Applications instead of acting from the popup")

        func scan(_ ago: TimeInterval, documents: Int64) -> HistoryEntry {
            HistoryEntry(id: UUID().uuidString, root: NSHomeDirectory(), bytes: documents, files: 1, dirs: 1, elapsed: 1,
                         scannedAt: now.addingTimeInterval(-ago), diskFreeAtScan: nil, diskTotalAtScan: nil,
                         children: [HistoryChild(name: "Documents", path: NSHomeDirectory() + "/Documents", bytes: documents)])
        }
        check(StorageWatchPolicy.staleScan(entries: [], now: now)?.id == "no-scan", "suggests a first scan when there is none")
        check(StorageWatchPolicy.staleScan(entries: [scan(5 * day, documents: 50 * gb)], now: now) == nil, "a recent scan needs no reminder")
        let grown = StorageWatchPolicy.staleScan(entries: [scan(30 * day, documents: 131 * gb), scan(60 * day, documents: 52 * gb)], now: now)
        check(grown?.action == .open(.history) && grown?.detail.contains("Documents grew by") == true,
              "a stale scan names the folder that grew between the last two scans")

        let small = StorageWatchPolicy.cache(chrome, reading: CacheReading(bytes: 3 * gb, previous: nil), blocked: nil)!
        let critical = StorageWatchPolicy.filling(trend: leak, free: 10 * gb, now: now)!
        let calm = StorageWatchPolicy.ranked([small, found!, critical], diskStatus: .comfortable)
        check(calm.map(\.urgency) == [.critical, .attention, .comfortable], "ranks critical, then attention, then the rest")
        check(StorageWatchPolicy.popup(calm).count == 2 && !StorageWatchPolicy.popup(calm).contains { $0.urgency == .comfortable },
              "the popup shows at most two cards and only ones that need attention")
        let tight = StorageWatchPolicy.ranked([small], diskStatus: .critical)
        check(tight.first?.urgency == .attention, "when the disk is tight, a 3 GB win is promoted into the popup")
        check(StorageWatchPolicy.popup(StorageWatchPolicy.ranked([small], diskStatus: .comfortable)).isEmpty,
              "a calm Mac gets a quiet popup")

        check(StorageWatchPolicy.notifiable(found!, previouslyNotified: nil), "a new problem notifies")
        check(!StorageWatchPolicy.notifiable(found!, previouslyNotified: "attention"), "the same problem does not notify twice")
        check(StorageWatchPolicy.notifiable(critical, previouslyNotified: "attention"), "getting worse notifies again")
        let dormantFinding = StorageWatchPolicy.dormant(apps.filter { dormant.contains($0.name) })!
        var promoted = dormantFinding; promoted.urgency = .attention
        check(!StorageWatchPolicy.notifiable(promoted, previouslyNotified: nil), "unused apps never trigger a notification")

        // MARK: Persistence

        let stateURL = URL(fileURLWithPath: root + "/state/storage-watch.json")
        var state = StorageWatchState()
        state.trend = leak
        state.caches["chrome"] = CacheReading(bytes: 5 * gb, previous: 4 * gb)
        state.notified["temp-profiles"] = "attention"
        state.save(to: stateURL)
        let loaded = StorageWatchState.load(from: stateURL)
        check(loaded.trend.points.count == leak.points.count && loaded.caches["chrome"] == state.caches["chrome"]
              && loaded.notified == state.notified, "state survives a save and load")
        try? Data("{\"version\":1,\"trend\":{\"poi".utf8).write(to: stateURL)
        check(StorageWatchState.load(from: stateURL).trend.points.isEmpty, "a truncated state file starts fresh instead of failing")
        try? Data("{\"version\":99}".utf8).write(to: stateURL)
        check(StorageWatchState.load(from: stateURL).version == StorageWatchState.currentVersion,
              "a state file from a newer version is not misread")

        // MARK: The watcher, end to end

        MainActor.assumeIsolated {
            let watch = StorageWatch(persists: false, startsTimers: false)
            var rises: [String] = []
            var deliver = false
            watch.onRise = { finding in rises.append(finding.id); return deliver }
            watch.seed(temp: today, history: [scan(2 * day, documents: 50 * gb)], free: 10 * gb, now: now)
            check(watch.popupFindings.first?.id == "temp-profiles", "the leak reaches the popup")
            check(rises == ["temp-profiles"], "a new problem is offered for notification")
            watch.seed(free: 10 * gb, now: now)
            check(rises.count == 2, "a refused notification (switched off) does not use up the rise")
            deliver = true
            watch.seed(free: 10 * gb, now: now)
            watch.seed(free: 10 * gb, now: now)
            check(rises.count == 3, "once delivered, the same problem stays quiet")
            watch.seed(temp: TempBrowserProfiles.Reading(), free: 10 * gb, now: now)
            check(watch.popupFindings.isEmpty, "the card disappears once the profiles are gone")
            watch.seed(temp: today, free: 10 * gb, now: now)
            check(rises.count == 4, "a problem that comes back notifies again")
        }
        return out
    }
}
