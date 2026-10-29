import Foundation
import Combine
import AppKit
import CoreServices

// MARK: - Storage watch
//
// The health monitor reads free space every 15 seconds but only ever compares it with a
// fixed threshold. That cannot see the thing that actually fills a Mac: steady growth
// somewhere specific. On the machine this was written for, abandoned headless-Chrome
// profiles grew the user temp folder by about 7 GB a day, and the disk went from fine to
// 98% full while the threshold still read "comfortable".
//
// So this watches *rate* and *place*, in three cost tiers:
//   • every 30 minutes, near free: one statfs reading for the trend, and a single-level
//     listing of the temp folder (names and marker files — no size walk);
//   • about once a day, at background priority: sizes of a short fixed list of cache
//     folders, and which large apps have gone unused for months;
//   • never a scan of its own: it reads the summaries saved by scans you ran yourself.
// It never walks your documents, never starts a disk scan, and never deletes outright —
// one-click fixes move things to the Trash, like every other cleanup in FastMac.

// MARK: Findings

struct StorageFinding: Identifiable {
    enum Kind: String, Codable { case filling, tempProfiles, cache, dormantApps, staleScan }

    enum Action: Equatable {
        /// Safe, done from the popup after a confirmation.
        case clearTempProfiles
        case clearCache(id: String)
        /// Anything that needs judgement opens the screen where that judgement is made.
        case open(ViewKind)
    }

    let id: String
    let kind: Kind
    let title: String
    /// The evidence: what was measured, so the claim can be checked.
    let detail: String
    let bytes: Int64?
    /// True when `bytes` comes from sampling rather than measuring every item.
    let estimated: Bool
    var urgency: HealthStatus
    let note: RiskNote
    let action: Action
    let actionTitle: String
    /// Why the one-click action cannot run right now, e.g. the owning app is open.
    let blockedReason: String?

    var isOpenAction: Bool { if case .open = action { return true } else { return false } }
    var isOneClick: Bool { !isOpenAction }

    /// Stable text for change detection without requiring RiskNote to be Equatable.
    var signature: String { "\(id)|\(urgency.rawValue)|\(bytes ?? -1)|\(blockedReason ?? "")" }

    var sizeText: String? {
        guard let bytes else { return nil }
        return (estimated ? "about " : "") + fmt(bytes)
    }
}

// MARK: Free-space trend

/// Free-space readings over time, and an honest forward projection from them.
struct FreeSpaceTrend: Codable {
    struct Point: Codable, Equatable { var at: Date; var free: Int64 }

    var points: [Point] = []

    static let spacing: TimeInterval = 30 * 60
    static let retention: TimeInterval = 14 * 86_400
    static let window: TimeInterval = 72 * 3_600
    /// Below this, daily wobble from swap, purgeable space and APFS housekeeping
    /// is louder than any real trend, so nothing is projected.
    static let minimumDecline: Double = 1_073_741_824

    mutating func record(free: Int64, at now: Date) {
        guard free >= 0 else { return }
        if let last = points.last, last.at <= now, now.timeIntervalSince(last.at) < Self.spacing { return }
        points.append(Point(at: now, free: free))
        // A clock change can leave readings in the future; they would bend the fit.
        points.removeAll { now.timeIntervalSince($0.at) > Self.retention || $0.at > now.addingTimeInterval(60) }
    }

    /// Bytes per day that free space is falling, from a least-squares fit over the last
    /// 72 hours. nil when there are too few readings, or they span too little time, to
    /// support any claim; 0 when free space is steady or growing.
    func declinePerDay(now: Date) -> Double? {
        let recent = points.filter { $0.at <= now && now.timeIntervalSince($0.at) <= Self.window }
        guard recent.count >= 4, let first = recent.first, let last = recent.last,
              last.at.timeIntervalSince(first.at) >= 6 * 3_600 else { return nil }
        let xs = recent.map { $0.at.timeIntervalSince(first.at) / 86_400 }
        let ys = recent.map { Double($0.free) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in xs.indices {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den > 0 else { return nil }
        let slope = num / den
        return slope < 0 ? -slope : 0
    }

    /// Days until free space reaches `floor` at the current rate, or nil when no
    /// meaningful decline is measured.
    func daysUntil(floor: Int64, currentFree: Int64, now: Date) -> Double? {
        guard let decline = declinePerDay(now: now), decline >= Self.minimumDecline else { return nil }
        let room = Double(currentFree - floor)
        return room <= 0 ? 0 : room / decline
    }
}

// MARK: Leftover browser profiles in the temp folder

/// Headless-Chrome test runs that create a profile with `mkdtemp` and never delete it.
///
/// The temp folder is outside the paths `Safety.canDelete` allows, deliberately. This has
/// its own, narrower gate instead: a candidate must be a direct child of *this user's*
/// temp folder, a real directory (not a symlink), recognisably a Chromium profile, and
/// idle — with no browser holding it — at the moment it is moved.
enum TempBrowserProfiles {
    static var directory: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return NSTemporaryDirectory() }
        return String(cString: buffer)
    }

