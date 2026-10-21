import Foundation
import Darwin
import AppKit

// MARK: - Startup & Login Impact
//
// Enumerates everything that auto-starts (LaunchAgents/LaunchDaemons the user or an
// installer put on this Mac — never /System/Library, which macOS owns), correlates each
// entry against what launchd actually has loaded right now, attributes it to the app or
// vendor that installed it, and rates its boot-time impact in plain language.
//
// Two things this file deliberately never does:
//   1. touch /System/Library/LaunchAgents or /System/Library/LaunchDaemons — Apple's own.
//   2. escalate privilege. Anything under /Library (global agents, all daemons) is
//      root-owned; we read and explain it, we do not sudo to change it.

// MARK: - Where things live

enum StartupDomain: String, CaseIterable, Identifiable {
    case userAgent      // ~/Library/LaunchAgents      — owned by this user, freely toggled
    case globalAgent    // /Library/LaunchAgents        — installed for every user, needs root
    case daemon         // /Library/LaunchDaemons       — runs as root, needs root

    var id: String { rawValue }

    var directory: String {
        switch self {
        case .userAgent:   NSHomeDirectory() + "/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .daemon:      "/Library/LaunchDaemons"
        }
    }

    var title: String {
        switch self {
        case .userAgent:   "Login Item (yours)"
        case .globalAgent: "Login Item (all users)"
        case .daemon:      "System Daemon"
        }
    }

    /// Only user agents can be toggled without administrator rights.
    var editableWithoutRoot: Bool { self == .userAgent }

    /// launchd domain a label lives in, for `launchctl` targeting.
    func target(uid: uid_t, label: String) -> String {
        switch self {
        case .userAgent, .globalAgent: "gui/\(uid)/\(label)"
        case .daemon:                  "system/\(label)"
        }
    }
    func domainRoot(uid: uid_t) -> String {
        switch self {
        case .userAgent, .globalAgent: "gui/\(uid)"
        case .daemon:                  "system"
        }
    }
}

// MARK: - One parsed + correlated launchd job

struct StartupItem: Identifiable, Hashable {
    let label: String
    let domain: StartupDomain
    let plistPath: String
    let programPath: String?          // resolved Program, or ProgramArguments[0]
    let programArguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let startInterval: Int?           // seconds, if periodic
    let watchesPaths: Bool            // WatchPaths / QueueDirectories present
    let legacyDisabledKey: Bool       // the old in-plist "Disabled" flag (rarely used now)
    let unreadable: Bool              // plist exists but we could not read/parse it (permissions)

    // Filled in by correlation against `launchctl`.
    var isLoaded = false
    var pid: Int32?
    var lastExitStatus: Int32?
    /// nil = unknown (we have no way to ask launchd without root for this domain)
    var launchctlDisabled: Bool?
    var cpuSeconds: Double?
    var binarySize: Int64?
    var owner: String = "Unknown"
    /// Measured with the background scan. UI rendering must never stat a path,
    /// which could point at an unavailable external or network volume.
    var binaryMissing = false

    var id: String { plistPath }

    var hasProgram: Bool { programPath != nil }

    /// The plist points at a binary that is no longer on disk — a dead entry still
    /// probed (and briefly stalling launchd) at every boot.
    var isOrphanBinary: Bool { binaryMissing }

    /// The plist itself is a content-free stub (no Program/ProgramArguments at all) —
    /// seen in practice from uninstallers that neuter an agent instead of removing it.
    var isStub: Bool { !unreadable && programArguments.isEmpty && programPath == nil }

    var isOrphan: Bool { isOrphanBinary || isStub }

    var effectiveDisabled: Bool { launchctlDisabled ?? legacyDisabledKey }

    var fileName: String { (plistPath as NSString).lastPathComponent }
}

// MARK: - Impact rating — always a stated reason, never a bare number

enum ImpactLevel: String, Comparable {
    case high = "High", medium = "Medium", low = "Low"
    private var rank: Int { switch self { case .high: 2; case .medium: 1; case .low: 0 } }
    static func < (l: ImpactLevel, r: ImpactLevel) -> Bool { l.rank < r.rank }
}

