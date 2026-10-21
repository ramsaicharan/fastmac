import SwiftUI
import Combine

enum FastMacApp {
    static func launch() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        objc_setAssociatedObject(app, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var commandShortcut: CommandShortcut?
    private var menuBar: MenuBarController?
    private var subscriptions: Set<AnyCancellable> = []
    let store = AppStore()
    let health = HealthMonitor()
    let aiStorage = AIStorageService()
    let activity = ActivityMonitor(allowsPersistence: !CommandLine.arguments.contains("--app-smoke"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()
        MenuActions.shared.store = store
        if !CommandLine.arguments.contains("--app-smoke") {
            commandShortcut = CommandShortcut { MenuActions.shared.openCommandPalette() }
            store.commandShortcutRegistered = commandShortcut?.registered == true
        }
        MenuActions.shared.onOpenDashboard = { [weak self] in self?.showDashboard() }
        MenuActions.shared.onOpenSettings = { [weak self] in self?.showSettings() }
        MenuActions.shared.onOpenQuickActions = { [weak self] in self?.menuBar?.showPopover() }

        Settings.shared.$healthMonitoringEnabled.sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.health.start(); self.activity.start() }
            else { self.health.stop(); self.activity.stop() }
            self.configureAlerts()
        }.store(in: &subscriptions)
        Settings.shared.$notificationsEnabled.sink { [weak self] enabled in
            guard let self else { return }
            AlertManager.shared.configure(health: self.health, activity: self.activity,
                enabled: enabled && self.health.isMonitoring && !CommandLine.arguments.contains("--app-smoke"))
        }.store(in: &subscriptions)
        Settings.shared.$activityRetentionDays.sink { [weak self] days in
            self?.activity.applyRetention(days: days)
        }.store(in: &subscriptions)

        menuBar = MenuBarController(health: health, store: store, activity: activity,
            onNavigate: { [weak self] view in self?.showDashboard(view: view) },
            onScanHome: { [weak self] in
                self?.showDashboard(view: .folders)
                self?.store.scan(path: NSHomeDirectory())
            },
            onSettings: { [weak self] in self?.showSettings() },
            onUnavailable: { [weak self] in self?.showDashboard() })

        if CommandLine.arguments.contains("--app-smoke") {
            runSmokeChecks()
        } else if CommandLine.arguments.contains("--dashboard")
                    || !Settings.shared.startInMenuBar || menuBar?.isInstalled != true {
            showDashboard()
        }
        resumeFullDiskAccessFlow()
    }

    /// System Settings relaunches FastMac through "Quit & Reopen" after Full Disk
    /// Access is turned on. Only when the user started that flow, confirm access
    /// and offer the rescan they were after.
    private func resumeFullDiskAccessFlow() {
        guard !CommandLine.arguments.contains("--app-smoke"),
              UserDefaults.standard.bool(forKey: FullDiskAccess.pendingRescanKey),
              FullDiskAccess.check() == .granted else { return }
        UserDefaults.standard.removeObject(forKey: FullDiskAccess.pendingRescanKey)
        showDashboard(view: .folders)
        store.fullDiskAccessPrompt = .granted
    }

