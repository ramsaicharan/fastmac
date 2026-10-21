import SwiftUI

// `swift run FastMac --bench <path>` measures the scanner without opening a window.
let args = CommandLine.arguments
if args.count >= 2, args[1] == "--diagnose-apps" {
    do { try PerformanceDiagnostic.run(seconds: args.count > 2 ? Int(args[2]) ?? 60 : 60) }
    catch { fputs("Diagnosis failed: \(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if args.count >= 2, args[1] == "--bench" {
    let target = args.count >= 3 ? args[2] : NSHomeDirectory()
    let p = ScanProgress()
    let s = Scanner(progress: p)
    let t0 = Date()
    let r = s.scan(root: target)
    let wall = Date().timeIntervalSince(t0)
    print("""
      root      \(r.root.path)
      bytes     \(fmt(r.bytes))
      files     \(fmtCount(r.files))
      dirs      \(fmtCount(r.dirs))
      errors    \(fmtCount(r.errors))
      elapsed   \(String(format: "%.2f", wall))s  (\(fmtCount(Int(Double(r.files)/wall)))/s)
      big(50MB+) \(fmtCount(r.bigFiles.count))
      dup groups \(fmtCount(r.bySize.count))
      top:
    """)
    for c in r.root.children.prefix(8) {
        print("        \(fmt(c.size).padding(toLength: 10, withPad: " ", startingAt: 0))\(c.name)")
    }
    if let disk = DiskOverviewProbe.read() {
        print("      disk \(disk.name): \(fmt(disk.used)) used of \(fmt(disk.capacity)); purgeable \(fmt(disk.purgeable))")
        for s in disk.segments(scannedPath: r.root.path, scannedBytes: r.bytes) {
            print("        \(fmt(s.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))\(s.kind.rawValue)")
        }
    }
    exit(0)
}

if args.count >= 2, args[1] == "--mem" {
    let m = MemoryProbe.sample()
    print("""
      total       \(fmt(m.total))
      app         \(fmt(m.app))
      wired       \(fmt(m.wired))
      compressor  \(fmt(m.compressor))  holds \(fmt(m.stored))  (\(String(format: "%.1f", m.ratio))x)
      free        \(fmt(m.free))
      swap        \(fmt(m.swapUsed)) of \(fmt(m.swapTotal))
      RAM estimate \(String(format: "%.0f", m.estimatedLoadPercent))%  — \(m.verdict)
      top:
    """)
    for p in MemoryProbe.processes(limit: 6) {
        print("        \(fmt(p.rss).padding(toLength: 10, withPad: " ", startingAt: 0))\(p.count) proc  \(p.name)")
    }
    exit(0)
}

if args.count >= 2, args[1] == "--e2e" {
    E2E.run(args.count >= 3 ? args[2] : nil)
    exit(0)
}

if args.count >= 2, args[1] == "--selftest" {
    SelfTest.run()
    exit(0)
}

// Headless entry points for the feature areas. Each prints PASS/FAIL lines and exits
// non-zero on failure, so the whole app stays verifiable without opening a window.
func runChecks(_ title: String, _ lines: [String]) -> Never {
    print("\n\(title)")
    for l in lines { print("  " + l) }
    let failed = lines.filter { $0.hasPrefix("FAIL") }.count
    print(failed == 0 ? "\nALL PASS (\(lines.count) checks)\n" : "\n\(failed) FAILED\n")
    exit(failed == 0 ? 0 : 1)
}

if args.count >= 2, args[1] == "--render-check" {
    _ = NSApplication.shared
    runChecks("RENDERING", MainActor.assumeIsolated { RenderCheck.run() })
}
if args.count >= 2, args[1] == "--health-render-check" {
    _ = NSApplication.shared
    let output = args.count >= 3 ? args[2] : ".verification/rendered"
    runChecks("HEALTH APP RENDERING", MainActor.assumeIsolated {
        HealthRenderCheck.run(outputDirectory: output)
    })
}
if args.count >= 2, args[1] == "--quick-actions-check" {
    runChecks("QUICK ACTIONS", QuickActionsSelfCheck.run())
}
if args.count >= 2, args[1] == "--layout-check" {
    runChecks("BOUNDED LAYOUT", LayoutSelfCheck.run())
}
if args.count >= 2, args[1] == "--navigation-check" {
    _ = NSApplication.shared
    exit(Int32(MainActor.assumeIsolated { NavigationSelfCheck.run() }))
}
if args.count >= 2, args[1] == "--quick-panel-check" {
    runChecks("QUICK ACTIONS PLACEMENT", QuickActionsPanelSelfCheck.run())
}
if args.count >= 3, args[1] == "--quick-panel-native-check" {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        runChecks("QUICK ACTIONS FULL SCREEN", await QuickActionsPanelSelfCheck.runNative(
            fixtureExecutable: URL(fileURLWithPath: args[2])))
    }
    application.run()
}
if args.count >= 2, args[1] == "--quick-actions-render-check" {
    _ = NSApplication.shared
    let output = args.count >= 3 ? args[2] : ".verification/quick-actions"
    runChecks("QUICK ACTIONS RENDERING", MainActor.assumeIsolated { QuickActionsRenderCheck.run(outputDirectory: output) })
}
if args.count >= 2, args[1] == "--menu-check" {
    _ = NSApplication.shared
    let output = args.count >= 3 ? args[2] : ".verification/menu"
    runChecks("MENU APPEARANCE", MainActor.assumeIsolated { MenuBarSelfCheck.run(outputDirectory: output) })
}
// Retina renders of fixture data for docs/screenshots. No personal data is read.
if args.count >= 3, args[1] == "--readme-screenshots" {
    _ = NSApplication.shared
    runChecks("README SCREENSHOTS", MainActor.assumeIsolated {
        QuickActionsRenderCheck.run(outputDirectory: args[2], scale: 2)
            + FeatureRenderCheck.run(outputDirectory: args[2], scale: 2)
    })
}
if args.count >= 2, args[1] == "--feature-render-check" {
    _ = NSApplication.shared
    let output = args.count >= 3 ? args[2] : ".verification/features"
    runChecks("NEW FEATURE RENDERING", MainActor.assumeIsolated { FeatureRenderCheck.run(outputDirectory: output) })
}
if args.count >= 2, args[1] == "--priv-check"    { runChecks("PRIVILEGED ACTIONS", PrivilegedSelfCheck.run()) }
if args.count >= 2, args[1] == "--risk-check"    { runChecks("RISK VOCABULARY", RiskSelfCheck.run()) }
if args.count >= 2, args[1] == "--helpers-check" { runChecks("HELPERS AND HISTORY PROTECTION", AppHelpersSelfCheck.run()) }
if args.count >= 2, args[1] == "--startup-check" { runChecks("STARTUP", StartupSelfCheck.run()) }
if args.count >= 2, args[1] == "--perf-check"    { runChecks("PERFORMANCE", PerfSelfCheck.run()) }
if args.count >= 2, args[1] == "--category-check" { runChecks("CATEGORIES", CategorySelfCheck.run()) }
if args.count >= 2, args[1] == "--maint-check"   { runChecks("MAINTENANCE", MaintSelfCheck.run()) }
if args.count >= 2, args[1] == "--shell-check"   { runChecks("APP SHELL", ShellSelfCheck.run()) }
if args.count >= 2, args[1] == "--health-check"  { runChecks("MAC HEALTH", HealthSelfCheck.run()) }
if args.count >= 2, args[1] == "--ai-storage-check" { runChecks("AI STORAGE", AIStorageSelfCheck.run()) }
if args.count >= 2, args[1] == "--process-action-check" { runChecks("PROCESS ACTIONS", ProcessActionSelfCheck.run()) }
if args.count >= 2, args[1] == "--history-check" { runChecks("SCAN HISTORY", HistorySelfCheck.run()) }
if args.count >= 2, args[1] == "--activity-check" { runChecks("ACTIVITY HISTORY", ActivityHistorySelfCheck.run()) }
if args.count >= 2, args[1] == "--activity-trends-check" { runChecks("ACTIVITY TRENDS", ActivityTrendsSelfCheck.run()) }
if args.count >= 2, args[1] == "--activity-alert-check" { runChecks("ACTIVITY ALERTS", ActivityAlertSelfCheck.run()) }
if args.count >= 2, args[1] == "--resource-check" { runChecks("RESOURCES", ResourceSelfCheck.run()) }
if args.count >= 2, args[1] == "--advanced-check" { runChecks("ADVANCED TOOLS", AdvancedResourcesSelfCheck.run()) }
if args.count >= 2, args[1] == "--activity-export-check" { runChecks("ACTIVITY EXPORT", ActivityExportSelfCheck.run()) }
if args.count >= 2, args[1] == "--activity-monitor-check" {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in runChecks("ACTIVITY MONITOR", await ActivityMonitorSelfCheck.run()) }
    // The production Timer needs the native run loop, not dispatchMain alone.
    application.run()
}

