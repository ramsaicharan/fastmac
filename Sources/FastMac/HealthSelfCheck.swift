import Foundation

enum HealthSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ pass: Bool, _ detail: String = "") {
            lines.append("\(pass ? "PASS" : "FAIL")  \(title)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let gb: Int64 = 1_073_741_824
        let memory = MemorySample(total: 16 * gb, app: 12 * gb, wired: 2 * gb,
                                  compressor: gb, free: gb, swapUsed: 4 * gb)
        let healthy = HealthSample(memory: memory, memoryPressure: .normal,
                                   diskFree: 200 * gb, diskTotal: 1000 * gb, thermalState: .nominal)
        check("comfortable status uses macOS pressure rather than RAM occupancy", healthy.status == .comfortable)
        check("existing swap does not claim active pressure", healthy.memoryStatus == .comfortable)
        check("normal kernel dispatch flag maps to normal", HealthMemoryPressure.fromKernelFlag(1) == .normal)
        check("warning kernel dispatch flag maps to warning", HealthMemoryPressure.fromKernelFlag(2) == .warning)
        check("critical kernel dispatch flag maps to critical", HealthMemoryPressure.fromKernelFlag(4) == .critical)
        check("unknown flags stay unavailable", HealthMemoryPressure.fromKernelFlag(0) == .unknown
              && HealthMemoryPressure.fromKernelFlag(7) == .unknown)

        var pressured = healthy
        pressured.memoryPressure = .critical
        check("critical OS pressure raises health status", pressured.status == .critical)
        let pressureActions = HealthRecommendations.make(sample: pressured)
        check("critical pressure recommends memory inspection",
              pressureActions.contains { $0.id == "memory-pressure" && $0.destination == .memory })
        var warning = healthy
        warning.memoryPressure = .warning
        check("warning OS pressure recommends review", warning.status == .attention)

        var disk = healthy
        disk.diskFree = 4 * gb
        check("under 5 GB is urgent storage headroom", disk.storageStatus == .critical)
        disk.diskFree = 19 * gb; disk.diskTotal = 100 * gb
        check("absolute storage headroom threshold triggers", disk.storageStatus == .attention)
        disk.diskFree = 80 * gb; disk.diskTotal = 1000 * gb
        check("relative storage headroom threshold triggers", disk.storageStatus == .attention)
        disk.diskFree = 200 * gb; disk.diskTotal = 0
        check("failed volume reading stays unknown", disk.storageStatus == .unknown && disk.status == .unknown)

        var hot = healthy
        hot.thermalState = .serious
        check("serious thermal state recommends performance inspection",
              hot.status == .attention && HealthRecommendations.make(sample: hot).contains {
                  $0.id == "thermal" && $0.destination == .performance
              })
        hot.thermalState = .critical
        check("critical thermal state raises status", hot.status == .critical)

        var unavailable = healthy
        unavailable.memoryPressure = .unknown
        check("unavailable pressure never reports a fully comfortable Mac", unavailable.status == .unknown)
        check("unavailable pressure does not fabricate a memory problem",
              !HealthRecommendations.make(sample: unavailable).contains { $0.id == "memory-pressure" })
        unavailable.memoryAvailable = false
        unavailable.memoryPressure = .normal
        check("failed VM counters remain unknown despite a pressure signal", unavailable.memoryStatus == .unknown)
        unavailable.memoryPressure = .critical
        check("actual critical pressure wins over a failed VM counter read", unavailable.status == .critical)

        let inspections = HealthRecommendations.make(sample: nil)
        check("AI storage inspection available before any scan", inspections.contains { $0.destination == .aiStorage })
        check("startup and cache inspections available before any scan",
              inspections.contains { $0.destination == .startup } && inspections.contains { $0.destination == .categories })
        check("generic inspections do not claim a measured problem", inspections.allSatisfy { $0.urgency == .comfortable })
        let queued = HealthRecommendations.make(sample: healthy, stagedCount: 3)
        check("queued cleanup links to the review screen", queued.contains { $0.id == "cleanup-queue" && $0.destination == .cleanup })
        check("recommendations have unique identifiers", Set(queued.map(\.id)).count == queued.count)
        check("monitor interval leaves idle headroom", HealthMonitor.interval == 15 && HealthMonitor.tolerance >= 3)

        // A single fixed-cost live sample exercises actual OS counters; unavailable
        // pressure is a supported outcome in sandboxes and on restricted versions.
        let before = ProcessInfo.processInfo.systemUptime
        let live = HealthProbe.sample()
        let milliseconds = (ProcessInfo.processInfo.systemUptime - before) * 1000
        check("cheap probe returns a recent timestamp", abs(live.sampledAt.timeIntervalSinceNow) < 5)
        check("cheap probe uses nonnegative memory and disk counters",
              live.memory.total >= 0 && live.memory.swapUsed >= 0 && live.diskFree >= 0 && live.diskTotal >= 0)
        check("cheap probe finishes within a generous idle budget", milliseconds < 200,
              String(format: "%.2f ms", milliseconds))
        lines.append(contentsOf: MainActor.assumeIsolated { monitorChecks() })
        return lines
    }

    @MainActor
    private static func monitorChecks() -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ pass: Bool) { lines.append("\(pass ? "PASS" : "FAIL")  \(title)") }
        let monitor = HealthMonitor()
        check("constructing monitor performs no probe", monitor.sample == nil && !monitor.isMonitoring)
        monitor.start()
        check("start publishes one cheap initial reading", monitor.sample != nil && monitor.isMonitoring)
        monitor.start()
        check("repeated start remains active", monitor.isMonitoring)
        monitor.stop()
        check("stop disables background monitoring and preserves the last reading", !monitor.isMonitoring && monitor.sample != nil)
        monitor.refresh()
        check("manual refresh does not resume a paused monitor", !monitor.isMonitoring)
        return lines
    }
}