struct ImpactRating: Hashable {
    let level: ImpactLevel
    let reason: String
}

enum Impact {
    static func rate(_ item: StartupItem) -> ImpactRating {
        if item.unreadable {
            return ImpactRating(level: .low,
                                 reason: "FastMac does not have permission to read this plist, so it cannot run analysis on it")
        }
        if item.isOrphanBinary {
            return ImpactRating(level: .low,
                                 reason: "the program this points to no longer exists on disk — a dead entry still checked at every boot")
        }
        if item.isStub {
            return ImpactRating(level: .low,
                                 reason: "an empty placeholder plist with nothing to launch, left behind by an installer/uninstaller")
        }
        if item.effectiveDisabled {
            return ImpactRating(level: .low,
                                 reason: "disabled — launchd will skip it at the next login")
        }

        var signals: [String] = []
        var weight = 0

        if item.runAtLoad {
            signals.append("launches at every login (RunAtLoad)")
            weight += 1
        }
        if item.keepAlive {
            signals.append("relaunches itself whenever it exits (KeepAlive)")
            weight += 1
        }
        if item.isLoaded {
            if let pid = item.pid {
                signals.append("currently running, PID \(pid)")
            } else {
                signals.append("currently loaded by launchd")
            }
            weight += 1
        }
        if let cpu = item.cpuSeconds, cpu >= 5 {
            signals.append("has used \(Self.describeCPU(cpu)) of CPU time this session")
            weight += cpu >= 60 ? 2 : 1
        }
        if let interval = item.startInterval, interval > 0 {
            signals.append("wakes itself up \(Self.describeInterval(interval))")
            weight += interval <= 900 ? 1 : 0
        }
        if item.watchesPaths {
            signals.append("watches the filesystem for changes and relaunches on them")
        }
        if let size = item.binarySize, size > 300 << 20 {
            signals.append("\(fmt(size)) binary to load")
            weight += 1
        }

        if signals.isEmpty {
            return ImpactRating(level: .low,
                                 reason: "not set to run at login and not currently loaded")
        }
        let reason = signals.joined(separator: "; ")
        if weight >= 3 { return ImpactRating(level: .high, reason: reason) }
        if weight >= 1 { return ImpactRating(level: .medium, reason: reason) }
        return ImpactRating(level: .low, reason: reason)
    }

    static func describeCPU(_ seconds: Double) -> String {
        seconds >= 60 ? String(format: "%.1f min", seconds / 60) : String(format: "%.0f s", seconds)
    }

    static func describeInterval(_ seconds: Int) -> String {
        switch seconds {
        case ..<0: "on an invalid interval"
        case 0: "immediately"
        case 1..<120: "every \(seconds)s"
        case 120..<7200: "every \(seconds / 60) min"
        case 7200..<172_800: "every \(seconds / 3600)h"
        default: "every \(seconds / 86_400)d"
        }
    }
}

// MARK: - Owner attribution: "Google Updater", not "com.google.keystone.agent"

enum Attribution {
    private static let knownVendors: [String: String] = [
        "google": "Google", "apple": "Apple", "microsoft": "Microsoft", "adobe": "Adobe",
        "docker": "Docker", "mozilla": "Mozilla", "spotify": "Spotify", "dropbox": "Dropbox",
        "zoom": "Zoom", "us": "Zoom", "openai": "OpenAI", "nordvpn": "NordVPN",
        "adguard": "AdGuard", "edb": "EnterpriseDB (PostgreSQL)", "1password": "1Password",
        "slack": "Slack", "citrix": "Citrix", "vmware": "VMware", "jetbrains": "JetBrains",
        "electron": "Electron app", "postman": "Postman", "notion": "Notion",
        "github": "GitHub", "amazon": "Amazon", "aws": "AWS",
    ]

