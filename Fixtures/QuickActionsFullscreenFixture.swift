import AppKit

/// Standalone fixture, deliberately outside the app's SwiftPM Sources directory.
/// Its only window contains synthetic content. It never requests permissions.
@main
@MainActor
final class QuickActionsFullscreenFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let began = Date()
    private var statusPath: String?
    private var stopPath: String?
    private var duration: TimeInterval = 20
    private var fullscreenEnteredAt: Date?

    static func main() {
        let app = NSApplication.shared
        let delegate = QuickActionsFullscreenFixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        statusPath = argument("--status")
        stopPath = argument("--stop")
        duration = min(120, max(5, argument("--duration").flatMap(Double.init) ?? 20))
        let created = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        created.title = "FastMac Fullscreen Test — synthetic content"
        created.collectionBehavior = [.primary, .fullScreenPrimary]
        created.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.23, alpha: 1)
        created.isReleasedWhenClosed = false
        created.delegate = self
        let label = NSTextField(labelWithString: "FastMac fullscreen fixture\nSynthetic content · no user apps or files")
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 60, y: 240, width: 780, height: 90)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        created.contentView?.addSubview(label)
        window = created
        created.center()
        created.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.window?.toggleFullScreen(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(began) > duration || stopPath.map({ FileManager.default.fileExists(atPath: $0) }) == true {
            NSApp.terminate(nil)
            return
        }
        guard let window, let statusPath else { return }
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "fullscreen": window.styleMask.contains(.fullScreen),
            "fullscreenSettled": fullscreenEnteredAt.map { Date().timeIntervalSince($0) >= 0.5 } ?? false,
            "onActiveSpace": window.isOnActiveSpace,
            "visible": window.isVisible,
            "occlusionVisible": window.occlusionState.contains(.visible),
            "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "updatedAt": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { fullscreenEnteredAt = Date() }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenEnteredAt = nil }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}