    static let idleAfter: TimeInterval = 30 * 60
    static let markers = ["Local State", "DevToolsActivePort", "Default"]

    struct Reading: Equatable {
        var idle: [String] = []
        var active = 0
        var bytes: Int64 = 0
        var estimated = false
    }

    static func isProfile(_ path: String) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: path + "/" + $0) }
    }

    /// Chromium keeps a `SingletonLock` symlink, "host-pid", in a profile its browser is
    /// using. A live pid means in use, whatever the timestamps say. A stale lock (left by
    /// a killed test run, which is exactly the leak) points at a pid that is gone.
    static func lockHolderAlive(_ path: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path + "/SingletonLock"),
              let last = target.split(separator: "-").last, let pid = pid_t(last), pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM          // exists, owned by someone else
    }

    static func newestActivity(_ path: String) -> Date? {
        let fm = FileManager.default
        let dates = ([path] + markers.map { path + "/" + $0 }).compactMap {
            (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return dates.max()
    }

    static func isIdle(_ path: String, now: Date) -> Bool {
        guard isProfile(path), !lockHolderAlive(path),
              let newest = newestActivity(path) else { return false }
        return now.timeIntervalSince(newest) >= idleAfter
    }

    private static func isDirectChild(_ path: String, of directory: String) -> Bool {
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.path
        let item = URL(fileURLWithPath: path).standardizedFileURL
        guard item.deletingLastPathComponent().path == dir else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) == nil else { return false }
        return true
    }

    /// One listing of the folder. Sizes come from at most `sampleLimit` profiles; with
    /// more than that, the total is an estimate and is labelled as one.
    static func read(directory: String = directory, now: Date = Date(), sampleLimit: Int = 5) -> Reading {
        // One listing with entry types prefetched. A temp folder can hold tens of thousands
        // of small files; only real directories are worth probing for profile markers.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return Reading() }
        var reading = Reading()
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // Keep the caller's spelling of the folder: URL listing resolves /var to
            // /private/var, and a path that changes form between read and clear would
            // no longer match what the user was shown.
            let path = (directory as NSString).appendingPathComponent(entry.lastPathComponent)
            guard isProfile(path) else { continue }
            if isIdle(path, now: now) { reading.idle.append(path) } else { reading.active += 1 }
        }
        reading.idle.sort()
        guard !reading.idle.isEmpty else { return reading }
        if reading.idle.count <= sampleLimit {
            reading.bytes = reading.idle.reduce(0) { $0 + Analysis.sizeOf($1) }
        } else {
            let step = Double(reading.idle.count) / Double(sampleLimit)
            let sample = (0..<sampleLimit).map { reading.idle[Int(Double($0) * step)] }
            let average = Double(sample.reduce(0) { $0 + Analysis.sizeOf($1) }) / Double(sampleLimit)
            reading.bytes = Int64(average * Double(reading.idle.count))
            reading.estimated = true
        }
        return reading
    }

    /// Moves idle profiles to the Trash. Every path is re-validated at the moment it is
    /// moved, so a profile that a new test run picked up after the reading is left alone.
    static func clear(_ paths: [String], directory: String = directory, now: Date = Date(), log: Bool = true,
                      remove: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        -> (moved: Int, skipped: Int, bytes: Int64) {
        var moved = 0, skipped = 0
        var bytes: Int64 = 0
        for path in paths {
            guard isDirectChild(path, of: directory), isIdle(path, now: now) else { skipped += 1; continue }
            let size = Analysis.sizeOf(path)
            do {
                try remove(URL(fileURLWithPath: path))
                moved += 1
                bytes += size
                if log { Audit.log("trashed", bytes: size, path: path) }
            } catch {
                skipped += 1
            }
        }
        return (moved, skipped, bytes)
    }
}

