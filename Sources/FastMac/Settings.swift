import Foundation
import Combine
import ServiceManagement

// MARK: - Settings
//
// A UserDefaults-backed ObservableObject other code can read. It takes its UserDefaults
// instance by injection (defaulting to `.standard`) so tests — see MaintSelfCheck — can
// exercise a real round trip through a throwaway suite instead of touching the user's
// actual preferences.
//
// Current menu-bar preferences use the FastMac.* namespace. Older scan preferences
// are retained so existing installations and self-checks keep their stored values.

/// Legacy stored preference. Cleanup uses Trash regardless of this value.
enum RemovalMode: String, CaseIterable, Identifiable, Codable {
    case trash
    case permanent

    var id: String { rawValue }
    var label: String {
        switch self {
        case .trash: "Move to Trash (recommended)"
        case .permanent: "Delete permanently — cannot be undone"
        }
    }
}

/// Legacy stored label preference. Formatting currently retains its fixed units.
enum SizeUnitStyle: String, CaseIterable, Identifiable, Codable {
    case binary   // 1024^n, labeled GiB/MiB/KiB — matches the math `fmt()` already does
    case decimal  // 1024^n math, labeled GB/MB/KB — matches `fmt()`'s current labels

    var id: String { rawValue }
    var label: String {
        switch self {
        case .binary: "Binary (GiB, MiB — accurate label for 1024-based math)"
        case .decimal: "Decimal (GB, MB — matches macOS's own labels)"
        }
    }
    var units: [String] {
        switch self {
        case .binary: ["B", "KiB", "MiB", "GiB", "TiB"]
        case .decimal: ["B", "KB", "MB", "GB", "TB"]
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    static let startInMenuBarKey = "FastMac.StartInMenuBar"
    static let healthMonitoringEnabledKey = "FastMac.HealthMonitoringEnabled"
    static let menuBarSummaryEnabledKey = "FastMac.MenuBarSummaryEnabled"
    static let menuBarMetricKey = "FastMac.MenuBarMetric"
    static let recordActivityHistoryKey = "FastMac.RecordActivityHistory"
    static let activityRetentionDaysKey = "FastMac.ActivityRetentionDays"
    static let notificationsEnabledKey = "FastMac.NotificationsEnabled"
    static let storageWatchEnabledKey = "FastMac.StorageWatchEnabled"

    private enum Key {
        static let exclusions = "fastmac.settings.exclusions"
        static let bigFileThresholdMB = "fastmac.settings.bigFileThresholdMB"
        static let untouchedSizeThresholdMB = "fastmac.settings.untouchedSizeThresholdMB"
        static let untouchedAgeDays = "fastmac.settings.untouchedAgeDays"
        static let removalMode = "fastmac.settings.removalMode"
        static let confirmBeforeStaging = "fastmac.settings.confirmBeforeStaging"
        static let logCleanupToFile = "fastmac.settings.logCleanupToFile"
        static let unitStyle = "fastmac.settings.unitStyle"
    }

    private let d: UserDefaults

    /// Applies on the next launch. The menu bar remains available while windows close.
    @Published var startInMenuBar: Bool {
        didSet { d.set(startInMenuBar, forKey: Self.startInMenuBarKey) }
    }

    /// Enables lightweight health samples; it never schedules a filesystem scan.
    @Published var healthMonitoringEnabled: Bool {
        didSet { d.set(healthMonitoringEnabled, forKey: Self.healthMonitoringEnabledKey) }
    }

    @Published var menuBarSummaryEnabled: Bool {
        didSet { d.set(menuBarSummaryEnabled, forKey: Self.menuBarSummaryEnabledKey) }
    }
    @Published var menuBarMetric: String {
        didSet { d.set(menuBarMetric, forKey: Self.menuBarMetricKey) }
    }
    @Published var recordActivityHistory: Bool {
        didSet { d.set(recordActivityHistory, forKey: Self.recordActivityHistoryKey) }
    }
    @Published var activityRetentionDays: Int {
        didSet { d.set(max(1, min(30, activityRetentionDays)), forKey: Self.activityRetentionDaysKey) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { d.set(notificationsEnabled, forKey: Self.notificationsEnabledKey) }
    }
    /// Light, bounded storage readings — see StorageWatch for exactly what is read and when.
    /// Separate from health monitoring because it lists the temp folder and, once a day,
    /// measures a fixed set of cache folders.
    @Published var storageWatchEnabled: Bool {
        didSet { d.set(storageWatchEnabled, forKey: Self.storageWatchEnabledKey) }
    }

    /// Paths a scan should skip entirely. Stored as expanded, standardized absolute
    /// paths (e.g. "/Users/name/Documents"), matched by prefix at scan time.
    @Published var exclusions: [String] { didSet { d.set(exclusions, forKey: Key.exclusions) } }

    /// Legacy stored threshold; Scanner currently uses its own fixed threshold.
    @Published var bigFileThresholdMB: Double {
        didSet { d.set(bigFileThresholdMB, forKey: Key.bigFileThresholdMB) }
    }

    /// Legacy stored threshold; ListViews currently uses its own fixed threshold.
    @Published var untouchedSizeThresholdMB: Double {
        didSet { d.set(untouchedSizeThresholdMB, forKey: Key.untouchedSizeThresholdMB) }
    }

    /// Legacy stored threshold; ListViews currently uses its own fixed threshold.
    @Published var untouchedAgeDays: Double {
        didSet { d.set(untouchedAgeDays, forKey: Key.untouchedAgeDays) }
    }

    @Published var removalMode: RemovalMode {
        didSet { d.set(removalMode.rawValue, forKey: Key.removalMode) }
    }

    @Published var confirmBeforeStaging: Bool {
        didSet { d.set(confirmBeforeStaging, forKey: Key.confirmBeforeStaging) }
    }

    @Published var logCleanupToFile: Bool {
        didSet { d.set(logCleanupToFile, forKey: Key.logCleanupToFile) }
    }

    @Published var unitStyle: SizeUnitStyle {
        didSet { d.set(unitStyle.rawValue, forKey: Key.unitStyle) }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        startInMenuBar = defaults.object(forKey: Self.startInMenuBarKey) as? Bool ?? true
        healthMonitoringEnabled = defaults.object(forKey: Self.healthMonitoringEnabledKey) as? Bool ?? true
        menuBarSummaryEnabled = defaults.object(forKey: Self.menuBarSummaryEnabledKey) as? Bool ?? true
        let metric = defaults.string(forKey: Self.menuBarMetricKey) ?? "status"
        menuBarMetric = ["status", "cpu", "memory", "network", "storage"].contains(metric) ? metric : "status"
        recordActivityHistory = defaults.object(forKey: Self.recordActivityHistoryKey) as? Bool ?? true
        activityRetentionDays = max(1, min(30, defaults.object(forKey: Self.activityRetentionDaysKey) as? Int ?? 30))
        notificationsEnabled = defaults.object(forKey: Self.notificationsEnabledKey) as? Bool ?? false
        storageWatchEnabled = defaults.object(forKey: Self.storageWatchEnabledKey) as? Bool ?? true
        exclusions = defaults.stringArray(forKey: Key.exclusions) ?? []
        bigFileThresholdMB = defaults.object(forKey: Key.bigFileThresholdMB) as? Double ?? 50
        untouchedSizeThresholdMB = defaults.object(forKey: Key.untouchedSizeThresholdMB) as? Double ?? 100
        untouchedAgeDays = defaults.object(forKey: Key.untouchedAgeDays) as? Double ?? 365
        removalMode = (defaults.string(forKey: Key.removalMode)).flatMap(RemovalMode.init) ?? .trash
        confirmBeforeStaging = defaults.object(forKey: Key.confirmBeforeStaging) as? Bool ?? true
        logCleanupToFile = defaults.object(forKey: Key.logCleanupToFile) as? Bool ?? true
        unitStyle = (defaults.string(forKey: Key.unitStyle)).flatMap(SizeUnitStyle.init) ?? .decimal
    }

    // MARK: exclusion list editing

    func addExclusion(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard !standardized.isEmpty, standardized != "/", !exclusions.contains(standardized) else { return }
        exclusions.append(standardized)
    }

    func removeExclusion(_ path: String) {
        exclusions.removeAll { $0 == path }
    }

    /// True when `path` falls inside any configured exclusion — the check other scan
    /// code should call before walking into a directory.
    func isExcluded(_ path: String) -> Bool {
        exclusions.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    // MARK: Full Disk Access

    var fullDiskAccessStatus: FullDiskAccess.Status { FullDiskAccess.check() }

    // MARK: Launch at login

    var supportsLaunchAtLogin: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// Called only from the user's Settings switch. Never registers at startup.
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            guard launchAtLoginStatus != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard launchAtLoginStatus != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: cleanup log path (~/.fastmac/cleanup.log — the same file Audit already writes)

    var cleanupLogPath: String { Audit.url.path }
}
