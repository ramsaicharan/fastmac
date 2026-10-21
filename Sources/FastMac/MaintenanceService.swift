import Foundation
import AppKit

// MARK: - System Maintenance
//
// Everything here either (a) only reads state via framework APIs / read-only shell-outs,
// or (b) performs a narrowly-scoped, non-root, user-reversible action that the UI gates
// behind an explicit opt-in. Nothing in this file ever calls `sudo`, prompts for a
// password, or uses AuthorizationServices to escalate. Actions that genuinely need admin
// rights are represented as `AdminCommand` — a string for the user to run themselves in
// Terminal — never executed by us.
//
// Every `Process` invocation below uses an absolute executable path and a fixed,
// hand-written argument list. None of it is built by concatenating user input into a
// shell string.

// MARK: Shelling out, once, carefully

enum Shell {
    struct Result { let status: Int32; let stdout: String; let stderr: String }

    /// Runs `path` with `args`, waiting up to `timeout` seconds. Never goes through
    /// `/bin/sh`; `path` must already be absolute.
    @discardableResult
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 25) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Result(status: -1, stdout: "", stderr: "\(path) is not present on this machine")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { p.terminate(); return Result(status: -2, stdout: "", stderr: "timed out") }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(status: p.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}

// MARK: - Time Machine local snapshots

struct LocalSnapshot: Identifiable, Hashable {
    let volume: String     // the mount point tmutil enumerated this under, e.g. "/"
    let dateToken: String  // the raw token tmutil printed — this exact string is what
                            // `tmutil deletelocalsnapshots <token>` expects
    let date: Date?         // parsed, when the token matches the usual yyyy-MM-dd-HHmmss shape

    var id: String { volume + "|" + dateToken }
    var displayDate: String {
        guard let date else { return dateToken }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

enum TimeMachineSnapshots {
    private static let tokenFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")  // tmutil timestamps its tokens in UTC
        return f
    }()

    /// Volumes worth asking tmutil about. Root is always present; the Data volume is
    /// where local snapshots on a modern (volume-group / sealed-system) Mac actually live.
    static func candidateVolumes() -> [String] {
        var vols = ["/"]
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data") {
            vols.append("/System/Volumes/Data")
        }
        return vols
    }

