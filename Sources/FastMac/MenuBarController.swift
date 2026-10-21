import AppKit
import Combine
import SwiftUI

// Kept as a headless performance probe for the existing shell checks.
// The live status item subscribes to the shared monitors and never starts a scan.
struct MenuBarTick {
    let diskFree: Int64
    let diskTotal: Int64
    let pressure: Double
    let level: MemorySample.Level
}

enum MenuBarStats {
    static func sample() -> MenuBarTick {
        let memory = MemoryProbe.sample()
        let disk = MemoryProbe.diskFree()
        return MenuBarTick(diskFree: disk.free, diskTotal: disk.total,
                           pressure: memory.pressure, level: memory.level)
    }
}

/// Semantic colors follow the menu bar's effective appearance, including a theme
/// change while FastMac is running. Status is communicated by the symbol and words.
enum MenuBarPresentation {
    static func attributedTitle(_ title: String, highlighted: Bool = false) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ])
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return String(format: "%.0f%%", value)
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0,
              value < Double(Int64.max) / 2 else { return "Unavailable" }
        return "\(fmt(Int64(value))) /s"
    }

    static func compactTitle(metric: String, snapshot: ActivitySnapshot?,
                             health: HealthSample?, paused: Bool, shortStatus: String) -> String {
        if paused { return "Paused" }
        switch metric {
        case "cpu":
            guard let cpu = snapshot?.cpuPercent else { return "CPU —" }
            return "CPU \(percent(cpu))"
        case "memory":
            guard let used = snapshot?.memoryUsed else { return "RAM —" }
            return "RAM \(fmt(used))"
        case "network":
            guard let down = snapshot?.networkDownloadRate else { return "↓ —" }
            return "↓ \(rate(down))"
        case "storage":
            guard let free = snapshot?.diskFree ?? health?.diskFree,
                  (snapshot?.diskTotal ?? health?.diskTotal ?? 0) > 0 else { return "Free —" }
            return "\(fmt(free)) free"
        default:
            return shortStatus
        }
    }
}

