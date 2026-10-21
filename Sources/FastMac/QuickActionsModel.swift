import AppKit
import ApplicationServices
import Combine
import Darwin
import Foundation

/// An Accessibility reply is a limited, point-in-time observation. A slow reply is
/// not proof that an app is frozen, and resource usage is never used to infer one.
enum QuickAppResponse: String, Sendable, CaseIterable {
    case unchecked, checking, responded, didNotRespond, unavailable

    var label: String {
        switch self {
        case .unchecked: return "Not checked"
        case .checking: return "Checking…"
        case .responded: return "Responded to check"
        case .didNotRespond: return "Did not respond to check"
        case .unavailable: return "Response unknown"
        }
    }
}

struct QuickActionApp: Identifiable {
    var name: String
    var bundleURL: URL?
    var icon: NSImage?
    var identity: ProcessIdentity
    var cpuPercent: Double? = nil
    var residentBytes: Int64? = nil
    var mainResidentBytes: Int64? = nil
    var mainResidentAt: Date? = nil
    var memoryIncludesHelpers = false
    var processCount: Int? = nil
    var metricsAt: Date? = nil
    var response: QuickAppResponse = .unchecked
    var responseCheckedAt: Date? = nil

    var id: String {
        "\(identity.pid)-\(identity.startedSeconds)-\(identity.startedMicroseconds)-\(identity.path)"
    }
    var appKey: String {
        MemoryProbe.appKey(path: identity.path, fallback: "pid \(identity.pid)")
    }
}

enum QuickActionsPolicy {
    static let metricsMaximumAge: TimeInterval = 75
    static let responseMaximumAge: TimeInterval = 60
    static let requestTimeout: Float = 0.25
    static let maximumCheckDuration: TimeInterval = 8
    static let maximumCheckedApps = 32

    /// Core desktop services have their own recovery flows. An ordinary Apple app
    /// such as Safari is still eligible; ownership and regular activation matter.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.dock",
        "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight"
    ]

    static func isEligible(identity: ProcessIdentity?, isRegular: Bool,
                           isTerminated: Bool, bundleID: String?,
                           currentUID: uid_t = getuid(), currentPID: pid_t = getpid()) -> Bool {
        guard let identity, isRegular, !isTerminated, identity.pid > 1,
              identity.pid != currentPID, identity.uid == currentUID,
              !identity.path.isEmpty, identity.startedSeconds > 0 else { return false }
        return !protectedBundleIDs.contains(bundleID ?? "")
    }

    static func applyMetrics(to app: QuickActionApp, snapshot: ActivitySnapshot?,
                             duplicateAppKeys: Set<String> = [], now: Date = Date()) -> QuickActionApp {
        var result = app
        result.cpuPercent = nil
        result.residentBytes = nil
        result.memoryIncludesHelpers = false
        result.processCount = nil
        result.metricsAt = nil
        if let checked = result.responseCheckedAt,
           now.timeIntervalSince(checked) > responseMaximumAge || checked > now.addingTimeInterval(1) {
            result.response = .unchecked
            result.responseCheckedAt = nil
        }
        if let mainRSS = app.mainResidentBytes, mainRSS >= 0,
           let at = app.mainResidentAt, at <= now.addingTimeInterval(1),
           now.timeIntervalSince(at) <= metricsMaximumAge {
            result.residentBytes = mainRSS
            result.metricsAt = at
        }
        guard let snapshot, !duplicateAppKeys.contains(app.appKey),
              snapshot.sampledAt <= now.addingTimeInterval(1),
              now.timeIntervalSince(snapshot.sampledAt) <= metricsMaximumAge else { return result }
        let launchedAt = Double(app.identity.startedSeconds) + Double(app.identity.startedMicroseconds) / 1_000_000
        guard snapshot.sampledAt.timeIntervalSince1970 >= launchedAt,
              let metrics = snapshot.apps.first(where: { $0.id == app.appKey }) else { return result }
        if let cpu = metrics.cpuPercent, cpu.isFinite, cpu >= 0 { result.cpuPercent = cpu }
        if let rss = metrics.rss, rss >= 0 {
            result.residentBytes = rss
            result.memoryIncludesHelpers = true
        }
        if metrics.processCount > 0 { result.processCount = metrics.processCount }
        result.metricsAt = snapshot.sampledAt
        return result
    }

    static func sorted(_ apps: [QuickActionApp]) -> [QuickActionApp] {
        apps.sorted { left, right in
            if (left.response == .didNotRespond) != (right.response == .didNotRespond) {
                return left.response == .didNotRespond
            }
            if left.residentBytes != right.residentBytes {
                return (left.residentBytes ?? -1) > (right.residentBytes ?? -1)
            }
            if left.name != right.name { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return left.identity.pid < right.identity.pid
        }
    }

    /// A quick messaging failure is ambiguous. Only two slow cannotComplete
    /// results become "did not respond", never "frozen" or "not responding".
    static func classify(_ attempts: [(error: AXError, elapsed: TimeInterval)], identityValid: Bool) -> QuickAppResponse {
        guard identityValid else { return .unavailable }
        if attempts.contains(where: { $0.error == .success }) { return .responded }
        let slowFailures = attempts.filter {
            $0.error == .cannotComplete && $0.elapsed >= Double(requestTimeout) * 0.8
        }
        return attempts.count == 2 && slowFailures.count == 2 ? .didNotRespond : .unavailable
    }
}