    func showDashboard(view: ViewKind? = nil) {
        if let view { store.view = view }
        store.dashboardActive = true
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            created.title = "FastMac — Mac Health"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            created.setFrameAutosaveName("FastMacMain")
            created.contentView = NSHostingView(rootView:
                ContentView(health: health, aiStorage: aiStorage, activity: activity,
                            allowsOnboarding: !CommandLine.arguments.contains("--app-smoke"))
                    .environmentObject(store))
            window = created
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "FastMac Settings"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            created.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            settingsWindow = created
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        if closed === window {
            store.dashboardActive = false
            store.suspendInteractiveWork()
            aiStorage.cancel()
            // Destroy the hosting hierarchy: visible-tab process timers must disappear
            // even though the menu bar app remains alive.
            closed.contentView = nil
            window = nil
        }
        if closed === settingsWindow {
            closed.contentView = nil
            settingsWindow = nil
        }
        if window == nil, settingsWindow == nil {
            if menuBar?.isInstalled == true {
                NSApp.setActivationPolicy(.accessory)
            } else {
                // An app with its status item disabled still needs a reachable Dock icon.
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            store.dashboardActive = false
            store.setMemoryVisible(false)
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === window { store.dashboardActive = true }
    }

    func applicationDidHide(_ notification: Notification) {
        store.dashboardActive = false
        store.setMemoryVisible(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        store.dashboardActive = window?.isVisible == true && window?.isMiniaturized == false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store.purgeInFlight {
            store.banner = "Wait for the move to Trash to finish before quitting."
            showDashboard(view: .cleanup)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.suspendInteractiveWork()
        aiStorage.cancel()
        health.stop()
        activity.stop()
        AlertManager.shared.stop()
        menuBar?.shutdown()
    }

    private func configureAlerts() {
        AlertManager.shared.configure(health: health, activity: activity,
            enabled: Settings.shared.notificationsEnabled && health.isMonitoring
                && !CommandLine.arguments.contains("--app-smoke"))
    }

    /// Exercises the real native lifecycle without scanning or changing user files.
    private func runSmokeChecks() {
        Task { @MainActor in
            var checks: [String] = []
            func record(_ ok: Bool, _ label: String) {
                checks.append("\(ok ? "PASS" : "FAIL") \(label)")
            }
            record(menuBar?.isInstalled == true, "status item installed on launch")
            record(window == nil, "menu bar launch creates no dashboard hierarchy")
            try? await Task.sleep(nanoseconds: 350_000_000)
            menuBar?.showPopover()
            try? await Task.sleep(nanoseconds: 250_000_000)
            record(menuBar?.isPopoverShown == true, "quick actions popover opens from status item")
            if menuBar?.isPopoverShown != true { print(menuBar?.presentationDiagnostic ?? "Menu controller missing") }
            menuBar?.closePopover()
            for _ in 0..<20 where menuBar?.isPopoverShown == true {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            record(menuBar?.isPopoverShown == false, "quick actions popover closes and cancels response checks")
            showDashboard(view: .health)
            try? await Task.sleep(nanoseconds: 400_000_000)
            record(window?.isVisible == true, "dashboard opens from menu action")
            window?.miniaturize(nil)
            try? await Task.sleep(nanoseconds: 450_000_000)
            record(!store.dashboardActive, "minimizing suspends detailed sampling")
            window?.deminiaturize(nil)
            try? await Task.sleep(nanoseconds: 450_000_000)
            record(store.dashboardActive, "restoring resumes visible dashboard sampling")
            window?.performClose(nil)
            record(window == nil, "closing dashboard releases view hierarchy")
            record(menuBar?.isInstalled == true, "status item survives dashboard close")
            record(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "closing window does not quit")
            showDashboard(view: .aiStorage)
            try? await Task.sleep(nanoseconds: 300_000_000)
            record(window?.isVisible == true && store.view == .aiStorage, "dashboard reopens at AI Storage")
            showDashboard(view: .cleanup)
            try? await Task.sleep(nanoseconds: 300_000_000)
            for view in [ViewKind.activity, .resources, .projects, .advanced] {
                showDashboard(view: view)
                try? await Task.sleep(nanoseconds: 250_000_000)
                record(window?.isVisible == true && store.view == view, "\(view.title) opens without a disk scan")
            }
            record(!store.progress.running && !store.analysing, "quick routes start no full disk scans")
            showSettings()
            try? await Task.sleep(nanoseconds: 200_000_000)
            record(settingsWindow?.isVisible == true, "settings opens as a native window")
            settingsWindow?.performClose(nil)
            if CommandLine.arguments.contains("--smoke-popup") {
                window?.performClose(nil)
                menuBar?.showPopover()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                menuBar?.closePopover()
            } else if CommandLine.arguments.contains("--smoke-hold") {
                showDashboard(view: .health)
                if CommandLine.arguments.contains("--smoke-dark") {
                    window?.appearance = NSAppearance(named: .darkAqua)
                } else {
                    window?.appearance = NSAppearance(named: .aqua)
                }
                // Optional bounded hold for inspecting the actual native controls.
                // Smoke mode still disables history writes and notification requests.
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
            window?.performClose(nil)
            for check in checks { print(check) }
            print("SMOKE \(checks.contains(where: { $0.hasPrefix("FAIL") }) ? "FAILED" : "PASSED")")
            fflush(stdout)
            if checks.contains(where: { $0.hasPrefix("FAIL") }) {
                health.stop()
                activity.stop()
                AlertManager.shared.stop()
                menuBar?.shutdown()
                exit(1)
            }
            NSApp.terminate(nil)
        }
    }

}
