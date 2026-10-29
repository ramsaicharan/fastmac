import SwiftUI
import AppKit
import ServiceManagement

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var fdaStatus: FullDiskAccess.Status?
    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @ObservedObject private var alerts = AlertManager.shared

    init(settings: Settings) { self.settings = settings }

    var body: some View {
        Form {
            Section {
                Toggle("Start in the menu bar", isOn: $settings.startInMenuBar)
                Toggle("Launch FastMac at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in updateLoginItem(enabled) }
                ))
                .disabled(!settings.supportsLaunchAtLogin)
                if loginStatus == .requiresApproval {
                    Label("Waiting for approval in Login Items", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                if !settings.supportsLaunchAtLogin {
                    Text("Launch the bundled FastMac.app to configure login launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Running FastMac") }
            footer: {
                Text("The startup choice applies on the next launch. Closing the dashboard keeps FastMac in the menu bar; use Quit FastMac to stop it. Login launch stays off until you enable it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Monitor Mac health in the background", isOn: $settings.healthMonitoringEnabled)
                Toggle("Show status beside the menu bar icon", isOn: $settings.menuBarSummaryEnabled)
                Picker("Menu bar readout", selection: $settings.menuBarMetric) {
                    Text("Health status").tag("status"); Text("CPU").tag("cpu")
                    Text("Memory").tag("memory"); Text("Network").tag("network")
                    Text("Free storage").tag("storage")
                }.disabled(!settings.menuBarSummaryEnabled)
            } header: { Text("Menu bar and monitoring") }
            footer: {
                Text("Monitoring reads system and readable process counters every 15 seconds without scanning folders. Pausing stops both health and activity sampling. Disk and AI scans remain manual.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Watch storage for leaks and growing caches", isOn: $settings.storageWatchEnabled)
            } header: { Text("Storage watch") }
            footer: {
                Text("Every 30 minutes FastMac notes your free space and lists the top level of your temp folder, without measuring sizes. About once a day, at low priority, it measures a short fixed list of cache folders and checks which large apps you haven’t opened in months. It never scans your documents and never removes anything on its own — fixes in the menu bar move items to the Trash after you confirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Record local activity history", isOn: $settings.recordActivityHistory)
                Picker("Keep recordings", selection: $settings.activityRetentionDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }
                Text("Stored only on this Mac, bounded to 100 MB. Clear recordings and export them from Activity History. App grouping identifiers can include local application paths; command arguments and project folders are not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Activity history") }

            Section {
                Toggle("Notify me about sustained resource problems", isOn: $settings.notificationsEnabled)
                Text(alerts.authorizationStatus).font(.caption).foregroundStyle(.secondary)
                if let until = alerts.snoozedUntil {
                    Text("Alerts snoozed until \(until.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resume alerts") { alerts.resumeAlerts() }
                } else {
                    Button("Snooze alerts for 1 hour") { alerts.snooze() }
                        .disabled(!settings.notificationsEnabled)
                }
                if let error = alerts.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Notifications") }
            footer: {
                Text("Optional alerts use macOS memory pressure, low storage, storage filling quickly, leftover browser test profiles, fast-growing caches and sustained app activity. Monitoring must be enabled. Notifications never quit apps or remove files.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                fdaRow
            } header: { Text("Full Disk Access") }
            footer: {
                Text("Full Disk Access is optional and macOS remembers your permission choices. Check access when a scan cannot read protected folders such as Mail or parts of Library. This check is best-effort; opening Settings does not check protected folders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Label("Reviewed items move to the Trash", systemImage: "trash")
                Text("FastMac asks before moving your cleanup queue. Trash remains recoverable until you empty it in Finder; moving items there does not free volume space.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reveal Cleanup Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([Audit.url])
                }
            } header: { Text("Cleanup") }
            footer: {
                Text("Scans and health monitoring never remove files. Protected paths are checked again before each move. Recent cleanup actions are recorded locally in ~/.fastmac/cleanup.log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 580, idealHeight: 640)
        .onAppear(perform: refreshLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
    }

    private func refreshLoginStatus() {
        if settings.supportsLaunchAtLogin { loginStatus = settings.launchAtLoginStatus }
    }

    private func updateLoginItem(_ enabled: Bool) {
        loginError = nil
        do {
            try settings.setLaunchAtLogin(enabled)
        } catch {
            loginError = "Could not update login launch: \(error.localizedDescription)"
        }
        loginStatus = settings.launchAtLoginStatus
    }

    private var fdaRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(fdaLabel, systemImage: fdaIcon)
                .foregroundStyle(fdaColor)
                .accessibilityLabel(fdaLabel)
            HStack {
                Button(fdaStatus == nil ? "Check Access" : "Recheck Access") {
                    fdaStatus = settings.fullDiskAccessStatus
                }
                if fdaStatus != .granted {
                    Button("Open Privacy Settings…") {
                        FullDiskAccess.openSettings()
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private var fdaIcon: String {
        switch fdaStatus {
        case .granted: "checkmark.shield.fill"
        case .denied: "xmark.shield.fill"
        case .unknown, nil: "questionmark.diamond.fill"
        }
    }

    private var fdaColor: Color {
        FDACheck.color(for: fdaStatus)
    }

    private var fdaLabel: String {
        FDACheck.label(for: fdaStatus)
    }
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "FastMac Settings"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
