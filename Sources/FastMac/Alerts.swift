import Foundation
import UserNotifications
import Combine
import CryptoKit

// MARK: - Pure decision logic
//
// Kept free of UNUserNotificationCenter so it can be driven and unit-checked
// headlessly (see ShellSelfCheck) without touching notification permissions.
// Two conditions, each independently edge-triggered and rate-limited:
//
//   disk   — fires the instant free space crosses below the threshold. Latches
//            (via `diskBad`) so it cannot fire again until free space recovers
//            above the threshold and drops below it a second time.
//   memory — requires pressure to stay at/above the threshold continuously for
//            `sustainedSeconds` before it counts as a real transition (a brief
//            spike must not alert), then latches the same way.
//
// Both also enforce a rate limit as a second, independent guard, so a threshold
// that flickers across the line for any reason still cannot spam more than once
// per window.

struct AlertEvaluator {
    var freeDiskThresholdBytes: Int64
    var memoryPressureThreshold: Double
    var sustainedSeconds: TimeInterval
    var rateLimit: TimeInterval

    enum Condition: String { case disk, memory }

    private(set) var diskBad = false
    private(set) var memBadSince: Date?
    private(set) var memLatched = false
    private(set) var lastFire: [Condition: Date] = [:]

    init(freeDiskThresholdBytes: Int64 = 10 << 30,
         memoryPressureThreshold: Double = 85,
         sustainedSeconds: TimeInterval = 5 * 60,
         rateLimit: TimeInterval = 6 * 3600) {
        self.freeDiskThresholdBytes = freeDiskThresholdBytes
        self.memoryPressureThreshold = memoryPressureThreshold
        self.sustainedSeconds = sustainedSeconds
        self.rateLimit = rateLimit
    }

    private func canFire(_ c: Condition, now: Date) -> Bool {
        guard let last = lastFire[c] else { return true }
        return now.timeIntervalSince(last) >= rateLimit
    }

    /// Adapts the real kernel/dispatch pressure flag to the legacy numeric fixture
    /// API. RAM occupancy is deliberately absent from this decision.
    static func operatingSystemPressure(_ level: HealthMemoryPressure) -> Double? {
        switch level {
        case .normal: return 0
        case .warning, .critical: return 100
        case .unknown: return nil
        }
    }

    /// Feed one fresh sample in. Returns the conditions that should notify right now
    /// (usually empty). Call this on every poll tick, in order — it is stateful.
    mutating func evaluate(diskFree: Int64, pressure: Double, now: Date = Date()) -> [Condition] {
        let fires = candidates(diskFree: diskFree, pressure: pressure, now: now)
        for condition in fires { commit(condition, now: now) }
        return fires
    }

    /// Live delivery is transactional: permission denial or notification scheduling
    /// failure must not consume a transition. Only `commit` marks it as reported.
    mutating func candidates(diskFree: Int64?, pressure: Double?, now: Date = Date()) -> [Condition] {
        var fires: [Condition] = []

        // A full disk is a *persistent* danger, not a momentary one. Only mark the
        // condition as "already reported" when we actually reported it — otherwise a
        // rate-limited first firing would swallow the edge, and the user would never be
        // warned again for as long as the disk stayed full.
        if let diskFree, diskFree >= 0 {
            let diskNowBad = diskFree < freeDiskThresholdBytes
            if diskNowBad {
                if !diskBad, canFire(.disk, now: now) {
                    fires.append(.disk)
                }
                // Still bad but suppressed: leave diskBad alone so the edge survives.
            } else {
                diskBad = false
            }
        }

        if let pressure, pressure.isFinite, pressure >= memoryPressureThreshold {
            if memBadSince == nil { memBadSince = now }
            let sustained = now.timeIntervalSince(memBadSince!) >= sustainedSeconds
            if sustained, !memLatched, canFire(.memory, now: now) {
                fires.append(.memory)
            }
        } else {
            memBadSince = nil
            memLatched = false
        }
        return fires
    }

    mutating func commit(_ condition: Condition, now: Date) {
        lastFire[condition] = now
        switch condition {
        case .disk: diskBad = true
        case .memory: memLatched = true
        }
    }

    mutating func seedCooldowns(_ cooldowns: [Condition: Date]) { lastFire = cooldowns }
    mutating func resetObservation() {
        diskBad = false
        memBadSince = nil
        memLatched = false
    }
}


struct ActivityAlertCandidate {
    enum Kind { case cpu, memoryGrowth }
    let kind: Kind
    let appID: String
    let key: String
    let title: String
    let body: String
}