private final class QuickCheckCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

private enum QuickResponseProbe {
    /// Read only the application object's role. No windows, titles, document
    /// content, UI traversal, or Accessibility actions are requested here.
    static func check(identity: ProcessIdentity, cancellation: QuickCheckCancellation) -> QuickAppResponse {
        guard !cancellation.isCancelled, AXIsProcessTrusted(),
              ProcessIdentity.capture(pid: identity.pid) == identity else { return .unavailable }
        let element = AXUIElementCreateApplication(identity.pid)
        guard AXUIElementSetMessagingTimeout(element, QuickActionsPolicy.requestTimeout) == .success else {
            return .unavailable
        }
        var attempts: [(error: AXError, elapsed: TimeInterval)] = []
        for index in 0..<2 {
            if index > 0 { Thread.sleep(forTimeInterval: 0.1) }
            guard !cancellation.isCancelled, AXIsProcessTrusted(),
                  ProcessIdentity.capture(pid: identity.pid) == identity else { return .unavailable }
            let began = ProcessInfo.processInfo.systemUptime
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            attempts.append((error, elapsed))
            if error != .cannotComplete || elapsed < Double(QuickActionsPolicy.requestTimeout) * 0.8 { break }
        }
        return QuickActionsPolicy.classify(attempts,
            identityValid: ProcessIdentity.capture(pid: identity.pid) == identity)
    }
}

/// No timer, process sweep, folder scan, or permission prompt is started by this
/// model. The popup supplies the shared ActivityMonitor's latest snapshot.
@MainActor
final class QuickActionsModel: ObservableObject {
    @Published private(set) var apps: [QuickActionApp]
    @Published private(set) var isChecking = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var actionMessage: String?
    @Published private(set) var busyAppID: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var inventoryMilliseconds = 0.0

    private let fixtureMode: Bool
    private let queue = DispatchQueue(label: "FastMac.quick-response-check", qos: .utility)
    private var cancellation: QuickCheckCancellation?
    private var generation: UInt = 0

    init(apps: [QuickActionApp] = [], fixtureMode: Bool = false) {
        self.apps = QuickActionsPolicy.sorted(apps)
        self.fixtureMode = fixtureMode
    }

    func refresh(snapshot: ActivitySnapshot?) {
        guard !fixtureMode else { return }
        cancelChecks()
        let began = ProcessInfo.processInfo.systemUptime
        let prior = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let now = Date()
        var inventory: [QuickActionApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated,
                  let identity = ProcessIdentity.capture(pid: app.processIdentifier),
                  QuickActionsPolicy.isEligible(identity: identity, isRegular: true,
                    isTerminated: false, bundleID: app.bundleIdentifier) else { continue }
            var item = QuickActionApp(name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Application",
                bundleURL: app.bundleURL, icon: app.icon, identity: identity)
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(identity.pid, PROC_PIDTASKINFO, 0, &task, size) == size,
               ProcessIdentity.capture(pid: identity.pid) == identity,
               task.pti_resident_size <= UInt64(Int64.max) {
                item.mainResidentBytes = Int64(task.pti_resident_size)
                item.mainResidentAt = now
            }
            if let previous = prior[item.id], let checked = previous.responseCheckedAt,
               now.timeIntervalSince(checked) <= QuickActionsPolicy.responseMaximumAge {
                item.response = previous.response
                item.responseCheckedAt = checked
            }
            inventory.append(item)
        }
        apps = inventory
        updateMetrics(snapshot: snapshot)
        accessibilityTrusted = AXIsProcessTrusted() // Passive query; never prompts.
        inventoryMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1_000
    }

