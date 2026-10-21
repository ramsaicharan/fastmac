import AppKit

/// Geometry is independent of window-server state so negative-origin displays,
/// auto-hidden menu bars and small screens can be checked without UI automation.
enum QuickActionsPanelPlacement {
    static func frame(visibleFrame: NSRect, anchor: NSRect?, pointer: NSPoint,
                      preferredSize: NSSize = NSSize(width: 420, height: 640)) -> NSRect? {
        guard visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.minX.isFinite, visibleFrame.minY.isFinite,
              visibleFrame.width > 32, visibleFrame.height > 32 else { return nil }
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(preferredSize.width, safe.width)
        let height = min(preferredSize.height, safe.height)
        let centerX = anchor?.midX ?? (pointer.x.isFinite ? pointer.x : safe.midX)
        let requestedTop = anchor.map { $0.minY - 6 } ?? safe.maxY
        let x = min(safe.maxX - width, max(safe.minX, centerX - width / 2))
        let y = min(safe.maxY - height, max(safe.minY, requestedTop - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func screenIndex(frames: [NSRect], anchor: NSRect?, pointer: NSPoint,
                            preferPointer: Bool) -> Int? {
        let pointed = frames.firstIndex { $0.contains(pointer) }
        if preferPointer, let pointed { return pointed }
        if let anchor {
            let intersections = frames.map { frame -> CGFloat in
                let intersection = frame.intersection(anchor)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            if let largest = intersections.max(), largest > 0 {
                return intersections.firstIndex(of: largest)
            }
        }
        return pointed ?? (frames.isEmpty ? nil : 0)
    }
}

@MainActor
private final class QuickActionsFloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // These flags are set before the window is shown. The app's activation
        // policy and its ordinary dashboard windows are left alone.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true
        // isFloatingPanel changes the level, so set this afterward. A transient
        // status-item popup uses the status-bar level;
        // the dashboard keeps its ordinary window level.
        level = .statusBar
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isMovable = false
        title = "FastMac Quick Actions"
    }

    /// A SwiftUI confirmation's onExitCommand handles Escape first. This is the
    /// fallback when the panel's ordinary content is the first responder.
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// A short-lived nonactivating panel avoids an NSPopover's invisible status-item
/// anchor failure. Mouse monitors need no Accessibility or screen-recording access.
/// Only mouse-down events are observed; keyboard input is handled by our own panel.
@MainActor
final class QuickActionsPanelHost: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    var onDismiss: (() -> Void)?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var spaceObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    private var menuDepth = 0
    private var anchorFrame: NSRect?
    private var generation: UInt = 0
    private var lastDismissReason = "not presented"
    private var needsInitialKeyFocus = false

    var isShown: Bool { window?.isVisible == true }
    var monitorCount: Int {
        [localMouse != nil, globalMouse != nil, spaceObserver != nil, screensObserver != nil,
         menuBeginObserver != nil, menuEndObserver != nil].filter { $0 }.count
    }
    var diagnostic: String {
        guard let window else { return "Quick Actions panel absent; monitors=\(monitorCount); lastDismiss=\(lastDismissReason)" }
        return "Quick Actions visible=\(window.isVisible), occlusionVisible=\(window.occlusionState.contains(.visible)), key=\(window.isKeyWindow), activeSpace=\(window.isOnActiveSpace), frame=\(window.frame), level=\(window.level.rawValue), collection=\(window.collectionBehavior.rawValue), nonactivating=\(window.styleMask.contains(.nonactivatingPanel)), appPolicy=\(NSApp.activationPolicy().rawValue), appActive=\(NSApp.isActive), monitors=\(monitorCount)"
    }

    func present(controller: NSViewController, frame: NSRect, anchor: NSRect?) {
        dismiss()
        generation &+= 1
        anchorFrame = anchor
        let panel = QuickActionsFloatingPanel()
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.dismiss(reason: "Escape") }
        panel.contentViewController = controller
        panel.setFrame(frame, display: false)
        window = panel
        needsInitialKeyFocus = true
        installMonitors()
        // Establish visibility before requesting keyboard focus. Ordering and
        // focusing a nonactivating panel separately avoids activating a dashboard
        // window on another Space, while retaining ordinary Escape handling.
        panel.orderFrontRegardless()
        scheduleInitialKeyFocus()
    }

    func dismiss(reason: String = "requested") {
        guard let panel = window else { removeMonitors(); return }
        lastDismissReason = reason
        generation &+= 1
        window = nil
        needsInitialKeyFocus = false
        removeMonitors()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        panel.contentViewController = nil
        anchorFrame = nil
        onDismiss?()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        lastDismissReason = "window closed"
        generation &+= 1
        window = nil
        needsInitialKeyFocus = false
        removeMonitors()
        anchorFrame = nil
        onDismiss?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        scheduleInitialKeyFocus()
    }

    private func scheduleInitialKeyFocus() {
        guard needsInitialKeyFocus, let panel = window else { return }
        let token = generation
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.generation == token,
                  self.window === panel, self.needsInitialKeyFocus,
                  panel.isVisible, panel.isOnActiveSpace,
                  panel.occlusionState.contains(.visible) else { return }
            self.needsInitialKeyFocus = false
            panel.makeKey()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.menuDepth == 0,
                  self.window?.isKeyWindow == false else { return }
            self.dismiss(reason: "lost keyboard focus")
        }
    }

    private func clickedOutside(at point: NSPoint) {
        guard let panel = window, panel.isVisible, menuDepth == 0,
              !panel.frame.contains(point), anchorFrame?.contains(point) != true else { return }
        dismiss(reason: "outside click")
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self?.clickedOutside(at: point)
            }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside(at: NSEvent.mouseLocation) }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss(reason: "Space changed") } }
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss(reason: "display configuration changed") } }
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.menuDepth += 1 } }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.menuDepth = max(0, (self?.menuDepth ?? 0) - 1) } }
    }

    private func removeMonitors() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        localMouse = nil
        globalMouse = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        if let menuBeginObserver { NotificationCenter.default.removeObserver(menuBeginObserver) }
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        spaceObserver = nil
        screensObserver = nil
        menuBeginObserver = nil
        menuEndObserver = nil
        menuDepth = 0
    }

    deinit {
        // The owner normally dismisses before releasing us. Observer removal also
        // remains safe during process teardown without touching any user apps.
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        for observer in [screensObserver, menuBeginObserver, menuEndObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