// MARK: Caches that grow back

struct WatchedCache: Identifiable {
    let id: String
    let label: String
    /// Relative to the home folder.
    let paths: [String]
    /// The app that must be closed first, so its cache is not pulled out from under it.
    let ownerBundleID: String?
    /// Or a command-line process name that uses it.
    let ownerProcess: String?
    let ownerName: String?

    static let all: [WatchedCache] = [
        WatchedCache(id: "chrome", label: "Chrome cache", paths: ["/Library/Caches/Google/Chrome"],
                     ownerBundleID: "com.google.Chrome", ownerProcess: nil, ownerName: "Google Chrome"),
        WatchedCache(id: "hyperframes", label: "HyperFrames render cache", paths: ["/.cache/hyperframes"],
                     ownerBundleID: nil, ownerProcess: "hyperframes", ownerName: "HyperFrames"),
        WatchedCache(id: "npm", label: "npm cache", paths: ["/.npm/_cacache"],
                     ownerBundleID: nil, ownerProcess: "npm", ownerName: "npm"),
        WatchedCache(id: "pip", label: "pip cache", paths: ["/Library/Caches/pip"],
                     ownerBundleID: nil, ownerProcess: "pip", ownerName: "pip"),
        WatchedCache(id: "homebrew", label: "Homebrew downloads", paths: ["/Library/Caches/Homebrew"],
                     ownerBundleID: nil, ownerProcess: "brew", ownerName: "Homebrew"),
        WatchedCache(id: "js-stores", label: "Yarn and pnpm caches", paths: ["/Library/Caches/Yarn", "/Library/Caches/pnpm"],
                     ownerBundleID: nil, ownerProcess: nil, ownerName: nil),
        WatchedCache(id: "gradle", label: "Gradle caches", paths: ["/.gradle/caches"],
                     ownerBundleID: nil, ownerProcess: nil, ownerName: nil),
        WatchedCache(id: "derived-data", label: "Xcode DerivedData", paths: ["/Library/Developer/Xcode/DerivedData"],
                     ownerBundleID: "com.apple.dt.Xcode", ownerProcess: nil, ownerName: "Xcode"),
    ]

    var absolutePaths: [String] { paths.map { NSHomeDirectory() + $0 } }
}

struct CacheReading: Codable, Equatable {
    var bytes: Int64
    var previous: Int64?
    var grew: Int64? { previous.map { bytes - $0 } }
}

enum ProcessNames {
    /// Is any process with this exact short name running? Used only before a clear.
    static func running(_ name: String) -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if String(cString: buffer) == name { return true }
        }
        return false
    }
}

extension WatchedCache {
    /// Why this cache cannot be cleared right now, or nil when it can.
    var inUseReason: String? {
        if let bundle = ownerBundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            return "Quit \(ownerName ?? "the app") first."
        }
        if let process = ownerProcess, ProcessNames.running(process) {
            return "\(ownerName ?? process) is running."
        }
        return nil
    }
}

// MARK: Large apps nobody opens

struct AppUse: Codable, Equatable {
    var name: String
    var path: String
    var bytes: Int64
    var lastUsed: Date?
    var installed: Date?
    var bundleModified: Date?
}

enum DormantApps {
    static let minimumBytes: Int64 = 1_073_741_824
    static let dormantAfter: TimeInterval = 120 * 86_400

    /// The app whose toolchain the command line is using. Spotlight records only launches
    /// from Finder and the Dock, so Xcode used through `swift` or `xcodebuild` looks
    /// "never used" when it is in daily use.
    static func activeDeveloperApp() -> String? {
        let link = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
        guard let link, let range = link.range(of: ".app") else { return nil }
        return String(link[..<range.upperBound])
    }

    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func select(_ apps: [AppUse], now: Date, excluding: Set<String>) -> [AppUse] {
        apps.filter { app in
            guard app.bytes >= minimumBytes, !excluding.contains(app.path) else { return false }
            // Never used: judge by how long it has been installed, so a fresh install is not flagged.
            guard let reference = app.lastUsed ?? app.installed else { return false }
            return now.timeIntervalSince(reference) >= dormantAfter
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Refreshes the inventory, re-measuring a bundle only when it changed on disk.
    static func inventory(previous: [String: AppUse]) -> [String: AppUse] {
        var result: [String: AppUse] = [:]
        let fm = FileManager.default
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = root + "/" + name
                let attrs = try? fm.attributesOfItem(atPath: path)
                let modified = attrs?[.modificationDate] as? Date
                var use = previous[path]
                if use == nil || use?.bundleModified != modified {
                    use = AppUse(name: String(name.dropLast(4)), path: path, bytes: Analysis.sizeOf(path),
                                 lastUsed: nil, installed: attrs?[.creationDate] as? Date, bundleModified: modified)
                }
                use?.lastUsed = lastUsed(path)
                result[path] = use
            }
        }
        return result
    }
}