if args.count >= 2, args[1] == "--disk-overview-check" { runChecks("DISK OVERVIEW", DiskOverviewSelfCheck.run()) }
if args.count >= 2, args[1] == "--insights-check" { runChecks("INSIGHTS", InsightsSelfCheck.run()) }
if args.count >= 2, args[1] == "--insights-async-check" {
    Task { runChecks("INSIGHTS ASYNC", await InsightsSelfCheck.asyncChecks()) }
    dispatchMain()
}
if args.count >= 2, args[1] == "--agent-observation-check" {
    let sample = AgentObservationProbe.capture()
    print("Observed \(sample.processes.count) readable processes in \(sample.milliseconds) ms; limited=\(sample.limited). No session tracking or actions executed.")
    exit(0)
}

if args.count >= 2, args[1] == "--checkall" {
    var all: [String] = []
    all += InsightsSelfCheck.run()
    all += DiskOverviewSelfCheck.run()
    all += StartupSelfCheck.run()
    all += PerfSelfCheck.run()
    all += CategorySelfCheck.run()
    all += MaintSelfCheck.run()
    all += ShellSelfCheck.run()
    all += HealthSelfCheck.run()
    all += AIStorageSelfCheck.run()
    all += AppHelpersSelfCheck.run()
    all += RiskSelfCheck.run()
    all += PrivilegedSelfCheck.run()
    all += ProcessActionSelfCheck.run()
    all += QuickActionsSelfCheck.run()
    all += LayoutSelfCheck.run()
    all += QuickActionsPanelSelfCheck.run()
    all += HistorySelfCheck.run()
    all += ActivityHistorySelfCheck.run()
    all += ActivityTrendsSelfCheck.run()
    all += ActivityAlertSelfCheck.run()
    all += ResourceSelfCheck.run()
    all += AdvancedResourcesSelfCheck.run()
    all += ActivityExportSelfCheck.run()
    runChecks("ALL FEATURE CHECKS", all)
}

