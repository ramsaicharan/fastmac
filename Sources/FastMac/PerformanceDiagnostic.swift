import Foundation

/// Explicit, read-only CLI capture. Does not start monitoring, persist history,
/// inspect arguments/environment, or act on other apps.
enum PerformanceDiagnostic {
    static func run(seconds: Int) throws {
        var previous = PerfProbe.CPUState()
        var memory: MemorySample?
        var lastUptime: Double?
        var rows: [[String: Any]] = []
        let duration = min(60, max(5, seconds))
        let names = Set(["ChatGPT", "Codex", "Claude", "Claude Code", "Google Chrome", "FastMac"])
        for index in 0...(duration / 5) {
            if index > 0 { Thread.sleep(forTimeInterval: 5) }
            let uptime = ProcessInfo.processInfo.systemUptime
            let sweep = PerfProbe.sweep(previous: previous)
            let health = HealthProbe.sample()
            let swap = ActivityMemoryRates.make(current: health.memory, previous: memory,
                                                elapsed: lastUptime.map { uptime - $0 })
            previous = sweep.newState
            memory = health.memory
            lastUptime = uptime
            let groups: [[String: Any]] = sweep.groups.filter { names.contains($0.name) }.map { group in
                let members = sweep.procs.filter { $0.appKey == group.id }
                let roles = Dictionary(grouping: members) { URL(fileURLWithPath: $0.path).lastPathComponent }
                let details: [[String: Any]] = roles.map { role, procs in
                    ["role": role, "processes": procs.count,
                     "waitingProcesses": procs.filter { $0.runState == .waiting }.count,
                     "unknownStateProcesses": procs.filter { $0.runState == .unknown }.count,
                     "rssBytes": procs.reduce(Int64(0)) { $0 + $1.rss },
                     "footprintBytes": procs.allSatisfy { $0.footprint != nil }
                        ? procs.reduce(Int64(0)) { $0 + ($1.footprint ?? 0) } as Any : NSNull(),
                     "cpuPercent": procs.allSatisfy(\.cpuAvailable)
                        ? procs.reduce(0.0) { $0 + $1.cpuPercent } as Any : NSNull()]
                }.sorted { ($0["rssBytes"] as? Int64 ?? 0) > ($1["rssBytes"] as? Int64 ?? 0) }
                return ["name": group.name, "processes": group.count, "rssBytes": group.rss,
                        "cpuPercent": group.cpuAvailable ? group.cpuPercent as Any : NSNull(),
                        "footprintBytes": members.allSatisfy { $0.footprint != nil }
                            ? members.reduce(Int64(0)) { $0 + ($1.footprint ?? 0) } as Any : NSNull(),
                        "roles": details]
            }
            rows.append([
                "timestamp": ISO8601DateFormatter().string(from: Date()), "cores": sweep.system.coreCount,
                "cpuPercent": sweep.system.cpuAvailable
                    ? sweep.system.systemUserPercent + sweep.system.systemSystemPercent as Any : NSNull(),
                "memoryTotalBytes": health.memory.total, "compressedBytes": health.memory.compressor,
                "uncompressedBytesInCompressor": health.memory.stored, "wiredBytes": health.memory.wired,
                "swapBytes": health.swapAvailable ? health.memory.swapUsed as Any : NSNull(),
                "swapInBytesPerSecond": swap.read as Any? ?? NSNull(),
                "swapOutBytesPerSecond": swap.write as Any? ?? NSNull(),
                "memoryPressure": health.memoryPressure.rawValue, "thermal": health.thermalTitle,
                "diskFreeBytes": health.diskFree, "diskTotalBytes": health.diskTotal,
                "readableProcesses": sweep.pidsReadable, "listedProcesses": sweep.pidsListed,
                "probeMilliseconds": sweep.sweepMs, "apps": groups])
        }
        let document: [String: Any] = ["samples": rows,
            "cpuNanosecondsPerMachTick": ProcessCPUClock.nanosecondsPerTick,
            "cpuMeasurementVersion": 2,
            "scope": "Read-only kernel counters; CPU is percent of one core for apps, whole-machine for system. RSS sums can double-count shared pages. Footprint is summed kernel accounting, including compressed allocations, not additional RAM on top of RSS. No command arguments or project paths."]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