// MARK: Policy

enum StorageWatchPolicy {
    static let fillingFloor: Int64 = 5 * 1_073_741_824
    static let tempAttentionBytes: Int64 = 1_073_741_824
    static let tempAttentionCount = 20
    static let cacheReportBytes: Int64 = 2 * 1_073_741_824
    static let cacheAttentionBytes: Int64 = 5 * 1_073_741_824
    static let cacheFastGrowth: Int64 = 2 * 1_073_741_824
    static let staleScanAfter: TimeInterval = 21 * 86_400
    static let popupLimit = 2

    static func rank(_ status: HealthStatus) -> Int {
        switch status { case .critical: 0; case .attention: 1; case .comfortable: 2; case .unknown: 3 }
    }

    static func filling(trend: FreeSpaceTrend, free: Int64, now: Date) -> StorageFinding? {
        guard let days = trend.daysUntil(floor: fillingFloor, currentFree: free, now: now), days <= 7,
              let decline = trend.declinePerDay(now: now) else { return nil }
        let when = days < 1 ? "within a day" : days < 1.5 ? "in about a day" : "in about \(Int(days.rounded())) days"
        return StorageFinding(
            id: "filling", kind: .filling,
            title: "Storage is filling up fast",
            detail: "Free space has fallen by about \(fmt(Int64(decline))) a day over the past few days. At that rate, less than \(fmt(fillingFloor)) will be left \(when).",
            bytes: nil, estimated: false, urgency: days <= 2 ? .critical : .attention,
            note: RiskNote(.safe, what: "Opens the storage categories so you can see what is growing.",
                           undo: "Nothing changes until you choose something to clean."),
            action: .open(.categories), actionTitle: "Find what’s growing", blockedReason: nil)
    }

    static func tempProfiles(_ reading: TempBrowserProfiles.Reading) -> StorageFinding? {
        let count = reading.idle.count
        guard count > 0, reading.bytes >= 256 * 1_048_576 || count >= 5 else { return nil }
        let attention = reading.bytes >= tempAttentionBytes || count >= tempAttentionCount
        return StorageFinding(
            id: "temp-profiles", kind: .tempProfiles,
            title: "Leftover browser test profiles",
            detail: "\(count) Chrome profile\(count == 1 ? "" : "s") in the temp folder, none open and untouched for 30+ minutes. Automated test runs leave these behind when they don’t clean up.",
            bytes: reading.bytes, estimated: reading.estimated,
            urgency: attention ? .attention : .comfortable,
            note: RiskNote(.safe,
                           what: "Moves only idle Chromium profiles from your temp folder to the Trash. Anything a browser is still using is skipped.",
                           undo: "Finder → Trash → Put Back. Empty the Trash to get the space back."),
            action: .clearTempProfiles, actionTitle: "Move to Trash", blockedReason: nil)
    }

    static func cache(_ cache: WatchedCache, reading: CacheReading, blocked: String?) -> StorageFinding? {
        guard reading.bytes >= cacheReportBytes else { return nil }
        let grew = reading.grew ?? 0
        let attention = reading.bytes >= cacheAttentionBytes || grew >= cacheFastGrowth
        let growth = grew >= 512 * 1_048_576 ? " It grew by \(fmt(grew)) since the previous daily check." : ""
        return StorageFinding(
            id: "cache-\(cache.id)", kind: .cache,
            title: cache.label,
            detail: "Cached data that rebuilds on its own as you use the tool.\(growth)",
            bytes: reading.bytes, estimated: false,
            urgency: attention ? .attention : .comfortable,
            note: .regenerableCache,
            action: .clearCache(id: cache.id), actionTitle: "Move to Trash", blockedReason: blocked)
    }