// Live performance snapshot. Two sweeps, because CPU% is a delta and one reading has
// nothing to subtract from.
if args.count >= 2, args[1] == "--live" {
    let first = PerfProbe.sweep(previous: PerfProbe.CPUState())
    usleep(600_000)
    let r = PerfProbe.sweep(previous: first.newState)
    let s = r.system
    print("""
      cores         \(s.coreCount)
      load avg      \(String(format: "%.2f", s.loadAvg1)) / \(String(format: "%.2f", s.loadAvg5)) / \(String(format: "%.2f", s.loadAvg15))
      cpu busy      \(String(format: "%.1f", s.systemUserPercent + s.systemSystemPercent))% of the whole machine
      thermal       \(s.thermalLabel)
      sweep cost    \(String(format: "%.2f", r.sweepMs)) ms
      visibility    \(r.pidsReadable) of \(r.pidsListed) processes readable\(r.hiddenCount > 0 ? "; \(r.hiddenCount) belong to other users and need admin rights to inspect" : "")
    """)
    print("      top consumers (% of one core, your processes only):")
    for g in r.groups.prefix(8) {
        let pct = String(format: "%.1f", g.cpuPercent)
        print("        \(pct.padding(toLength: 6, withPad: " ", startingAt: 0))%  \(g.count) proc  \(fmt(g.rss).padding(toLength: 10, withPad: " ", startingAt: 0))\(g.name)")
    }
    for a in PerfProbe.advisories(groups: r.groups, system: r.system).prefix(5) { print("        - \(a)") }
    exit(0)
}

FastMacApp.launch()