    static func owner(label: String, programPath: String?) -> String {
        // Best source: the .app bundle the executable lives inside.
        if let p = programPath, let r = p.range(of: ".app/") {
            let head = String(p[p.startIndex..<r.lowerBound])
            let name = (head as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        // Homebrew formulas: /opt/homebrew/Cellar/<formula>/... or the mxcl.<formula> label.
        if let p = programPath, let r = p.range(of: "/Cellar/") {
            let tail = p[r.upperBound...]
            if let formula = tail.split(separator: "/").first {
                return "Homebrew (\(formula))"
            }
        }
        if label.hasPrefix("homebrew.mxcl.") {
            return "Homebrew (\(label.dropFirst("homebrew.mxcl.".count)))"
        }
        // PrivilegedHelperTools installed by an app's installer carry the app's reverse-DNS.
        // Fall back to the reverse-DNS vendor segment of the label itself.
        let parts = label.split(separator: ".")
        if parts.count >= 2 {
            let vendor = String(parts[1]).lowercased()
            if let known = knownVendors[vendor] { return known }
            return vendor.capitalized
        }
        return label
    }
}

// MARK: - Service

@MainActor
final class StartupService: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var isScanning = false
    @Published var lastScanAt: Date?
    @Published var lastError: String?
    /// Human-readable result of the most recent enable/disable, shown in the UI.
    @Published var lastAction: String?

    private let uid = getuid()
    private var scanTask: Task<Void, Never>?

    // MARK: scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        let uid = self.uid
        scanTask = Task.detached(priority: .userInitiated) {
            let found = Self.performScan(uid: uid)
            let ranked = found
                .map { ($0, Impact.rate($0).level) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.label < $1.0.label }
                .map(\.0)
            await MainActor.run {
                self.items = ranked
                self.isScanning = false
                self.lastScanAt = Date()
                self.scanTask = nil
            }
        }
    }

    // MARK: summary

    var orphans: [StartupItem] { items.filter(\.isOrphan) }
    var highImpact: [StartupItem] { items.filter { Impact.rate($0).level == .high } }
    var running: [StartupItem] { items.filter(\.isLoaded) }

    // MARK: - the heavy lifting, off the main actor

    private struct ListedJob { var pid: Int32?; var lastExit: Int32? }

    /// Internal (not private) so StartupSelfCheck can exercise the real, live scan on
    /// this machine without needing a MainActor bridge — it is a pure, read-only function.
    nonisolated static func performScan(uid: uid_t) -> [StartupItem] {
        var items: [StartupItem] = []
        for domain in StartupDomain.allCases {
            items.append(contentsOf: parseDirectory(domain))
        }

        let loaded = listLoadedJobs()
        let guiDisabled = printDisabled(target: "gui/\(uid)")
        let systemDisabled = printDisabled(target: "system")

        for i in items.indices {
            let label = items[i].label
            switch items[i].domain {
            case .userAgent, .globalAgent:
                if let job = loaded[label] {
                    items[i].isLoaded = true
                    items[i].pid = job.pid
                    items[i].lastExitStatus = job.lastExit
                }
                if let d = guiDisabled[label] { items[i].launchctlDisabled = d }
            case .daemon:
                // No general, unprivileged way to list root-domain PIDs; `print-disabled`
                // is the one piece of system-domain state launchctl exposes without root.
                if let d = systemDisabled[label] { items[i].launchctlDisabled = d }
            }

            if items[i].isLoaded, let pid = items[i].pid, pid > 0 {
                items[i].cpuSeconds = cpuSeconds(pid: pid)
            }
            if let p = items[i].programPath {
                items[i].binarySize = fileSize(p)
            }
            items[i].owner = Attribution.owner(label: label, programPath: items[i].programPath)
        }
        return items
    }

    // MARK: plist enumeration