/// Observed resident-memory growth is a review cue, never a memory-leak diagnosis.
/// Missing readings, app disappearance, pauses, and collection sessions break continuity.
struct ActivityAlertEvaluator {
    static let cpuThreshold: Double = 80
    static let cpuSustained: TimeInterval = 120
    static let memoryGrowthBytes: Int64 = 500 * 1_024 * 1_024
    static let memoryWindow: TimeInterval = 30 * 60
    static let maximumSampleGap: TimeInterval = 60
    static let rateLimit: TimeInterval = 6 * 60 * 60

    private struct AppState {
        var cpuSince: Date?
        var cpuLatched = false
        var memory: [(date: Date, rss: Int64)] = []
        var memoryLatched = false
    }
    private var states: [String: AppState] = [:]
    private var sessionID: String?
    private var previousSample: Date?
    private(set) var lastFire: [String: Date] = [:]

    static func key(_ kind: ActivityAlertCandidate.Kind, appID: String) -> String {
        let hash = SHA256.hash(data: Data(appID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "app.\(kind == .cpu ? "cpu" : "memory-growth").\(hash)"
    }

    mutating func resetObservation() {
        states = [:]
        sessionID = nil
        previousSample = nil
    }
    mutating func seedCooldowns(_ cooldowns: [String: Date]) { lastFire = cooldowns }

    mutating func candidates(_ snapshot: ActivitySnapshot) -> [ActivityAlertCandidate] {
        let now = snapshot.sampledAt
        if sessionID != snapshot.sessionID {
            states = [:]
            previousSample = nil
            sessionID = snapshot.sessionID
        }
        if let previousSample {
            guard now > previousSample else { return [] }
            if now.timeIntervalSince(previousSample) > Self.maximumSampleGap { states = [:] }
        }
        previousSample = now
        let currentIDs = Set(snapshot.apps.map(\.id))
        states = states.filter { currentIDs.contains($0.key) }
        var candidates: [ActivityAlertCandidate] = []

        for app in snapshot.apps {
            var state = states[app.id] ?? AppState()
            let cpuKey = Self.key(.cpu, appID: app.id)
            if let cpu = app.cpuPercent, cpu.isFinite, cpu > Self.cpuThreshold {
                if state.cpuSince == nil { state.cpuSince = now }
                if now.timeIntervalSince(state.cpuSince!) >= Self.cpuSustained,
                   !state.cpuLatched, canFire(cpuKey, now: now) {
                    candidates.append(ActivityAlertCandidate(kind: .cpu, appID: app.id, key: cpuKey,
                        title: "Sustained app CPU activity",
                        body: "\(app.name) used more than 80% of one CPU core for 2 minutes. Review its current activity in Performance."))
                }
            } else {
                state.cpuSince = nil
                state.cpuLatched = false
            }

            let memoryKey = Self.key(.memoryGrowth, appID: app.id)
            if let rss = app.rss, rss >= 0 {
                // One point per 15 seconds bounds memory even with a faster shared collector.
                if state.memory.last.map({ now.timeIntervalSince($0.date) >= 15 }) ?? true {
                    state.memory.append((now, rss))
                }
                let cutoff = now.addingTimeInterval(-Self.memoryWindow)
                while state.memory.count > 1, state.memory[1].date <= cutoff {
                    state.memory.removeFirst()
                }
                if let first = state.memory.first,
                   now.timeIntervalSince(first.date) >= Self.memoryWindow, state.memory.count >= 10 {
                    let growth = rss >= first.rss ? rss - first.rss : 0
                    if growth >= Self.memoryGrowthBytes {
                        if !state.memoryLatched, canFire(memoryKey, now: now) {
                            candidates.append(ActivityAlertCandidate(kind: .memoryGrowth,
                                appID: app.id, key: memoryKey, title: "App memory increased",
                                body: "\(app.name)'s resident memory increased by \(fmt(growth)) over 30 minutes. Caches and active work can cause growth; review it in Performance."))
                        }
                    } else { state.memoryLatched = false }
                }
            } else {
                state.memory = []
                state.memoryLatched = false
            }
            states[app.id] = state
        }
        return candidates
    }

    private func canFire(_ key: String, now: Date) -> Bool {
        lastFire[key].map { now.timeIntervalSince($0) >= Self.rateLimit } ?? true
    }

    mutating func commit(_ candidate: ActivityAlertCandidate, now: Date) {
        lastFire[candidate.key] = now
        guard var state = states[candidate.appID] else { return }
        switch candidate.kind {
        case .cpu: state.cpuLatched = true
        case .memoryGrowth: state.memoryLatched = true
        }
        states[candidate.appID] = state
    }
}

/// Observes the shared collectors. Enabling notifications is an explicit Settings
/// choice; no permission request, probe, sweep, or timer runs while disabled.
enum AlertSnoozePolicy {
    static func until(minutes: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(Double(max(1, min(1_440, minutes))) * 60)
    }
    static func isActive(until: Date?, now: Date = Date()) -> Bool {
        guard let until else { return false }
        return until.timeIntervalSince1970.isFinite && until > now
    }
}

@MainActor
final class AlertManager: ObservableObject {
    static let shared = AlertManager()
    static let cooldownKey = "FastMac.AlertCooldowns"
    static let snoozeKey = "FastMac.AlertSnoozedUntil"

    @Published private(set) var authorizationStatus = "Disabled"
    @Published private(set) var error: String?
    @Published private(set) var snoozedUntil: Date?

    private var healthEvaluator = AlertEvaluator()
    private var activityEvaluator = ActivityAlertEvaluator()
    private var subscriptions: Set<AnyCancellable> = []
    private var cooldowns: [String: Date] = [:]
    private var pending: Set<String> = []
    private var authorized = false
    private var enabled = false
    private var generation = 0
    private var lastHealthSample: Date?
    private weak var health: HealthMonitor?
    private weak var activity: ActivityMonitor?

    private init() {
        let timestamp = UserDefaults.standard.double(forKey: Self.snoozeKey)
        if timestamp.isFinite {
            let until = Date(timeIntervalSince1970: timestamp)
            if AlertSnoozePolicy.isActive(until: until) { snoozedUntil = until }
        }
        let stored = UserDefaults.standard.dictionary(forKey: Self.cooldownKey) ?? [:]
        cooldowns = stored.reduce(into: [:]) { result, entry in
            guard let timestamp = entry.value as? Double, timestamp.isFinite else { return }
            result[entry.key] = Date(timeIntervalSince1970: timestamp)
        }
        seedCooldowns()
    }

    func configure(health: HealthMonitor, activity: ActivityMonitor, enabled: Bool) {
        stopObserving()
        self.health = health
        self.activity = activity
        self.enabled = enabled
        guard enabled else {
            authorized = false
            authorizationStatus = "Disabled"
            error = nil
            return
        }
        authorized = false
        requestAuthorization()
        guard health.isMonitoring else {
            authorizationStatus = "Monitoring paused"
            return
        }
        let epoch = generation
        health.$sample.sink { [weak self, weak health] sample in
            guard let sample else { return }
            Task { @MainActor in
                guard let self, let health, self.generation == epoch, self.enabled,
                      health.isMonitoring else { return }
                self.evaluateHealth(sample)
            }
        }.store(in: &subscriptions)
        if activity.isMonitoring {
            activity.$latest.sink { [weak self, weak activity] snapshot in
                guard let snapshot else { return }
                Task { @MainActor in
                    guard let self, let activity, self.generation == epoch, self.enabled,
                          activity.isMonitoring else { return }
                    self.evaluateActivity(snapshot)
                }
            }.store(in: &subscriptions)
        }
    }

    func stop() {
        enabled = false
        authorized = false
        stopObserving()
        authorizationStatus = "Disabled"
    }

    func snooze(minutes: Int = 60) {
        snoozedUntil = AlertSnoozePolicy.until(minutes: minutes)
        UserDefaults.standard.set(snoozedUntil?.timeIntervalSince1970, forKey: Self.snoozeKey)
        resetObservations()
    }

    func resumeAlerts() {
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
        resetObservations()
    }

    private func resetObservations() {
        lastHealthSample = nil
        healthEvaluator.resetObservation()
        activityEvaluator.resetObservation()
    }

    private func suspendForSnooze() -> Bool {
        if AlertSnoozePolicy.isActive(until: snoozedUntil) {
            resetObservations()
            return true
        }
        if snoozedUntil != nil { resumeAlerts() }
        return false
    }

    private func stopObserving() {
        generation &+= 1
        subscriptions = []
        pending = []
        lastHealthSample = nil
        healthEvaluator.resetObservation()
        activityEvaluator.resetObservation()
    }

    private func seedCooldowns() {
        var system: [AlertEvaluator.Condition: Date] = [:]
        system[.disk] = cooldowns["system.disk"]
        system[.memory] = cooldowns["system.memory"]
        healthEvaluator.seedCooldowns(system)
        activityEvaluator.seedCooldowns(cooldowns.filter { $0.key.hasPrefix("app.") })
    }

    private func requestAuthorization() {
        let epoch = generation
        authorizationStatus = "Checking permission…"
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self, self.enabled, self.generation == epoch else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.authorized = true
                    self.authorizationStatus = "Allowed"
                    self.error = nil
                    self.evaluateLatest()
                case .denied:
                    self.authorized = false
                    self.authorizationStatus = "Denied in System Settings"
                    self.error = nil
                case .notDetermined:
                    self.authorized = false
                    self.authorizationStatus = "Awaiting permission…"
                    self.requestPermission(epoch: epoch)
                @unknown default:
                    self.authorized = false
                    self.authorizationStatus = "Unavailable"
                }
            }
        }
    }

    private func requestPermission(epoch: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, failure in
            Task { @MainActor in
                guard let self, self.enabled, self.generation == epoch else { return }
                self.authorized = granted
                self.error = failure?.localizedDescription
                self.authorizationStatus = failure != nil ? "Permission unavailable"
                    : granted ? "Allowed" : "Denied in System Settings"
                if granted { self.evaluateLatest() }
            }
        }
    }

    private func evaluateLatest() {
        guard health?.isMonitoring == true else { return }
        if let sample = health?.sample {
            // A pending edge should be retried once permission becomes available.
            lastHealthSample = nil
            evaluateHealth(sample)
        }
        // App continuity continues from subsequent real snapshots. Replaying a
        // cached sample must not manufacture an extra interval of sustained work.
    }

    private func evaluateHealth(_ sample: HealthSample) {
        guard !suspendForSnooze() else { return }
        if let previous = lastHealthSample {
            guard sample.sampledAt > previous else { return }
            if sample.sampledAt.timeIntervalSince(previous) > ActivityAlertEvaluator.maximumSampleGap {
                healthEvaluator.resetObservation()
            }
        }
        lastHealthSample = sample.sampledAt
        // These numbers represent a boolean OS pressure event for the legacy pure
        // evaluator. They are not the occupied-RAM percentage from MemoryProbe.
        let pressure = AlertEvaluator.operatingSystemPressure(sample.memoryPressure)
        let candidates = healthEvaluator.candidates(diskFree: sample.diskAvailable ? sample.diskFree : nil,
                                                    pressure: pressure, now: sample.sampledAt)
        for condition in candidates {
            let title: String
            let body: String
            switch condition {
            case .disk:
                title = "Low disk space"
                body = "\(fmt(sample.diskFree)) is free of \(fmt(sample.diskTotal)). Review storage before deleting anything."
            case .memory:
                title = "Sustained macOS memory pressure"
                body = "macOS reported elevated memory pressure for at least 5 minutes. Review current app activity in Performance."
            }
            deliver(key: "system.\(condition.rawValue)", title: title, body: body,
                    systemCondition: condition, appCandidate: nil)
        }
    }

    private func evaluateActivity(_ snapshot: ActivitySnapshot) {
        guard !suspendForSnooze() else { return }
        for candidate in activityEvaluator.candidates(snapshot) {
            deliver(key: candidate.key, title: candidate.title, body: candidate.body,
                    systemCondition: nil, appCandidate: candidate)
        }
    }

    /// Storage findings arrive already edge-triggered from StorageWatch. Returns whether
    /// delivery was attempted, so a refusal — alerts off, no permission, snoozed, or still
    /// cooling down — leaves the rise for later instead of silently using it up.
    @discardableResult
    func notifyStorage(_ finding: StorageFinding, now: Date = Date()) -> Bool {
        guard enabled, authorized, !AlertSnoozePolicy.isActive(until: snoozedUntil, now: now) else { return false }
        let key = "storage.\(finding.id)"
        if let last = cooldowns[key], now.timeIntervalSince(last) < 12 * 3_600 { return false }
        let size = finding.sizeText.map { " (\($0))" } ?? ""
        deliver(key: key, title: finding.title + size, body: finding.detail + " Nothing is removed until you choose to.",
                systemCondition: nil, appCandidate: nil)
        return true
    }

    private func deliver(key: String, title: String, body: String,
                         systemCondition: AlertEvaluator.Condition?, appCandidate: ActivityAlertCandidate?) {
        guard enabled, authorized, !AlertSnoozePolicy.isActive(until: snoozedUntil), !pending.contains(key) else { return }
        pending.insert(key)
        let epoch = generation
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fastmac.\(key).\(UUID().uuidString)",
                                             content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if self.generation == epoch { self.pending.remove(key) }
                guard failure == nil else {
                    if self.generation == epoch { self.error = "Notification could not be scheduled: " + failure!.localizedDescription }
                    return
                }
                let acceptedAt = Date()
                self.cooldowns[key] = acceptedAt
                self.persistCooldowns(now: acceptedAt)
                self.seedCooldowns()
                if self.generation == epoch {
                    self.error = nil
                    if let systemCondition { self.healthEvaluator.commit(systemCondition, now: acceptedAt) }
                    if let appCandidate { self.activityEvaluator.commit(appCandidate, now: acceptedAt) }
                }
            }
        }
    }

    private func persistCooldowns(now: Date) {
        cooldowns = cooldowns.filter { now.timeIntervalSince($0.value) <= 30 * 86_400 }
        if cooldowns.count > 256 {
            cooldowns = Dictionary(uniqueKeysWithValues: cooldowns.sorted { $0.value > $1.value }
                .prefix(256).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(cooldowns.mapValues(\.timeIntervalSince1970), forKey: Self.cooldownKey)
    }
}