    static func dormant(_ apps: [AppUse]) -> StorageFinding? {
        guard !apps.isEmpty else { return nil }
        let total = apps.reduce(0) { $0 + $1.bytes }
        let names = apps.prefix(3).map(\.name).joined(separator: ", ") + (apps.count > 3 ? " and \(apps.count - 3) more" : "")
        return StorageFinding(
            id: "dormant-apps", kind: .dormantApps,
            title: "\(apps.count) large app\(apps.count == 1 ? "" : "s") unused for 4+ months",
            detail: "\(names). Spotlight has no record of these being opened in that time.",
            bytes: total, estimated: false, urgency: .comfortable,
            note: RiskNote(.caution, what: "Opens Applications, where each app’s full footprint is listed before anything is removed.",
                           undo: "Reinstall from the App Store or the developer’s site."),
            action: .open(.apps), actionTitle: "Review apps", blockedReason: nil)
    }

    static func staleScan(entries: [HistoryEntry], home: String = NSHomeDirectory(), now: Date) -> StorageFinding? {
        let homeScans = entries.filter { $0.root == home }.sorted { $0.scannedAt > $1.scannedAt }
        guard let latest = homeScans.first else {
            return StorageFinding(
                id: "no-scan", kind: .staleScan, title: "No full storage scan yet",
                detail: "A scan records what each folder holds, so FastMac can show what grew between scans.",
                bytes: nil, estimated: false, urgency: .comfortable,
                note: RiskNote(.safe, what: "Scans your home folder. Nothing is changed.", undo: "Nothing to undo."),
                action: .open(.folders), actionTitle: "Scan now", blockedReason: nil)
        }
        let age = now.timeIntervalSince(latest.scannedAt)
        guard age >= staleScanAfter else { return nil }
        var detail = "Your last scan was \(Int(age / 86_400)) days ago."
        var action: StorageFinding.Action = .open(.folders)
        if homeScans.count >= 2 {
            let before = Dictionary(homeScans[1].children.map { ($0.path, $0.bytes) }, uniquingKeysWith: max)
            if let grower = latest.children.map({ ($0, $0.bytes - (before[$0.path] ?? 0)) }).max(by: { $0.1 < $1.1 }),
               grower.1 >= 5 * 1_073_741_824 {
                detail += " Between your last two scans, \(grower.0.name) grew by \(fmt(grower.1))."
                action = .open(.history)
            }
        }
        return StorageFinding(
            id: "stale-scan", kind: .staleScan, title: "Time for a storage check-up",
            detail: detail + " A fresh scan shows what has grown since.",
            bytes: nil, estimated: false, urgency: .comfortable,
            note: RiskNote(.safe, what: "Scans your home folder. Nothing is changed.", undo: "Nothing to undo."),
            action: action, actionTitle: action == .open(.history) ? "Compare scans" : "Scan now", blockedReason: nil)
    }

    /// Worst first. When the disk itself is short of room, every finding that would free
    /// a gigabyte or more is promoted, because that is when you need to know where to look.
    static func ranked(_ findings: [StorageFinding], diskStatus: HealthStatus) -> [StorageFinding] {
        let tight = diskStatus == .attention || diskStatus == .critical
        return findings.map { finding in
            var f = finding
            if tight, f.urgency == .comfortable, (f.bytes ?? 0) >= 1_073_741_824 { f.urgency = .attention }
            return f
        }
        .sorted {
            if rank($0.urgency) != rank($1.urgency) { return rank($0.urgency) < rank($1.urgency) }
            return ($0.bytes ?? 0) > ($1.bytes ?? 0)
        }
    }

    /// The popup stays quiet unless something deserves attention.
    static func popup(_ ranked: [StorageFinding]) -> [StorageFinding] {
        Array(ranked.filter { $0.urgency == .attention || $0.urgency == .critical }.prefix(popupLimit))
    }

    /// Findings worth a notification: a rise into attention or critical, once per rise.
    static func notifiable(_ finding: StorageFinding, previouslyNotified: String?) -> Bool {
        guard [.filling, .tempProfiles, .cache].contains(finding.kind),
              finding.urgency == .attention || finding.urgency == .critical else { return false }
        guard let previous = previouslyNotified.flatMap(HealthStatus.init(rawValue:)) else { return true }
        return rank(finding.urgency) < rank(previous)
    }
}

// MARK: Persisted state

