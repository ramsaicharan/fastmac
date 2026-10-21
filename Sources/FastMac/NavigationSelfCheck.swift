import AppKit
import SwiftUI

/// Hidden-window checks against the production ContentView and destinations.
/// All models are synthetic; scans, persistence, onboarding and app actions stay off.
@MainActor
enum NavigationSelfCheck {
    static func run() -> Int {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        let health = HealthMonitor(fixtureSample: nil, isMonitoring: false)
        let activity = ActivityMonitor(allowsPersistence: false)
        let aiStorage = AIStorageService(home: "/fixture")
        let cases: [(ViewKind, Int, Bool)] = [
            (.insights, 0, false), (.aiStorage, 0, false), (.projects, 0, false), (.admin, 0, false), (.startup, 0, true), (.startup, 0, false),
            (.startup, 2, false), (.startup, 10, false), (.startup, 30, false),
            (.startup, 80, false), (.apps, 4, false), (.apps, 0, false), (.apps, 0, true)
        ]
        for size in [NSSize(width: 900, height: 692), NSSize(width: 1160, height: 800)] {
            for dark in [false, true] {
                for (route, count, loading) in cases {
                    let store = AppStore(loadSavedQueue: false)
                    store.view = route
                    store.analysing = route == .apps && loading
                    if route == .apps {
                        store.apps = (0..<count).map { index in
                            AppFootprint(name: "Fixture app \(index)", path: "/fixture/App\(index).app",
                                bundleID: "test.fixture.\(index)", bundleSize: 104_857_600,
                                leftovers: [], leftoverSize: 0, isElectron: false, lastUsed: nil)
                        }
                    }
                    let startup = StartupService()
                    startup.isScanning = loading
                    startup.items = (0..<count).map { index in
                        StartupItem(label: "com.fixture.orphan\(index)",
                            domain: index.isMultiple(of: 2) ? .globalAgent : .userAgent,
                            plistPath: "/fixture/com.fixture.orphan\(index).plist", programPath: nil,
                            programArguments: [], runAtLoad: false, keepAlive: false, startInterval: nil,
                            watchesPaths: false, legacyDisabledKey: false, unreadable: false,
                            owner: "Fixture app \(index)")
                    }
                    let host = NSHostingView(rootView:
                        ContentView(health: health, aiStorage: aiStorage, activity: activity,
                            allowsOnboarding: false, startsAutomaticWork: false, startupService: startup)
                            .environmentObject(store)
                            .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    settle(host)
                    let label = "\(route.rawValue)/\(count)/\(loading ? "loading" : "ready")/\(Int(size.width))x\(Int(size.height))/\(dark ? "dark" : "light")"
                    print("FIXTURE: \(label)")
                    verifyBounds(host: host, label: label, check: check)
                    check(window.title == "FastMac — \(route.title)", "\(label): title \(window.title)")
                    if count > 0 && (route == .startup || route == .apps) {
                        let table = descendants(host).compactMap { $0 as? NSTableView }
                            .first { $0.numberOfRows == count && $0.numberOfColumns >= 5 }
                        check(table != nil, "\(label): populated native table is present")
                        if let table, let scroll = table.enclosingScrollView {
                            let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
                            print("  tableRows=\(table.numberOfRows), columns=\(table.numberOfColumns), viewport=\(viewport), tableWidth=\(table.bounds.width)")
                            check(viewport.height >= 120, "\(label): table retains usable height")
                            check(viewport.intersection(host.bounds).height >= viewport.height - 1,
                                  "\(label): table viewport stays on screen")
                            check(table.bounds.width <= scroll.contentSize.width + 2,
                                  "\(label): table columns fit the viewport")
                        }
                    }
                    check(!store.progress.running && !store.refreshing && !activity.isMonitoring && !health.isMonitoring,
                          "\(label): no scans or monitoring started")
                    check(startup.isScanning == loading, "\(label): startup auto-scan stayed suppressed")
                    check(store.staged.isEmpty, "\(label): no cleanup items staged")

                    // Reuse the same hosting/window tree: stale route titles and oversized
                    // split views must recover through ordinary state changes.
                    if route == .admin {
                        for destination in [ViewKind.maintenance, .startup, .health] {
                            store.view = destination
                            settle(host)
                            verifyBounds(host: host, label: "\(label) → \(destination.rawValue)", check: check)
                            check(window.title == "FastMac — \(destination.title)",
                                  "\(label) → \(destination.rawValue): route title updates")
                        }
                    }
                    window.contentView = nil
                    window.close()
                }
            }
        }
        print("Navigation checks: \(checks - failures.count)/\(checks) passed; \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }

    private static func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func verifyBounds(host: NSView, label: String, check: (Bool, String) -> Void) {
        guard let split = descendants(host).compactMap({ $0 as? NSSplitView }).first else {
            check(false, "\(label): navigation split view exists")
            return
        }
        let frame = host.convert(split.bounds, from: split)
        print("  split=\(frame), host=\(host.bounds)")
        check(frame.minY >= -1 && frame.maxY <= host.bounds.height + 1,
              "\(label): navigation remains within host height")
        check(frame.minX >= -1 && frame.maxX <= host.bounds.width + 1,
              "\(label): navigation remains within host width")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