    /// `tmutil listlocalsnapshotdates <volume>` — one bare date token per line after a
    /// header line. This is the read-only, non-destructive half of snapshot management.
    static func list(volume: String) -> [LocalSnapshot] {
        let r = Shell.run(MaintenanceService.tmutilPath, ["listlocalsnapshotdates", volume])
        guard r.status == 0 else { return [] }
        var out: [LocalSnapshot] = []
        for rawLine in r.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.lowercased().hasPrefix("snapshot") == false else { continue }
            out.append(LocalSnapshot(volume: volume, dateToken: line,
                                      date: tokenFormat.date(from: line)))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func listAll() -> [LocalSnapshot] {
        // A snapshot spanning the whole volume group shows up under both mount points;
        // de-duplicate by date token so the list reflects distinct snapshots, not
        // distinct volumes that happened to enumerate the same one.
        var seen = Set<String>()
        var out: [LocalSnapshot] = []
        for v in candidateVolumes() {
            for s in list(volume: v) where seen.insert(s.dateToken).inserted {
                out.append(s)
            }
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Thins exactly one local snapshot. This is the one genuinely destructive call in
    /// this file — it is never invoked except from the UI, behind an explicit confirm,
    /// and every call is written to `Audit.log` regardless of outcome. It intentionally
    /// takes a `LocalSnapshot` rather than a bare string so a caller can't hand it an
    /// arbitrary, unvalidated token.
    static func delete(_ snapshot: LocalSnapshot) -> Shell.Result {
        let r = Shell.run(MaintenanceService.tmutilPath,
                           ["deletelocalsnapshots", snapshot.dateToken], timeout: 120)
        Audit.log(r.status == 0 ? "tm-snapshot-thinned" : "tm-snapshot-thin-failed",
                  bytes: 0, path: "\(snapshot.volume) @ \(snapshot.dateToken)")
        return r
    }
}

// MARK: - Purgeable space
//
// "Purgeable" is not a folder you can open and empty. It is the gap between what a
// volume reports as plainly free and what it could free under storage pressure — local
// TM snapshots, some caches, iCloud-evictable files. macOS reclaims it itself when
// needed; nothing here pretends to reclaim it directly.

struct VolumeSpace {
    let volume: String
    let totalBytes: Int64
    let availableBytes: Int64            // what Finder/df calls "available" today
    let availableImportantBytes: Int64   // what the OS could make available under pressure
    var purgeableBytes: Int64 { max(0, availableImportantBytes - availableBytes) }
}

enum PurgeableSpace {
    /// Framework APIs, not `df` — `URLResourceValues` is the documented way to ask APFS
    /// for these numbers and needs no subprocess.
    static func info(volume: String = "/") -> VolumeSpace? {
        let url = URL(fileURLWithPath: volume)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let avail = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? avail
        return VolumeSpace(volume: volume, totalBytes: total, availableBytes: avail,
                           availableImportantBytes: important)
    }
}

// MARK: - Safe maintenance actions

struct MaintVerdict {
    /// A short, honest statement of current state — a size when one is measurable and
    /// meaningful, a state description otherwise. Nil means "we couldn't measure and
    /// won't guess" and the UI should say so rather than invent a number.
    let headline: String
    /// True when there's something real to gain right now; the UI only shows an action
    /// button when this is true (or the action is informational, like a status check).
    let worthDoing: Bool
}

struct MaintAction: Identifiable {
    let id: String
    let title: String
    let explanation: String        // plain-language cost/benefit, shown always
    let verdict: () -> MaintVerdict
    /// nil when the action needs admin rights the app won't take — `adminCommand` then
    /// holds the exact command line for the user to paste into Terminal themselves.
    let perform: (() -> Shell.Result)?
    let adminCommand: String?
}

enum MaintenanceService {
    // Absolute paths only. Checked for existence before every run via
    // `FileManager.isExecutableFile`, so a missing tool fails loudly, not silently.
    static let tmutilPath = "/usr/bin/tmutil"
    static let dscacheutilPath = "/usr/bin/dscacheutil"
    static let killallPath = "/usr/bin/killall"
    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let mdutilPath = "/usr/bin/mdutil"
    static let atsutilPath = "/usr/bin/atsutil"
    static let qlmanagePath = "/usr/bin/qlmanage"
    static let periodicPath = "/usr/sbin/periodic"

    static func toolExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Spotlight status (read-only, no admin)

    static func spotlightStatus(volume: String = "/") -> String {
        spotlightStatusText(Shell.run(mdutilPath, ["-s", volume]))
    }

    /// An empty successful reply is also unavailable, rather than a blank UI verdict.
    static func spotlightStatusText(_ result: Shell.Result) -> String {
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 {
            let reason = !error.isEmpty ? error
                : (!output.isEmpty ? output : "mdutil exited with status \(result.status)")
            return "Spotlight status unavailable: \(String(reason.prefix(500)))"
        }

        var lines = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // mdutil normally starts with "/:"; a one-line indexing result has no header.
        if let first = lines.first, first.hasPrefix("/"), first.hasSuffix(":") {
            lines.removeFirst()
        }
        let status = lines.joined(separator: " ")
        guard !status.isEmpty else {
            let reason = error.isEmpty ? "mdutil returned no indexing status" : error
            return "Spotlight status unavailable: \(String(reason.prefix(500)))"
        }
        return status
    }

    // MARK: QuickLook thumbnail cache (measurable, no admin)

    /// The per-user cache root macOS actually uses — inside `/var/folders/...`, not
    /// under `~/Library`, so reading it needs no special entitlement.
    static var darwinUserCacheDir: String? {
        let r = Shell.run("/usr/bin/getconf", ["DARWIN_USER_CACHE_DIR"])
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func quickLookCacheSize() -> Int64 {
        guard let base = darwinUserCacheDir else { return 0 }
        return Analysis.sizeOf(base + "com.apple.QuickLook.thumbnailcache")
    }

    static func clearQuickLookThumbnailCache() -> Shell.Result {
        let r1 = Shell.run(qlmanagePath, ["-r", "cache"])
        let r2 = Shell.run(qlmanagePath, ["-r"])
        Audit.log("quicklook-cache-cleared", bytes: 0, path: "qlmanage -r cache; qlmanage -r")
        return r1.status == 0 ? r2 : r1
    }

    // MARK: Launch Services database (no admin — it's the user's own registration DB)

    static func rebuildLaunchServicesDatabase() -> Shell.Result {
        let r = Shell.run(lsregisterPath,
                           ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"],
                           timeout: 60)
        Audit.log("launch-services-rebuilt", bytes: 0, path: lsregisterPath)
        return r
    }

    // MARK: Fonts — per-user is safe; system-wide needs admin (atsutil says so itself)

    static func clearUserFontCache() -> Shell.Result {
        let r = Shell.run(atsutilPath, ["databases", "-removeUser"])
        Audit.log("font-cache-cleared-user", bytes: 0, path: atsutilPath)
        return r
    }

    static var clearSystemFontCacheCommand: String { "sudo atsutil databases -remove" }

    // MARK: Things that genuinely need root — command strings only, never run

    static var flushDNSCacheCommand: String {
        "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
    }

    static func rebuildSpotlightIndexCommand(volume: String = "/") -> String {
        "sudo mdutil -E \(volume)"
    }

    // MARK: periodic daily/weekly/monthly

    static var periodicAvailable: Bool { toolExists(periodicPath) }

    static func periodicCommand(_ which: String) -> String { "sudo periodic \(which)" }

    // MARK: the assembled list the view renders

    static func actions() -> [MaintAction] {
        var out: [MaintAction] = []

        out.append(MaintAction(
            id: "spotlight-status",
            title: "Spotlight indexing status",
            explanation: "Read-only check of whether Spotlight is indexing this volume. "
                + "Rebuilding the index (below) can take hours and uses real CPU — only "
                + "worth doing if search results are visibly wrong or stale.",
            verdict: { MaintVerdict(headline: spotlightStatus(), worthDoing: false) },
            perform: nil, adminCommand: nil))

        out.append(MaintAction(
            id: "spotlight-rebuild",
            title: "Rebuild Spotlight index",
            explanation: "Erases and rebuilds the search index for a volume. Fixes "
                + "\"Spotlight can't find files I know exist\" — costs hours of background "
                + "CPU and disk activity while it reindexes. Needs admin rights; FastMac "
                + "will not run this for you.",
            verdict: { MaintVerdict(headline: "admin command only — see below", worthDoing: false) },
            perform: nil, adminCommand: rebuildSpotlightIndexCommand()))

        out.append(MaintAction(
            id: "dns-flush",
            title: "Flush DNS cache",
            explanation: "Clears cached DNS lookups. Fixes \"I updated a DNS record and "
                + "the Mac won't see it\" or stale/broken hostnames after switching "
                + "networks. Harmless — the cache rebuilds itself as you browse. Needs "
                + "admin rights; FastMac will not run this for you.",
            verdict: { MaintVerdict(headline: "admin command only — see below", worthDoing: false) },
            perform: nil, adminCommand: flushDNSCacheCommand))

        out.append(MaintAction(
            id: "launch-services-rebuild",
            title: "Rebuild Launch Services database",
            explanation: "Re-scans installed apps and rebuilds the map from document "
                + "types/URL schemes to the app that opens them. Fixes duplicate or wrong "
                + "\"Open With\" entries and double-clicking a file launching the wrong "
                + "app. Touches only your own registration database — no admin needed. "
                + "Every app's Dock icon and menu may flash briefly right after.",
            verdict: { MaintVerdict(headline: "safe to run any time", worthDoing: true) },
            perform: { rebuildLaunchServicesDatabase() }, adminCommand: nil))

        let qlSize = quickLookCacheSize()
        out.append(MaintAction(
            id: "quicklook-cache",
            title: "Clear QuickLook thumbnail cache",
            explanation: "Deletes cached preview thumbnails (Space bar quick-look, Finder "
                + "icons). Regenerates automatically the next time you preview something — "
                + "nothing is lost. Fixes thumbnails stuck showing an old version of a file.",
            verdict: {
                qlSize > 0
                    ? MaintVerdict(headline: "\(fmt(qlSize)) cached now", worthDoing: true)
                    : MaintVerdict(headline: "cache is empty right now — nothing to gain", worthDoing: false)
            },
            perform: { clearQuickLookThumbnailCache() }, adminCommand: nil))

        out.append(MaintAction(
            id: "font-cache-user",
            title: "Clear font cache (your account)",
            explanation: "Rebuilds the per-user font database. Fixes garbled glyphs, "
                + "missing fonts in one app, or a font that won't uninstall cleanly. Your "
                + "apps may need a relaunch to pick up the change. A separate, "
                + "system-wide font cache also exists and needs admin rights to clear — "
                + "see below; most font glitches are fixed by the per-user reset alone.",
            verdict: { MaintVerdict(headline: "safe to run any time", worthDoing: true) },
            perform: { clearUserFontCache() }, adminCommand: nil))

        out.append(MaintAction(
            id: "font-cache-system",
            title: "Clear font cache (system-wide)",
            explanation: "The system-wide counterpart to the action above. atsutil's own "
                + "help text says this must run as root, so FastMac won't run it for you.",
            verdict: { MaintVerdict(headline: "admin command only — see below", worthDoing: false) },
            perform: nil, adminCommand: clearSystemFontCacheCommand))

        if periodicAvailable {
            for which in ["daily", "weekly", "monthly"] {
                out.append(MaintAction(
                    id: "periodic-\(which)",
                    title: "Run \(which) maintenance script",
                    explanation: "Classic BSD housekeeping (log rotation and cleanup). "
                        + "Runs as root and needs admin rights; FastMac won't run it for you.",
                    verdict: { MaintVerdict(headline: "admin command only — see below", worthDoing: false) },
                    perform: nil, adminCommand: periodicCommand(which)))
            }
        } else {
            out.append(MaintAction(
                id: "periodic-unavailable",
                title: "Run daily/weekly/monthly maintenance scripts",
                explanation: "Not available on this Mac — Apple removed /usr/sbin/periodic "
                    + "and /etc/periodic from recent macOS versions; there is nothing here "
                    + "to run. (Verified on this machine: \(periodicPath) does not exist.)",
                verdict: { MaintVerdict(headline: "not available on this macOS version", worthDoing: false) },
                perform: nil, adminCommand: nil))
        }

        return out
    }
}

// MARK: - Full Disk Access detection
//
// FastMac under-reports silently without FDA: whole Library subtrees read back empty
// instead of erroring, and the scan totals look plausible but are wrong. Detecting this
// matters more than almost anything else in Settings.
//
// The brief's suggested probe path, `~/Library/Application Support/com.apple.TCC`,
// does not exist as a real directory on a stock account (confirmed on this machine —
// it's ENOENT, not EPERM), which would read as "has FDA" by accident. The system-level
// TCC database always exists and is SIP+TCC protected even from processes running as
// root, so a permission failure reading it is unambiguous. If for some reason that path
// is missing too, fall back to `~/Library/Safari`, which macOS creates for every account
// and which is one of the well-known protected paths without FDA.

enum FullDiskAccess {
    enum Status { case granted, denied, unknown }

    private static let probes = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari",
        NSHomeDirectory() + "/Library/Mail",
    ]

    static func check() -> Status {
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            let e = errno
            if e == ENOENT { continue }          // doesn't exist here — try the next probe
            if e == EPERM || e == EACCES { return .denied }
            // Some other error (e.g. it's a directory and O_RDONLY still worked, or a
            // transient issue) — try the next probe rather than guessing.
        }
        return .unknown
    }

    /// Privacy & Security → Full Disk Access. macOS 13 and later register the pane as
    /// a Settings extension; the legacy identifier is kept as a fallback.
    static let systemSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    static let legacySystemSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @discardableResult
    static func openSettings() -> Bool {
        NSWorkspace.shared.open(systemSettingsURL) || NSWorkspace.shared.open(legacySystemSettingsURL)
    }

    /// Set when the user leaves for System Settings, so a relaunch through
    /// "Quit & Reopen" can confirm access and offer the rescan they were after.
    static let pendingRescanKey = "FastMac.FullDiskAccess.PendingRescan"
    /// Set when the user chooses to scan without access; stops the pre-scan prompt.
    static let skipScanPromptKey = "FastMac.FullDiskAccess.SkipScanPrompt"

    /// Ask before a whole-disk scan only when access is known to be missing and the
    /// user has not already chosen to scan without it. An undetermined status is not
    /// treated as denied.
    static func shouldPromptBeforeScan(status: Status, skipped: Bool) -> Bool {
        status == .denied && !skipped
    }
}