@MainActor
final class HealthMenuHeader: NSView {
    let status = NSTextField(labelWithString: "Reading Mac health…")
    let cpu = NSTextField(labelWithString: "CPU: awaiting a reading")
    let memory = NSTextField(labelWithString: "Memory: awaiting a reading")
    let network = NSTextField(labelWithString: "Network: awaiting a reading")
    let storage = NSTextField(labelWithString: "Storage: awaiting a reading")
    let cadence = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 146))
        let labels = [status, cpu, memory, network, storage, cadence]
        for (index, label) in labels.enumerated() {
            label.font = .systemFont(ofSize: index == 0 ? 14 : 11,
                                     weight: index == 0 ? .semibold : .regular)
            // Do not let a health severity tint override menu foreground contrast.
            label.textColor = index == 0 ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 16, y: 116 - index * 21, width: 328, height: 19)
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let enabledKey = "FastMac.MenuBarEnabled"
    static let summaryKey = "FastMac.MenuBarSummaryEnabled"
    static let metricKey = "FastMac.MenuBarMetric"
    static let pollInterval: TimeInterval = 15

    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var defaultsObserver: NSObjectProtocol?
    private let health: HealthMonitor
    private let store: AppStore
    private let activity: ActivityMonitor
    private let header = HealthMenuHeader()
    private var pauseItem: NSMenuItem?
    private var queueItem: NSMenuItem?
    private let quickActions = QuickActionsModel()
    private let quickPanel = QuickActionsPanelHost()
    private var presentationGeneration: UInt = 0
    private var contextMenu: NSMenu?
    var isPopoverShown: Bool { quickPanel.isShown }
    var presentationDiagnostic: String {
        quickPanel.diagnostic + "; status visible=\(statusItem?.isVisible ?? false), anchor window visible=\(statusItem?.button?.window?.isVisible ?? false), anchor=\(String(describing: statusItem?.button?.frame))"
    }
    private let onNavigate: (ViewKind) -> Void
    private let onScanHome: () -> Void
    private let onSettings: () -> Void
    private let onUnavailable: () -> Void

    var isInstalled: Bool { statusItem != nil }
    var lastTickCost: TimeInterval { health.lastProbeMilliseconds / 1000 }

    init(health: HealthMonitor, store: AppStore, activity: ActivityMonitor? = nil,
         onNavigate: @escaping (ViewKind) -> Void,
         onScanHome: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onUnavailable: @escaping () -> Void) {
        self.health = health
        self.store = store
        self.activity = activity ?? ActivityMonitor(allowsPersistence: false)
        self.onNavigate = onNavigate
        self.onScanHome = onScanHome
        self.onSettings = onSettings
        self.onUnavailable = onUnavailable
        super.init()
        quickPanel.onDismiss = { [weak self] in
            guard let self else { return }
            self.presentationGeneration &+= 1
            self.quickActions.cancelChecks()
        }
        health.$sample.sink { [weak self] _ in
            // @Published emits before the new value is installed.
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        health.$isMonitoring.sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        do {
            self.activity.$latest.sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }.store(in: &subscriptions)
            self.activity.$isMonitoring.sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }.store(in: &subscriptions)
        }
        store.$staged.sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyDefaults() } }
        applyDefaults()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func applyDefaults() {
        setEnabled(UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
        update()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, statusItem == nil { install() }
        if !enabled, statusItem != nil {
            shutdown()
            onUnavailable()
        }
    }

    func shutdown() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        closePopover()
        contextMenu = nil
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let info = NSMenuItem()
        info.view = header
        menu.addItem(info)
        menu.addItem(.separator())
        addRoute("Open Mac Health", .health, to: menu)
        addRoute("Review AI Model Storage…", .aiStorage, to: menu)
        addRoute("Find Cache Cleanup…", .quick, to: menu)
        addRoute("Inspect Running Apps…", .performance, to: menu)
        addRoute("Review Startup Items…", .startup, to: menu)
        queueItem = addRoute("Review Cleanup Queue", .cleanup, to: menu)
        menu.addItem(makeItem("Scan Entire Mac…", #selector(scanMac)))
        menu.addItem(makeItem("Scan Home Folder…", #selector(scanHome)))
        menu.addItem(.separator())
        pauseItem = makeItem("Pause Monitoring", #selector(toggleMonitoring))
        menu.addItem(pauseItem!)
        menu.addItem(makeItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit FastMac", #selector(quit), key: "q"))
        contextMenu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        update()
    }

    @discardableResult
    private func addRoute(_ title: String, _ view: ViewKind, to menu: NSMenu) -> NSMenuItem {
        let item = makeItem(title, #selector(navigate(_:)))
        item.representedObject = view.rawValue
        menu.addItem(item)
        return item
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        if health.isMonitoring { health.refresh() }
        update()
    }

    private func update() {
        let showSummary = UserDefaults.standard.object(forKey: Self.summaryKey) as? Bool ?? true
        let paused = !health.isMonitoring
        let sample = health.sample
        let latest = activity.latest
        let status = sample?.status ?? .unknown
        let title = paused ? "Monitoring paused" : sample?.statusTitle ?? "Reading Mac health…"
        let symbol: String
        switch status {
        case .comfortable: symbol = "checkmark.circle"
        case .attention: symbol = "exclamationmark.circle"
        case .critical: symbol = "exclamationmark.triangle"
        case .unknown: symbol = "circle.dotted"
        }
        let button = statusItem?.button
        let image = NSImage(systemSymbolName: paused ? "pause.circle" : symbol,
                            accessibilityDescription: "FastMac: \(title)")
        image?.isTemplate = true
        button?.image = image
        // Let AppKit draw the template symbol with the menu bar foreground. A fixed
        // tint applies to the button's title too and can be unreadable on a dark bar.
        button?.contentTintColor = nil
        let shortStatus: String
        switch status {
        case .comfortable: shortStatus = "OK"
        case .attention: shortStatus = "Check"
        case .critical: shortStatus = "Action"
        case .unknown: shortStatus = "Limited"
        }
        let metric = UserDefaults.standard.string(forKey: Self.metricKey) ?? "status"
        let compact = MenuBarPresentation.compactTitle(metric: metric, snapshot: latest,
                                                       health: sample, paused: paused,
                                                       shortStatus: shortStatus)
        button?.attributedTitle = MenuBarPresentation.attributedTitle(showSummary ? " " + compact : "")
        button?.attributedAlternateTitle = MenuBarPresentation.attributedTitle(
            showSummary ? " " + compact : "", highlighted: true)
        button?.setAccessibilityLabel("FastMac: \(title). \(compact)")
        header.status.stringValue = title
        header.cpu.stringValue = "CPU: \(MenuBarPresentation.percent(latest?.cpuPercent)) · system total"
        let used = latest?.memoryUsed
        let total = latest?.memoryTotal
        if let used, let total, total > 0 {
            header.memory.stringValue = "Memory: \(fmt(used)) of \(fmt(total)) · \(sample?.memoryPressure.title ?? "Unavailable") pressure"
        } else if let sample {
            let swap = sample.swapAvailable ? fmt(sample.memory.swapUsed) : "unavailable"
            header.memory.stringValue = "Memory: \(sample.memoryPressure.title) pressure · Swap: \(swap)"
        } else {
            header.memory.stringValue = "Memory: awaiting a reading"
        }
        if let down = latest?.networkDownloadRate, let up = latest?.networkUploadRate {
            header.network.stringValue = "Network: ↓ \(MenuBarPresentation.rate(down))  ↑ \(MenuBarPresentation.rate(up))"
        } else {
            header.network.stringValue = "Network: awaiting rate samples"
        }
        if let free = latest?.diskFree ?? sample?.diskFree,
           let total = latest?.diskTotal ?? sample?.diskTotal, total > 0 {
            header.storage.stringValue = "Storage: \(fmt(free)) free of \(fmt(total))"
        } else {
            header.storage.stringValue = "Storage: unavailable"
        }
        let readingDate = latest?.sampledAt ?? sample?.sampledAt
        header.cadence.stringValue = paused ? "Paused · last reading retained"
            : readingDate.map { "Updated \($0.formatted(date: .omitted, time: .standard)) · scans stay manual" }
                ?? "Reading activity · scans stay manual"
        if let sample {
            button?.toolTip = "\(title)\n\(sample.statusDetail)\n\(header.cpu.stringValue)\n\(header.memory.stringValue)\n\(header.network.stringValue)\n\(header.storage.stringValue)\n\(header.cadence.stringValue)"
        } else {
            button?.toolTip = "\(title)\n\(header.cadence.stringValue)"
        }
        if quickPanel.isShown { quickActions.updateMetrics(snapshot: latest) }
        pauseItem?.title = paused ? "Resume Monitoring" : "Pause Monitoring"
        queueItem?.title = store.staged.isEmpty ? "Review Cleanup Queue"
            : "Review Cleanup Queue (\(store.staged.count) · \(fmt(store.stagedBytes)))"
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp, let contextMenu, let button = statusItem?.button {
            closePopover()
            statusItem?.menu = contextMenu
            button.performClick(nil)
            statusItem?.menu = nil
        } else if quickPanel.isShown {
            closePopover()
        } else {
            presentQuickActions(preferPointerScreen: true)
        }
    }

    /// Kept as the public entry point for the app menu and smoke checks. Unlike an
    /// anchored popover this also works when an auto-hidden status view is absent.
    func showPopover() { presentQuickActions(preferPointerScreen: false) }

    private func presentQuickActions(preferPointerScreen: Bool) {
        guard !quickPanel.isShown else { return }
        let pointer = NSEvent.mouseLocation
        let button = statusItem?.button
        let anchorWindow = button?.window
        let visibleAnchor: NSRect? = {
            guard let button, let anchorWindow, anchorWindow.isVisible,
                  !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty else { return nil }
            return anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }()
        let screens = NSScreen.screens
        guard let screenIndex = QuickActionsPanelPlacement.screenIndex(frames: screens.map(\.frame),
            anchor: visibleAnchor, pointer: pointer, preferPointer: preferPointerScreen) else { return }
        let screen = screens[screenIndex]
        let anchor: NSRect? = {
            if let visibleAnchor, visibleAnchor.intersects(screen.frame),
               !preferPointerScreen || visibleAnchor.insetBy(dx: -4, dy: -4).contains(pointer) {
                return visibleAnchor
            }
            if preferPointerScreen {
                let width = max(32, button?.bounds.width ?? 32)
                let height = NSStatusBar.system.thickness
                return NSRect(x: pointer.x - width / 2, y: screen.frame.maxY - height,
                              width: width, height: height)
            }
            return nil
        }()
        guard let frame = QuickActionsPanelPlacement.frame(visibleFrame: screen.visibleFrame,
                                                           anchor: anchor, pointer: pointer) else { return }
        // Expire old readings, but do no inventory/IO work until the first frame.
        quickActions.updateMetrics(snapshot: activity.latest)
        let view = QuickActionsPopover(health: health, activity: activity, model: quickActions,
            onNavigate: { [weak self] destination in
                self?.closePopover()
                self?.onNavigate(destination)
            }, onSettings: { [weak self] in
                self?.closePopover()
                self?.onSettings()
            }, onRefresh: { [weak self] in self?.refreshPopover() })
        let fitted = QuickActionsPanelContent(content: view, size: frame.size)
        quickPanel.present(controller: NSHostingController(rootView: fitted), frame: frame, anchor: anchor)
        presentationGeneration &+= 1
        let token = presentationGeneration
        // Permit cached content to paint before reading icons or enumerating apps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.presentationGeneration == token, self.quickPanel.isShown else { return }
            self.refreshPopover()
        }
    }

    func closePopover() {
        presentationGeneration &+= 1
        quickActions.cancelChecks()
        quickPanel.dismiss()
    }

    private func refreshPopover() {
        health.refresh()
        activity.refresh()
        quickActions.refresh(snapshot: activity.latest)
        update()
    }

    @objc private func navigate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let view = ViewKind(rawValue: raw) else { return }
        onNavigate(view)
    }
    @objc private func scanHome() { onScanHome() }
    @objc private func scanMac() {
        onNavigate(.folders)
        store.scanMac()
    }
    @objc private func openSettings() { onSettings() }
    @objc private func toggleMonitoring() {
        Settings.shared.healthMonitoringEnabled.toggle()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Very short displays scroll the entire popup rather than clipping its actions.
private struct QuickActionsPanelContent<Content: View>: View {
    let content: Content
    let size: NSSize
    var body: some View {
        Group {
            if size.height < 520 {
                ScrollView { content.frame(height: 520) }
            } else {
                content.frame(height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(VibrancyBackground(material: .popover, cornerRadius: DS.Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Palette.hairline))
    }
}