struct StorageWatchState: Codable {
    static let currentVersion = 1
    var version = StorageWatchState.currentVersion
    var trend = FreeSpaceTrend()
    var caches: [String: CacheReading] = [:]
    var cachesMeasuredAt: Date?
    var apps: [String: AppUse] = [:]
    var appsCheckedAt: Date?
    /// Finding id → the urgency it was last notified at, so a notification fires on a rise only.
    var notified: [String: String] = [:]

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".fastmac/storage-watch.json")
    }

    /// A missing, truncated or future-version file starts fresh rather than failing.
    static func load(from url: URL = defaultURL) -> StorageWatchState {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return StorageWatchState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(StorageWatchState.self, from: data),
              state.version <= currentVersion else { return StorageWatchState() }
        return state
    }

    func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - The watcher

@MainActor
final class StorageWatch: ObservableObject {
    /// For previews and render checks: never samples, never touches disk.
    static let inert = StorageWatch(persists: false, startsTimers: false)

    static let interval: TimeInterval = 30 * 60
    static let tolerance: TimeInterval = 5 * 60
    static let dailyAfter: TimeInterval = 20 * 3_600
    /// When the disk is short of room, the daily pass runs every few hours instead.
    static let tightAfter: TimeInterval = 6 * 3_600

    @Published private(set) var findings: [StorageFinding] = []
    @Published private(set) var popupFindings: [StorageFinding] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var working: String?
    @Published var message: String?

    var diskStatus: () -> HealthStatus = { .unknown }
    /// Notifications are delivered by AlertManager, which owns permission and snoozing.
    /// Returns whether delivery was attempted, so a refused attempt does not use up the rise.
    var onRise: (StorageFinding) -> Bool = { _ in false }

    private let persists: Bool
    private let startsTimers: Bool
    private var state: StorageWatchState
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var tickInFlight = false
    private var temp = TempBrowserProfiles.Reading()
    private var history: [HistoryEntry] = []

    init(persists: Bool = true, startsTimers: Bool = true) {
        self.persists = persists
        self.startsTimers = startsTimers
        self.state = persists ? StorageWatchState.load() : StorageWatchState()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard startsTimers, timer == nil else { return }
        // Let launch settle first; the popup's own refresh covers anyone who opens it sooner.
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = Self.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        startTask?.cancel(); startTask = nil
        timer?.invalidate(); timer = nil
    }

    /// Cheap tier only, for when the popup opens. Skipped if a reading is minutes old.
    func refreshIfStale() {
        guard startsTimers else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 120 { return }
        tick(allowDaily: false)
    }

    private var dailyDue: Bool {
        let after = (diskStatus() == .attention || diskStatus() == .critical) ? Self.tightAfter : Self.dailyAfter
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        guard let last = state.cachesMeasuredAt else { return true }
        return Date().timeIntervalSince(last) >= after
    }

