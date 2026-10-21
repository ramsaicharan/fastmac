import SwiftUI

/// The application menu.
///
/// A SwiftUI `App` gets this for free. This app is built on an imperative `AppDelegate`
/// with a hand-made `NSWindow`, and that route gets *nothing* — no ⌘Q, no ⌘W, no ⌘,, no
/// Copy/Paste in text fields, no Minimise. The menu bar is not decoration on macOS; it is
/// where the standard key equivalents actually live.
enum AppMenu {

    static func install() {
        let main = NSMenu()

        main.addItem(appMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())

        NSApp.mainMenu = main
    }

    // MARK: FastMac

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "FastMac")

        menu.addItem(withTitle: "About FastMac",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let dashboard = menu.addItem(withTitle: "Open Dashboard",
                                     action: #selector(MenuActions.openDashboard),
                                     keyEquivalent: "0")
        dashboard.target = MenuActions.shared

        let quickActions = menu.addItem(withTitle: "Open Quick Actions",
                                        action: #selector(MenuActions.openQuickActions), keyEquivalent: "0")
        quickActions.keyEquivalentModifierMask = [.command, .shift]
        quickActions.target = MenuActions.shared

        let palette = menu.addItem(withTitle: "Search & Commands…", action: #selector(MenuActions.openCommandPalette), keyEquivalent: "k")
        palette.target = MenuActions.shared

        let settings = menu.addItem(withTitle: "Settings…",
                                    action: #selector(MenuActions.openSettings),
                                    keyEquivalent: ",")
        settings.target = MenuActions.shared

        let scanMac = menu.addItem(withTitle: "Scan Entire Mac",
                                   action: #selector(MenuActions.scanMac),
                                   keyEquivalent: "R")
        scanMac.keyEquivalentModifierMask = [.command, .shift]
        scanMac.target = MenuActions.shared

        let scan = menu.addItem(withTitle: "Scan Home Folder",
                                action: #selector(MenuActions.scanHome),
                                keyEquivalent: "r")
        scan.target = MenuActions.shared

        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide FastMac",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit FastMac",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Termination belongs to the application even when a custom control is
        // first responder. Native NSMenuItem titles retain AppKit's theme colors.
        quit.target = NSApp

        item.submenu = menu
        return item
    }

    // MARK: Edit — needed for text fields and the path/command copy buttons to behave

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    // MARK: View

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        // Number keys jump between sections, matching the sidebar order.
        for (i, kind) in MenuActions.quickJump.enumerated() {
            let m = menu.addItem(withTitle: kind.title,
                                 action: #selector(MenuActions.jumpToView(_:)),
                                 keyEquivalent: "\(i + 1)")
            m.target = MenuActions.shared
            m.representedObject = kind.rawValue
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen",
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        item.submenu = menu
        return item
    }

    // MARK: Window

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimise",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let bring = menu.addItem(withTitle: "Bring All to Front",
                                 action: #selector(MenuActions.bringToFront), keyEquivalent: "")
        bring.target = MenuActions.shared
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: Help

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        let fda = menu.addItem(withTitle: "Grant Full Disk Access…",
                               action: #selector(MenuActions.openFullDiskAccess), keyEquivalent: "")
        fda.target = MenuActions.shared
        let log = menu.addItem(withTitle: "Reveal Cleanup Log",
                               action: #selector(MenuActions.revealLog), keyEquivalent: "")
        log.target = MenuActions.shared
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}

/// Menu targets. `AppDelegate` points this at the live store on launch.
final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var store: AppStore?
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenQuickActions: (() -> Void)?

    static let quickJump: [ViewKind] = [
        .health, .aiStorage, .quick, .cleanup, .memory, .performance, .startup, .folders, .apps,
    ]

    @MainActor @objc func scanHome() {
        openDashboard()
        store?.scan(path: NSHomeDirectory())
    }

    @MainActor @objc func scanMac() {
        openDashboard()
        store?.view = .folders
        store?.scanMac()
    }

    @MainActor @objc func jumpToView(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ViewKind(rawValue: raw) else { return }
        openDashboard()
        store?.view = kind
        store?.ensureStandaloneAnalysis(for: kind)
    }

    @MainActor @objc func openDashboard() { onOpenDashboard?() }
    @MainActor @objc func openCommandPalette() { openDashboard(); store?.showingCommandPalette = true }
    @MainActor @objc func openQuickActions() { onOpenQuickActions?() }
    @MainActor @objc func openSettings() {
        if let onOpenSettings { onOpenSettings() }
        else { SettingsWindowController.shared.show() }
    }
    @MainActor @objc func bringToFront() {
        openDashboard()
        NSApp.arrangeInFront(nil)
    }
    @objc func openFullDiskAccess() { FullDiskAccess.openSettings() }
    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Audit.url])
    }
}
