import Foundation
import Darwin

/// Self-checks for the Live Performance feature, in the same "PASS/FAIL lines" shape as
/// SelfTest.swift. Exercises PerfProbe directly rather than PerfService, since the service
/// is @MainActor and timer-driven — the probe is where the actual measurement logic lives.
enum PerfSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        // Compare against an independent API in seconds, so an Apple Silicon
        // timebase error cannot pass merely by staying inside the 0...100% range.
        func ownCounters() -> (ticks: UInt64, seconds: Double)? {
            var info = proc_taskinfo(), usage = rusage()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size,
                  getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            return (info.pti_total_user + info.pti_total_system, seconds)
        }
        let beforeCPU = ownCounters()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while ProcessInfo.processInfo.systemUptime < deadline { _ = getpid() }
        let afterCPU = ownCounters()
        if let beforeCPU, let afterCPU, afterCPU.ticks >= beforeCPU.ticks {
            let actual = ProcessCPUClock.seconds(ticks: afterCPU.ticks - beforeCPU.ticks)
            let expected = afterCPU.seconds - beforeCPU.seconds
            check("Mach CPU time agrees with independent getrusage seconds",
                  expected > 0.001 && abs(actual - expected) < max(0.002, expected * 0.1),
                  String(format: "probe %.4fs, getrusage %.4fs, timebase %.5f", actual, expected, ProcessCPUClock.nanosecondsPerTick))
        } else { check("Mach CPU time agrees with independent getrusage seconds", false, "self counters unavailable") }

        // Sweep #1 establishes the CPU-delta baseline; sweep #2 (after a short, real
        // wall-clock gap) is where CPU%, disk I/O and system snapshot actually populate —
        // matching how the two-taskinfo-readings approach works across polling ticks.
        let t0 = Date()
        let first = PerfProbe.sweep(previous: PerfProbe.CPUState())
        let firstMs = Date().timeIntervalSince(t0) * 1000
        check("sweep #1 completes", true, "\(String(format: "%.2f", firstMs)) ms, \(first.procs.count) processes")
        check("sweep #1 sees at least one process", !first.procs.isEmpty)
        check("current process is present", first.procs.contains { $0.pid == getpid() })

        usleep(300_000)   // 0.3s gap so the second sweep has a real CPU-time delta to measure

        let t1 = Date()
        let second = PerfProbe.sweep(previous: first.newState)
        let sweepMs = Date().timeIntervalSince(t1) * 1000
        check("sweep #2 completes", true, "\(String(format: "%.2f", sweepMs)) ms")
        check("sweep cost is cheap enough to poll on a timer", sweepMs < 200,
              "\(String(format: "%.2f", sweepMs)) ms (budget 200 ms)")

        check("core count is plausible", PerfProbe.coreCount >= 1 && PerfProbe.coreCount <= 256,
              "\(PerfProbe.coreCount)")

        let ownedProcs = second.procs.filter(\.owned)
        check("at least one owned process found", !ownedProcs.isEmpty, "\(ownedProcs.count) owned")
        check("owned processes carry a disk-I/O reading", ownedProcs.contains { $0.diskIOKnown })
        let notOwned = second.procs.filter { !$0.owned }
        check("processes we don't own never get a disk-I/O reading (rusage guard)",
              notOwned.allSatisfy { !$0.diskIOKnown }, "\(notOwned.count) not-owned in this sweep")

        check("CPU% values are within 0...100×cores", second.procs.allSatisfy {
            $0.cpuPercent >= 0 && $0.cpuPercent <= 100 * Double(PerfProbe.coreCount)
        })
        check("RSS values are non-negative", second.procs.allSatisfy { $0.rss >= 0 })
        check("lifetime CPU seconds are non-negative", second.procs.allSatisfy { $0.lifetimeCPUSeconds >= 0 })

        check("groups are non-empty when processes exist", !second.groups.isEmpty)
        let groupPidTotal = second.groups.reduce(0) { $0 + $1.count }
        check("grouping doesn't drop or duplicate processes", groupPidTotal == second.procs.count,
              "\(groupPidTotal) grouped vs \(second.procs.count) sampled")

        check("thermal state is a recognized value",
              [.nominal, .fair, .serious, .critical].contains(second.system.thermalState) as Bool)
        check("load averages are non-negative",
              second.system.loadAvg1 >= 0 && second.system.loadAvg5 >= 0 && second.system.loadAvg15 >= 0)
        check("uptime is positive", second.system.uptime > 0, "\(String(format: "%.0f", second.system.uptime))s")
        check("system busy+idle percentages are sane",
              second.system.systemUserPercent >= 0 && second.system.systemSystemPercent >= 0
              && second.system.systemIdlePercent >= 0)

        let advisories = PerfProbe.advisories(groups: second.groups, system: second.system)
        check("advisories are generated without crashing", true, "\(advisories.count) lines")

        // Safety: signal refusal, never actually sending a real signal in a self-check.
        let refusedInit = PerfActions.canSignal(pid: 1, uid: getuid())
        check("refuses to signal pid 1", !refusedInit.ok, refusedInit.why)
        let refusedRoot = PerfActions.canSignal(pid: 2, uid: 0)
        check("refuses to signal a process not owned by the current user", !refusedRoot.ok, refusedRoot.why)
        let allowedSelf = PerfActions.canSignal(pid: getpid(), uid: getuid())
        check("permits signaling a pid the current user owns (not sent — just the gate)", allowedSelf.ok)

        return lines
    }
}