    func updateMetrics(snapshot: ActivitySnapshot?) {
        guard !fixtureMode else { return }
        let counts = Dictionary(grouping: apps, by: \.appKey)
        let duplicateKeys = Set(counts.filter { $0.value.count > 1 }.keys)
        apps = QuickActionsPolicy.sorted(apps.map {
            QuickActionsPolicy.applyMetrics(to: $0, snapshot: snapshot, duplicateAppKeys: duplicateKeys)
        })
    }

    /// Explicit user action only. Trust is checked without prompting. The caller
    /// may offer a separate Settings button if the user wants to grant access.
    func checkResponsiveness() {
        guard !fixtureMode, !isChecking else { return }
        actionMessage = nil
        accessibilityTrusted = AXIsProcessTrusted()
        guard accessibilityTrusted else {
            statusMessage = "Response checks need Accessibility access. You can still quit an app without it."
            return
        }
        guard !apps.isEmpty else { statusMessage = "No eligible open apps to check."; return }
        generation &+= 1
        let token = generation
        let flag = QuickCheckCancellation()
        cancellation = flag
        isChecking = true
        statusMessage = "Checking open apps…"
        let candidates = Array(apps.prefix(QuickActionsPolicy.maximumCheckedApps)).map { ($0.id, $0.identity) }
        let expectedCount = apps.count
        for index in apps.indices { apps[index].response = .unchecked; apps[index].responseCheckedAt = nil }
        for (id, _) in candidates {
            if let index = apps.firstIndex(where: { $0.id == id }) { apps[index].response = .checking }
        }
        queue.async { [weak self] in
            let began = ProcessInfo.processInfo.systemUptime
            var checked = 0
            for (id, identity) in candidates {
                guard !flag.isCancelled,
                      ProcessInfo.processInfo.systemUptime - began < QuickActionsPolicy.maximumCheckDuration - 0.6 else { break }
                let response = QuickResponseProbe.check(identity: identity, cancellation: flag)
                checked += 1
                let at = Date()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, !flag.isCancelled,
                          let index = self.apps.firstIndex(where: { $0.id == id && $0.identity == identity }) else { return }
                    self.apps[index].response = response
                    self.apps[index].responseCheckedAt = at
                }
            }
            let completedCount = checked
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !flag.isCancelled else { return }
                self.isChecking = false
                self.cancellation = nil
                self.lastCheckedAt = Date()
                for index in self.apps.indices where self.apps[index].response == .checking {
                    self.apps[index].response = .unchecked
                }
                self.apps = QuickActionsPolicy.sorted(self.apps)
                let missed = self.apps.filter { $0.response == .didNotRespond }.count
                if missed > 0 {
                    self.statusMessage = "\(missed) \(missed == 1 ? "app did" : "apps did") not reply to two brief checks. It may be busy or waiting for input."
                } else if completedCount < expectedCount {
                    self.statusMessage = "Checked \(completedCount) of \(expectedCount) apps within the time limit. Unchecked apps remain unknown."
                } else {
                    self.statusMessage = "Check complete. A reply confirms only that the app answered this request."
                }
            }
        }
    }

    func cancelChecks() {
        generation &+= 1
        cancellation?.cancel()
        cancellation = nil
        if isChecking { statusMessage = nil }
        isChecking = false
        for index in apps.indices where apps[index].response == .checking { apps[index].response = .unchecked }
    }

    /// The UI must ask for confirmation before calling this method. PerfActions
    /// revalidates PID, owner, launch time and executable immediately before use.
    func terminate(_ app: QuickActionApp, force: Bool) async -> (ok: Bool, message: String) {
        guard !fixtureMode else { return rejectAction("Actions are disabled in previews.") }
        guard busyAppID == nil else { return rejectAction("Wait for the current quit request to finish.") }
        guard apps.contains(where: { $0.id == app.id && $0.identity == app.identity }) else {
            return rejectAction("This app is no longer in the current list. Refresh and try again.")
        }
        guard let running = NSRunningApplication(processIdentifier: app.identity.pid),
              QuickActionsPolicy.isEligible(identity: ProcessIdentity.capture(pid: app.identity.pid),
                isRegular: running.activationPolicy == .regular, isTerminated: running.isTerminated,
                bundleID: running.bundleIdentifier) else {
            return rejectAction("This app exited or is no longer eligible. Refresh and try again.")
        }
        cancelChecks()
        busyAppID = app.id
        let result = await PerfActions.terminate(identity: app.identity, name: app.name, force: force)
        busyAppID = nil
        actionMessage = result.message
        if !PerfActions.isStillRunning(app.identity) { apps.removeAll { $0.id == app.id } }
        return result
    }

    private func rejectAction(_ message: String) -> (ok: Bool, message: String) {
        actionMessage = message
        return (false, message)
    }

    deinit { cancellation?.cancel() }
}
