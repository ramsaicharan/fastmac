import AppKit
import Foundation

enum QuickActionsPanelSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ name: String, _ condition: Bool) { lines.append("\(condition ? "PASS" : "FAIL")  \(name)") }
        let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: 1330, y: 875, width: 60, height: 25)
        let frame = QuickActionsPanelPlacement.frame(visibleFrame: main, anchor: anchor, pointer: .zero)!
        check("quick panel keeps its standard size when space permits", frame.size == NSSize(width: 420, height: 640))
        check("quick panel clamps its right edge inside the display", frame.maxX <= main.maxX - 8)
        check("quick panel sits below its status-item anchor", frame.maxY <= anchor.minY - 6)
        let left = NSRect(x: -1920, y: -200, width: 1920, height: 1055)
        let leftFrame = QuickActionsPanelPlacement.frame(visibleFrame: left,
            anchor: NSRect(x: -90, y: 855, width: 60, height: 25), pointer: NSPoint(x: -60, y: 870))!
        check("negative-origin external displays keep all popup content onscreen", left.insetBy(dx: 8, dy: 8).contains(leftFrame))
        let above = NSRect(x: 200, y: 900, width: 1280, height: 775)
        let aboveFrame = QuickActionsPanelPlacement.frame(visibleFrame: above, anchor: nil, pointer: NSPoint(x: 1450, y: 1660))!
        check("vertically arranged displays use their own coordinate origin", above.insetBy(dx: 8, dy: 8).contains(aboveFrame))
        let short = NSRect(x: 0, y: 0, width: 800, height: 480)
        let shortFrame = QuickActionsPanelPlacement.frame(visibleFrame: short, anchor: nil, pointer: .zero)!
        check("short displays do not inherit the old 520-point minimum", shortFrame.height == 464)
        check("short-display frame remains entirely reachable", short.insetBy(dx: 8, dy: 8).contains(shortFrame))
        let narrow = NSRect(x: 0, y: 0, width: 390, height: 700)
        check("narrow display geometry clamps popup width", QuickActionsPanelPlacement.frame(visibleFrame: narrow,
            anchor: nil, pointer: .zero)!.width == 374)
        let absentAnchor = QuickActionsPanelPlacement.frame(visibleFrame: main, anchor: nil, pointer: NSPoint(x: 700, y: 850))!
        check("an auto-hidden or unavailable anchor still has a usable position", main.insetBy(dx: 8, dy: 8).contains(absentAnchor))
        check("invalid screen geometry is rejected", QuickActionsPanelPlacement.frame(visibleFrame: .zero,
            anchor: nil, pointer: .zero) == nil)
        let screens = [main, left, above]
        check("a status-item click selects the clicked external display", QuickActionsPanelPlacement.screenIndex(frames: screens,
            anchor: anchor, pointer: NSPoint(x: -200, y: 600), preferPointer: true) == 1)
        check("programmatic opening uses a valid visible anchor display", QuickActionsPanelPlacement.screenIndex(frames: screens,
            anchor: NSRect(x: -100, y: 800, width: 50, height: 20), pointer: NSPoint(x: 200, y: 600), preferPointer: false) == 1)
        check("programmatic opening falls back to the pointer display without an anchor", QuickActionsPanelPlacement.screenIndex(frames: screens,
            anchor: nil, pointer: NSPoint(x: 600, y: 1200), preferPointer: false) == 2)
        check("offscreen pointer with no anchor has a deterministic fallback", QuickActionsPanelPlacement.screenIndex(frames: screens,
            anchor: nil, pointer: NSPoint(x: 9000, y: 9000), preferPointer: true) == 0)
        check("no connected screens yields no presentation", QuickActionsPanelPlacement.screenIndex(frames: [],
            anchor: nil, pointer: .zero, preferPointer: true) == nil)
        return lines
    }

    /// Launches only our separate, blank fixture app. No Accessibility API,
    /// AppleScript, synthetic input, or existing user app is touched.
    @MainActor
    static func runNative(fixtureExecutable: URL) async -> [String] {
        var lines = run()
        func check(_ name: String, _ condition: Bool) { lines.append("\(condition ? "PASS" : "FAIL")  \(name)") }
        guard FileManager.default.isExecutableFile(atPath: fixtureExecutable.path) else {
            check("fullscreen fixture executable exists", false)
            return lines
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fastmac-panel-native-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { lines.append("FAIL  native fixture directory: \(error.localizedDescription)"); return lines }
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        for policy in [NSApplication.ActivationPolicy.accessory, .regular] {
            let label = policy == .accessory ? "accessory" : "regular"
            NSApp.setActivationPolicy(policy)
            let statusFile = directory.appendingPathComponent("\(label).json")
            let stopFile = directory.appendingPathComponent("\(label).stop")
            let process = Process()
            process.executableURL = fixtureExecutable
            process.arguments = ["--status", statusFile.path, "--stop", stopFile.path, "--duration", "16"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { lines.append("FAIL  \(label) fixture launch: \(error.localizedDescription)"); continue }
            func status() -> [String: Any]? {
                guard let data = try? Data(contentsOf: statusFile),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object
            }
            var ready = false
            var stableSamples = 0
            for _ in 0..<70 {
                let value = status()
                if value?["fullscreen"] as? Bool == true,
                   value?["fullscreenSettled"] as? Bool == true,
                   value?["onActiveSpace"] as? Bool == true,
                   value?["occlusionVisible"] as? Bool == true,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                    stableSamples += 1
                    if stableSamples >= 7 { ready = true; break }
                } else { stableSamples = 0 }
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            check("\(label): controlled fixture entered fullscreen and owns focus", ready)
            if !ready {
                let observed = status() ?? [:]
                lines.append("NOTE  \(label): stable visible fullscreen baseline unavailable; fixture=\(observed), frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            }
            if ready, let screen = NSScreen.main,
               let frame = QuickActionsPanelPlacement.frame(visibleFrame: screen.visibleFrame,
                                                            anchor: nil, pointer: NSEvent.mouseLocation) {
                let controller = NSViewController()
                controller.view = NSView(frame: NSRect(origin: .zero, size: frame.size))
                controller.view.wantsLayer = true
                controller.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                let title = NSTextField(labelWithString: "FastMac fullscreen panel test")
                title.frame = NSRect(x: 24, y: frame.height - 55, width: frame.width - 48, height: 30)
                title.font = .systemFont(ofSize: 18, weight: .semibold)
                controller.view.addSubview(title)
                let field = NSTextField(string: "")
                field.placeholderString = "Owned fixture keyboard focus"
                field.frame = NSRect(x: 24, y: frame.height - 110, width: frame.width - 48, height: 28)
                controller.view.addSubview(field)
                let host = QuickActionsPanelHost()
                host.present(controller: controller, frame: frame, anchor: nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let after = status()
                check("\(label): panel is visible on the active Space", host.isShown && host.window?.isOnActiveSpace == true)
                check("\(label): panel is not occluded behind fullscreen content", host.window?.occlusionState.contains(.visible) == true)
                check("\(label): fullscreen fixture remains frontmost", NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier)
                check("\(label): fixture stays fullscreen on its active Space", after?["fullscreen"] as? Bool == true
                    && after?["onActiveSpace"] as? Bool == true)
                check("\(label): transient popup uses the status-bar window level", host.window?.level == .statusBar)
                check("\(label): popup keeps its nonactivating style", host.window?.styleMask.contains(.nonactivatingPanel) == true)
                check("\(label): visible popup obtains initial keyboard focus", host.window?.isKeyWindow == true)
                let focused = host.window?.makeFirstResponder(field) == true
                try? await Task.sleep(nanoseconds: 200_000_000)
                check("\(label): owned text field accepts focus without activating FastMac", focused
                    && host.window?.isKeyWindow == true && field.currentEditor() != nil
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier)
                let afterFocus = status()
                check("\(label): focused popup remains visible over the same fullscreen Space", host.window?.occlusionState.contains(.visible) == true
                    && afterFocus?["fullscreen"] as? Bool == true && afterFocus?["onActiveSpace"] as? Bool == true)
                lines.append("NOTE  \(label): \(host.diagnostic)")
                host.window?.cancelOperation(nil)
                check("\(label): Escape responder closes the panel and removes monitors", !host.isShown && host.monitorCount == 0)
            }
            try? Data("stop".utf8).write(to: stopFile, options: .atomic)
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            if process.isRunning { process.terminate() } // Only the fixture we launched.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return lines
    }
}