    func tick(allowDaily: Bool = true) {
        guard !tickInFlight else { return }
        tickInFlight = true
        let daily = allowDaily && dailyDue
        let previousApps = state.apps
        let previousCaches = state.caches
        Task.detached(priority: .background) {
            let disk = MemoryProbe.diskFree()
            let temp = TempBrowserProfiles.read()
            var caches: [String: CacheReading]? = nil
            var apps: [String: AppUse]? = nil
            if daily {
                var measured: [String: CacheReading] = [:]
                for cache in WatchedCache.all {
                    let existing = cache.absolutePaths.filter { FileManager.default.fileExists(atPath: $0) }
                    guard !existing.isEmpty else { continue }
                    let bytes = existing.reduce(Int64(0)) { $0 + Analysis.sizeOf($1) }
                    measured[cache.id] = CacheReading(bytes: bytes, previous: previousCaches[cache.id]?.bytes)
                }
                caches = measured
                apps = DormantApps.inventory(previous: previousApps)
            }
            let history = History.loadAll()
            let measuredCaches = caches, measuredApps = apps
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tickInFlight = false
                let now = Date()
                if disk.total > 0 { self.state.trend.record(free: disk.free, at: now) }
                self.temp = temp
                if let measuredCaches { self.state.caches = measuredCaches; self.state.cachesMeasuredAt = now }
                if let measuredApps { self.state.apps = measuredApps; self.state.appsCheckedAt = now }
                self.history = history
                self.lastChecked = now
                self.evaluate(free: disk.free, now: now)
                if self.persists { self.state.save() }
            }
        }
    }

    /// Rebuilds the findings from the latest readings. Pure apart from notifications.
    func evaluate(free: Int64, now: Date) {
        var list: [StorageFinding] = []
        if let filling = StorageWatchPolicy.filling(trend: state.trend, free: free, now: now) { list.append(filling) }
        if let profiles = StorageWatchPolicy.tempProfiles(temp) { list.append(profiles) }
        for cache in WatchedCache.all {
            guard let reading = state.caches[cache.id] else { continue }
            if let finding = StorageWatchPolicy.cache(cache, reading: reading, blocked: cache.inUseReason) {
                list.append(finding)
            }
        }
        let developer = DormantApps.activeDeveloperApp()
        let excluded = Set([developer, Bundle.main.bundleURL.path].compactMap { $0 })
        if let dormant = StorageWatchPolicy.dormant(DormantApps.select(Array(state.apps.values), now: now, excluding: excluded)) {
            list.append(dormant)
        }
        if let stale = StorageWatchPolicy.staleScan(entries: history, now: now) { list.append(stale) }

        let ranked = StorageWatchPolicy.ranked(list, diskStatus: diskStatus())
        findings = ranked
        popupFindings = StorageWatchPolicy.popup(ranked)

        // Notify on a rise only; forget a condition once it clears so a return notifies again.
        let present = Set(ranked.map(\.id))
        state.notified = state.notified.filter { present.contains($0.key) }
        for finding in ranked where StorageWatchPolicy.notifiable(finding, previouslyNotified: state.notified[finding.id]) {
            if onRise(finding) { state.notified[finding.id] = finding.urgency.rawValue }
        }
    }

    // MARK: Actions

    func perform(_ finding: StorageFinding) {
        guard working == nil else { return }
        switch finding.action {
        case .open:
            return
        case .clearTempProfiles:
            working = finding.id
            let paths = temp.idle
            Task.detached(priority: .userInitiated) {
                let result = TempBrowserProfiles.clear(paths)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.working = nil
                    self.message = result.moved == 0
                        ? "Nothing was moved — those profiles became active or were already gone."
                        : "Moved \(result.moved) profile\(result.moved == 1 ? "" : "s") (\(fmt(result.bytes))) to the Trash. Empty the Trash to get the space back."
                        + (result.skipped > 0 ? " \(result.skipped) in use or changed were left alone." : "")
                    self.tick(allowDaily: false)
                }
            }
        case .clearCache(let id):
            guard let cache = WatchedCache.all.first(where: { $0.id == id }) else { return }
            if let reason = cache.inUseReason { message = reason; return }
            working = finding.id
            Task.detached(priority: .userInitiated) {
                var moved: Int64 = 0
                var refused = 0
                for path in cache.absolutePaths where FileManager.default.fileExists(atPath: path) {
                    guard Safety.canDelete(path).ok else { refused += 1; continue }
                    let size = Analysis.sizeOf(path)
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                        moved += size
                        Audit.log("trashed", bytes: size, path: path)
                    } catch { refused += 1 }
                }
                let totalMoved = moved, refusedCount = refused
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.working = nil
                    if totalMoved > 0 {
                        self.state.caches[id] = CacheReading(bytes: 0, previous: nil)
                        if self.persists { self.state.save() }
                    }
                    self.message = totalMoved > 0
                        ? "Moved \(cache.label) (\(fmt(totalMoved))) to the Trash. It rebuilds as you use \(cache.ownerName ?? "the tool"). Empty the Trash to get the space back."
                        : "\(cache.label) could not be moved\(refusedCount > 0 ? " — the safety check refused it" : "")."
                    self.tick(allowDaily: false)
                }
            }
        }
    }

    // MARK: Test support

    /// Sets findings directly, for render fixtures that must not depend on which apps
    /// happen to be open on the machine drawing them.
    func seed(findings: [StorageFinding], message: String? = nil) {
        self.findings = findings
        popupFindings = StorageWatchPolicy.popup(findings)
        self.message = message
    }

    /// Seeds readings directly. Used by self-checks and render checks only.
    func seed(trend: FreeSpaceTrend? = nil, temp: TempBrowserProfiles.Reading? = nil,
              caches: [String: CacheReading]? = nil, apps: [String: AppUse]? = nil,
              history: [HistoryEntry]? = nil, free: Int64, now: Date = Date()) {
        if let trend { state.trend = trend }
        if let temp { self.temp = temp }
        if let caches { state.caches = caches }
        if let apps { state.apps = apps }
        if let history { self.history = history }
        lastChecked = now
        evaluate(free: free, now: now)
    }
}