    nonisolated private static func parseDirectory(_ domain: StartupDomain) -> [StartupItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: domain.directory) else { return [] }
        var out: [StartupItem] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            let path = domain.directory + "/" + name
            out.append(parsePlist(path: path, domain: domain))
        }
        return out
    }

    /// Internal so it can be unit-tested against fixture plists directly.
    nonisolated static func parsePlist(path: String, domain: StartupDomain) -> StartupItem {
        let fallbackLabel = (path as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")

        guard let data = FileManager.default.contents(atPath: path) else {
            // Exists (we enumerated it) but unreadable — typically root-only permissions,
            // e.g. a security vendor's daemon plist mode 600. Report it, don't guess at it.
            return StartupItem(label: fallbackLabel, domain: domain, plistPath: path,
                                programPath: nil, programArguments: [], runAtLoad: false,
                                keepAlive: false, startInterval: nil, watchesPaths: false,
                                legacyDisabledKey: false, unreadable: true)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            return StartupItem(label: fallbackLabel, domain: domain, plistPath: path,
                                programPath: nil, programArguments: [], runAtLoad: false,
                                keepAlive: false, startInterval: nil, watchesPaths: false,
                                legacyDisabledKey: false, unreadable: true)
        }

        let label = (dict["Label"] as? String) ?? fallbackLabel
        let args = (dict["ProgramArguments"] as? [String]) ?? []
        let program = (dict["Program"] as? String) ?? args.first
        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false

        var keepAlive = false
        if let b = dict["KeepAlive"] as? Bool { keepAlive = b }
        else if let d = dict["KeepAlive"] as? [String: Any], !d.isEmpty { keepAlive = true }

        let startInterval = (dict["StartInterval"] as? NSNumber)?.intValue

        let watches = ((dict["WatchPaths"] as? [String])?.isEmpty == false)
            || ((dict["QueueDirectories"] as? [String])?.isEmpty == false)

        let legacyDisabled = (dict["Disabled"] as? Bool) ?? false

        var item = StartupItem(label: label, domain: domain, plistPath: path,
                            programPath: program, programArguments: args,
                            runAtLoad: runAtLoad, keepAlive: keepAlive,
                            startInterval: startInterval, watchesPaths: watches,
                            legacyDisabledKey: legacyDisabled, unreadable: false)
        if let program, program.hasPrefix("/") {
            var info = stat()
            let result = stat(program, &info)
            let failure = errno
            item.binaryMissing = result != 0 && (failure == ENOENT || failure == ENOTDIR)
        }
        return item
    }

    // MARK: launchctl correlation
    //
    // Shelling out through Process with an absolute path and an argument array — never a
    // shell string — because there is no framework API that returns launchd's live job
    // table or its per-service disabled bit.

    nonisolated private static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let result = ProjectProbe.runBounded(executable: path, arguments: args,
                                             timeout: 2, byteLimit: 1_048_576)
        if let error = result.error { return (-1, "Could not launch \(path): \(error)") }
        if result.timedOut { return (-1, "Command exceeded its two-second time limit.") }
        if result.truncated { return (-1, "Command output exceeded its one-megabyte limit.") }
        let status = result.exitCode ?? -1
        let output = String(data: result.data, encoding: .utf8) ?? ""
        return (status, status == 0 ? output : "Command failed (status \(status)). \(output)")
    }

    /// `launchctl list` — tab-separated "PID\tStatus\tLabel", one header line.
    /// Only ever shows jobs in the caller's own domains (gui/<uid> and below), which is
    /// exactly the user- and global-agent set; root daemons are invisible without sudo.
    nonisolated private static func listLoadedJobs() -> [String: ListedJob] {
        let (status, out) = run("/bin/launchctl", ["list"])
        guard status == 0 else { return [:] }
        var jobs: [String: ListedJob] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let pid = Int32(cols[0])
            let exit = Int32(cols[1])
            let label = String(cols[2])
            jobs[label] = ListedJob(pid: pid, lastExit: exit)
        }
        return jobs
    }

    /// `launchctl print-disabled <target>` — one of the only pieces of state launchd will
    /// hand over for the system domain without root.
    nonisolated private static func printDisabled(target: String) -> [String: Bool] {
        let (status, out) = run("/bin/launchctl", ["print-disabled", target])
        guard status == 0 else { return [:] }
        var result: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let closing = trimmed.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            if trimmed.hasSuffix("disabled") { result[label] = true }
            else if trimmed.hasSuffix("enabled") { result[label] = false }
        }
        return result
    }

    // MARK: process introspection — mirrors Memory.swift's house style exactly

    nonisolated private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// PROC_PIDTASKINFO, never proc_pid_rusage: rusage blocks on processes this user does
    /// not own, which would hang the whole scan the moment a root daemon's PID is asked
    /// about. Every item we call this for came out of `launchctl list` in our own gui
    /// domain, so it is always safe here — but the choice of API is the point, not luck.
    nonisolated static func cpuSeconds(pid: Int32) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard rc == size else { return nil }
        let ticks = info.pti_total_user + info.pti_total_system
        guard timebase.denom != 0 else { return Double(ticks) / 1_000_000_000 }
        let ns = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return ns / 1_000_000_000
    }

    nonisolated private static func fileSize(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    // MARK: - Actions
    //
    // Reversible, confirmed by the caller (the View shows an alert before invoking these),
    // and always logged. Only ~/Library/LaunchAgents is ever touched; everything else is
    // root's, and we say so instead of finding a way around it.

    enum ActionOutcome {
        case ok(String)
        case refused(String)
        case failed(String)
    }

    func setEnabled(_ item: StartupItem, enabled: Bool) -> ActionOutcome {
        let outcome = Self.performSetEnabled(item, enabled: enabled, uid: uid)
        remember(outcome)
        return outcome
    }

    func setEnabledAsync(_ item: StartupItem, enabled: Bool, publishResult: Bool = true) async -> ActionOutcome {
        let uid = self.uid
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.performSetEnabled(item, enabled: enabled, uid: uid)
        }.value
        if publishResult { remember(outcome) }
        return outcome
    }

    private func remember(_ outcome: ActionOutcome) {
        switch outcome {
        case .ok(let message), .refused(let message), .failed(let message): lastAction = message
        }
    }

    /// Rendering uses snapshots; bulk actions re-read the exact reviewed job and
    /// require that its missing-program/stub condition still holds.
    nonisolated static func revalidatedOrphans(_ items: [StartupItem]) -> [StartupItem] {
        items.filter { previous in
            let current = parsePlist(path: previous.plistPath, domain: previous.domain)
            return !current.unreadable && current.isOrphan
                && current.label == previous.label
                && current.programPath == previous.programPath
                && current.programArguments == previous.programArguments
                && current.runAtLoad == previous.runAtLoad
                && current.keepAlive == previous.keepAlive
                && current.startInterval == previous.startInterval
                && current.watchesPaths == previous.watchesPaths
        }
    }

    nonisolated private static func performSetEnabled(_ item: StartupItem, enabled: Bool,
                                                      uid: uid_t) -> ActionOutcome {
        guard item.domain.editableWithoutRoot else {
            let msg = "\(item.fileName) lives in \(item.domain.directory) and is owned by root. " +
                "FastMac deliberately does not ask for administrator rights to change it — " +
                "use Reveal in Finder, or System Settings › General › Login Items, or an admin Terminal."
            return .refused(msg)
        }
        let target = item.domain.target(uid: uid, label: item.label)
        let domainRoot = item.domain.domainRoot(uid: uid)

        if enabled {
            let en = Self.run("/bin/launchctl", ["enable", target])
            let bs = Self.run("/bin/launchctl", ["bootstrap", domainRoot, item.plistPath])
            // bootstrap fails with "service already loaded" if it raced a login — not an error.
            let ok = en.status == 0 || bs.status == 0
            Audit.log("startup-enable", bytes: 0, path: item.plistPath)
            let message = ok ? "Enabled \(item.owner) — \(item.label)"
                            : "Enable reported an error for \(item.label): \(en.out)\(bs.out)"
            return ok ? .ok(message) : .failed(message)
        } else {
            let bo = Self.run("/bin/launchctl", ["bootout", target])
            let di = Self.run("/bin/launchctl", ["disable", target])
            // bootout fails harmlessly if the job was not currently loaded; `disable`
            // (which sticks across reboots) is the one that has to succeed.
            let ok = di.status == 0
            Audit.log("startup-disable", bytes: 0, path: item.plistPath)
            let message = ok ? "Disabled \(item.owner) — \(item.label)"
                            : "Disable reported an error for \(item.label): \(bo.out)\(di.out)"
            return ok ? .ok(message) : .failed(message)
        }
    }

    func revealInFinder(_ item: StartupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.plistPath)])
    }
}
