import Foundation
import AppKit
import Combine
import Darwin
import IOKit.ps
import IOKit.pwr_mgt

/// PROC_PIDTASKINFO CPU counters are Mach absolute-time ticks, not nanoseconds.
/// Apple Silicon commonly uses a 125/3 timebase; Intel commonly uses 1/1.
enum ProcessCPUClock {
    static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0, info.numer > 0 else { return .nan }
        return Double(info.numer) / Double(info.denom)
    }()
    static func seconds(ticks: UInt64) -> Double {
        Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }
}

// MARK: - Live Performance
//
// Sibling to Memory.swift: same "read the kernel directly, no subprocesses" approach,
// extended to per-process CPU%, disk I/O, thermal state, and system load.
//
// The one constraint that shaped this whole file: proc_pid_rusage() blocks indefinitely
// on a process the current user does not own — confirmed during development, where it
// hung an entire sweep. proc_pidinfo(PROC_PIDTASKINFO/PROC_PIDT_SHORTBSDINFO) does not
// block, so those run for every pid; proc_pid_rusage only ever runs after an ownership
// check via PROC_PIDT_SHORTBSDINFO's pbsi_uid. In practice, on an unprivileged account,
// proc_pidinfo(PROC_PIDTASKINFO) itself already returns EPERM for most not-owned system
// processes (measured: 681 pids listed, 433 accessible, all 433 owned by this user) —
// so the guard is a defensive belt-and-suspenders check, not the only thing standing
// between this code and a hang.

// MARK: - Sampled data

struct PerfProcSample: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let comm: String          // up to 16 chars, from the kernel's proc table
    var appName: String       // grouped the way Memory.swift groups helpers under their app
    let path: String
    let uid: uid_t
    let owned: Bool
    let rss: Int64
    /// Percent of one core, following Activity Monitor: one busy core reads 100%;
    /// multithreaded processes can reach 100 × logical core count.
    let cpuPercent: Double
    /// Equivalent whole cores consumed (0...coreCount), the un-normalized figure.
    let cpuCores: Double
    /// Cumulative CPU time since the process started, in seconds. Not a rate — this is
    /// pti_total_user + pti_total_system converted from Mach ticks to seconds.
    let lifetimeCPUSeconds: Double
    /// nil when not sampled (process not owned by the current user, or the rusage call failed).
    let diskRead: Int64?
    let diskWrite: Int64?
    var id: pid_t { pid }
    var appKey: String = ""
    var identity: ProcessIdentity? = nil
    var cpuAvailable = true
    /// Kernel-accounted footprint, including compressed allocations. Not RSS.
    var footprint: Int64?
    var runState: ProcessRunState = .unknown

    var diskIOKnown: Bool { diskRead != nil || diskWrite != nil }
}

struct PerfAppGroup: Identifiable, Hashable {
    let name: String
    let pids: [pid_t]
    var count: Int { pids.count }
    let cpuPercent: Double
    let rss: Int64
    /// nil when any member lacks the counter; unavailable is different from zero.
    let diskRead: Int64?
    let diskWrite: Int64?
    let lifetimeCPUSeconds: Double
    var appKey: String = ""
    var cpuAvailable = true
    var footprint: Int64?
    var id: String { appKey.isEmpty ? name : appKey }
}

struct SystemSnapshot: Equatable {
    var coreCount: Int = 1
    var loadAvg1: Double = 0
    var loadAvg5: Double = 0
    var loadAvg15: Double = 0
    var uptime: TimeInterval = 0
    var onBattery: Bool = false
    var batteryPercent: Int?
    var isCharging: Bool = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// From IOPMCopyCPUPowerStatus — percent of normal clock speed the CPU is allowed to
    /// run at. Intel/XCPM concept; on Apple Silicon the call typically returns "not found"
    /// (confirmed on the dev machine, an M-series Mac), so this stays nil there and the
    /// thermal-state advisory carries the throttling signal instead.
    var speedLimitPercent: Int?
    var schedulerLimitPercent: Int?
    var systemUserPercent: Double = 0
    var systemSystemPercent: Double = 0
    var systemIdlePercent: Double = 0
    /// A valid pair of readable host tick snapshots is required for a CPU rate.
    var cpuAvailable = false
    /// Summed from each process's pti_csw delta — a real kernel-reported number, but an
    /// undercount of the true system-wide total: it misses threads/processes that exited
    /// mid-interval and any switching accounted to the idle/kernel context itself.
    var contextSwitchesPerSec: Double = 0

    var thermalLabel: String {
        switch thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Probe (stateless; the service holds state between sweeps)

enum PerfProbe {
    struct CPUState {
        var perPid: [pid_t: (userSysTicks: UInt64, csw: Int32, identity: ProcessIdentity?)] = [:]
        var hostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
        var at = Date.distantPast
        var sampledUptime: TimeInterval = 0
    }

    struct SweepResult {
        var procs: [PerfProcSample] = []
        var groups: [PerfAppGroup] = []
        var system = SystemSnapshot()
        var newState = CPUState()
        var sweepMs: Double = 0
        /// Every pid the kernel listed, including ones we may not inspect.
        var pidsListed: Int = 0
        /// Pids we could actually read task info for. Without root the kernel denies
        /// PROC_PIDTASKINFO for processes owned by other users — measured on this machine
        /// as 0 of 255 non-owned readable — so the list below is *your* processes only.
        /// Saying so is the difference between an honest tool and a confusing one.
        var pidsReadable: Int = 0
        var hiddenCount: Int { max(0, pidsListed - pidsReadable) }
    }

    static let myUID: uid_t = getuid()

    static let coreCount: Int = {
        var v: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.logicalcpu", &v, &sz, nil, 0) == 0, v > 0 { return Int(v) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }()

    /// One full sweep of every process on the system. Cost is measured by the caller
    /// (SweepResult.sweepMs) so the polling view can report it honestly.
    static func sweep(previous: CPUState) -> SweepResult {
        let t0 = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        var result = SweepResult()

        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else {
            result.newState = CPUState(at: t0, sampledUptime: uptime)
            result.system = systemSnapshot(cswPerSec: 0, hostTicks: nil, previous: previous)
            result.sweepMs = Date().timeIntervalSince(t0) * 1000
            return result
        }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                 Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else {
            result.newState = CPUState(at: t0, sampledUptime: uptime)
            result.system = systemSnapshot(cswPerSec: 0, hostTicks: nil, previous: previous)
            result.sweepMs = Date().timeIntervalSince(t0) * 1000
            return result
        }
        let n = Int(got) / MemoryLayout<pid_t>.size
        result.pidsListed = n

        let interval = uptime - previous.sampledUptime
        let elapsed = max(0.001, interval)
        let hasBaseline = ActivitySamplingContinuity.elapsed(currentUptime: uptime, currentAt: t0,
            previousUptime: previous.sampledUptime, previousAt: previous.at) != nil && !previous.perPid.isEmpty

        var newPerPid: [pid_t: (userSysTicks: UInt64, csw: Int32, identity: ProcessIdentity?)] = [:]
        newPerPid.reserveCapacity(n)
        var cswDeltaSum: Int64 = 0
        var samples: [PerfProcSample] = []
        samples.reserveCapacity(n)

        let pathMax = 4 * Int(MAXPATHLEN)   // PROC_PIDPATHINFO_MAXSIZE, which does not import
        var pathBuf = [CChar](repeating: 0, count: pathMax)

        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 { continue }
            let identity = ProcessIdentity.capture(pid: pid)

            var ti = proc_taskinfo()
            let tiSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }

            var sb = proc_bsdshortinfo()
            let sbSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let sbOK = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sb, sbSize) == sbSize
            let uid: uid_t = sbOK ? sb.pbsi_uid : .max
            let ppid: pid_t = sbOK ? pid_t(bitPattern: sb.pbsi_ppid) : 0
            let comm = sbOK ? cStringOf(sb.pbsi_comm) : ""
            let owned = uid == myUID

            let userSysTicks = ti.pti_total_user + ti.pti_total_system
            var cpuPercent = 0.0, cpuCores = 0.0
            var cpuAvailable = false
            if hasBaseline, ProcessCPUClock.nanosecondsPerTick.isFinite,
               let prev = previous.perPid[pid], let identity,
               prev.identity == identity, userSysTicks >= prev.userSysTicks {
                let deltaSeconds = ProcessCPUClock.seconds(ticks: userSysTicks - prev.userSysTicks)
                cpuCores = min(Double(coreCount), max(0, deltaSeconds / elapsed))
                cpuPercent = cpuCores * 100
                cpuAvailable = true
                cswDeltaSum += Int64(max(0, ti.pti_csw &- prev.csw))
            }
            newPerPid[pid] = (userSysTicks, ti.pti_csw, identity)

            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(cString: pathBuf) : ""
            let fallback = comm.isEmpty ? "pid \(pid)" : comm
            let owner = MemoryProbe.appOwner(path: path)
            let app = owner.name.isEmpty ? fallback : owner.name
            let appKey = MemoryProbe.appKey(path: path, fallback: "pid \(pid)")

            var diskRead: Int64?, diskWrite: Int64?, footprint: Int64?
            if owned, identity?.uid == myUID, identity == ProcessIdentity.capture(pid: pid) {
                var ru = rusage_info_v4()
                let rc = withUnsafeMutablePointer(to: &ru) { p -> Int32 in
                    p.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { rp in
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
                    }
                }
                if rc == 0 {
                    diskRead = Int64(ru.ri_diskio_bytesread)
                    diskWrite = Int64(ru.ri_diskio_byteswritten)
                    footprint = Int64(clamping: ru.ri_phys_footprint)
                }
            }

            samples.append(PerfProcSample(
                pid: pid, ppid: ppid, comm: comm.isEmpty ? app : comm, appName: app, path: path,
                uid: uid, owned: owned, rss: Int64(ti.pti_resident_size),
                cpuPercent: cpuPercent, cpuCores: cpuCores,
                lifetimeCPUSeconds: ProcessCPUClock.seconds(ticks: userSysTicks),
                diskRead: diskRead, diskWrite: diskWrite, appKey: appKey, identity: identity,
                cpuAvailable: cpuAvailable, footprint: footprint,
                runState: .measured(bsdStatus: sbOK ? sb.pbsi_status : nil,
                    runningThreads: ti.pti_numrunning, threadCount: ti.pti_threadnum)))
        }

        samples = associateEmbeddedWorkers(samples)
        result.groups = group(samples)

        result.pidsReadable = samples.count
        result.procs = samples.sorted { $0.cpuPercent > $1.cpuPercent }

        let cswPerSec = hasBaseline ? Double(cswDeltaSum) / elapsed : 0
        var hostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                            / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &loadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            hostTicks = (loadInfo.cpu_ticks.0, loadInfo.cpu_ticks.1,
                        loadInfo.cpu_ticks.2, loadInfo.cpu_ticks.3)
        }

        result.system = systemSnapshot(cswPerSec: cswPerSec, hostTicks: hostTicks, previous: previous)
        result.newState = CPUState(perPid: newPerPid, hostTicks: hostTicks, at: t0, sampledUptime: uptime)
        result.sweepMs = Date().timeIntervalSince(t0) * 1000
        return result
    }

    private static func systemSnapshot(
        cswPerSec: Double,
        hostTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?,
        previous: CPUState
    ) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.coreCount = coreCount
        s.contextSwitchesPerSec = cswPerSec

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            s.loadAvg1 = loads[0]; s.loadAvg5 = loads[1]; s.loadAvg15 = loads[2]
        }

        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0, boot.tv_sec > 0 {
            let bootDate = Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
            s.uptime = Date().timeIntervalSince(bootDate)
        } else {
            // Available even when a sandbox denies the boot-time sysctl.
            s.uptime = ProcessInfo.processInfo.systemUptime
        }

        s.thermalState = ProcessInfo.processInfo.thermalState

        var cpuPowerStatus: Unmanaged<CFDictionary>?
        if IOPMCopyCPUPowerStatus(&cpuPowerStatus) == kIOReturnSuccess, let u = cpuPowerStatus {
            let dict = u.takeRetainedValue() as? [String: Any]
            s.speedLimitPercent = dict?[kIOPMCPUPowerLimitProcessorSpeedKey] as? Int
            s.schedulerLimitPercent = dict?[kIOPMCPUPowerLimitSchedulerTimeKey] as? Int
        }

        if let blobU = IOPSCopyPowerSourcesInfo() {
            let blob = blobU.takeRetainedValue()
            if let listU = IOPSCopyPowerSourcesList(blob) {
                let list = listU.takeRetainedValue() as [CFTypeRef]
                if let first = list.first, let descU = IOPSGetPowerSourceDescription(blob, first) {
                    let desc = descU.takeUnretainedValue() as? [String: Any]
                    if let state = desc?[kIOPSPowerSourceStateKey] as? String {
                        s.onBattery = state == kIOPSBatteryPowerValue
                    }
                    s.batteryPercent = desc?[kIOPSCurrentCapacityKey] as? Int
                    s.isCharging = (desc?[kIOPSIsChargingKey] as? Bool) ?? false
                }
            }
        }

        if ActivitySamplingContinuity.elapsed(currentUptime: ProcessInfo.processInfo.systemUptime,
            currentAt: Date(), previousUptime: previous.sampledUptime, previousAt: previous.at) != nil,
           let prevTicks = previous.hostTicks, let cur = hostTicks {
            func d(_ a: UInt32, _ b: UInt32) -> Double { Double(a &- b) }
            let du = d(cur.user, prevTicks.user), dsys = d(cur.system, prevTicks.system)
            let didle = d(cur.idle, prevTicks.idle), dnice = d(cur.nice, prevTicks.nice)
            let total = du + dsys + didle + dnice
            if total > 0 {
                s.cpuAvailable = true
                s.systemUserPercent = (du + dnice) / total * 100
                s.systemSystemPercent = dsys / total * 100
                s.systemIdlePercent = didle / total * 100
            }
        }
        return s
    }

    static func associateEmbeddedWorkers(_ samples: [PerfProcSample]) -> [PerfProcSample] {
        let nodes = samples.compactMap { sample -> AppProcessOwnership.Node? in
            guard let identity = sample.identity, identity.path == sample.path, identity.uid == sample.uid else { return nil }
            return .init(identity: identity, parentPID: sample.ppid)
        }
        let owners = AppProcessOwnership.overrides(nodes)
        return samples.map { original in
            var sample = original
            if let owner = owners[sample.pid] { sample.appName = owner.name; sample.appKey = owner.bundle }
            return sample
        }
    }

    /// The grouping key is an executable/outer app path, never just a display name.
    /// All counters in a group must be readable before we report its disk total.
    static func group(_ samples: [PerfProcSample]) -> [PerfAppGroup] {
        let grouped = Dictionary(grouping: samples) { sample in
            sample.appKey.isEmpty
                ? MemoryProbe.appKey(path: sample.path, fallback: "pid \(sample.pid)")
                : sample.appKey
        }
        return grouped.map { key, members in
            PerfAppGroup(name: members.first?.appName ?? key, pids: members.map(\.pid),
                         cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                         rss: members.reduce(0) { $0 + $1.rss },
                         diskRead: members.allSatisfy { $0.diskRead != nil }
                            ? members.reduce(0) { $0 + ($1.diskRead ?? 0) } : nil,
                         diskWrite: members.allSatisfy { $0.diskWrite != nil }
                            ? members.reduce(0) { $0 + ($1.diskWrite ?? 0) } : nil,
                         lifetimeCPUSeconds: members.reduce(0) { $0 + $1.lifetimeCPUSeconds },
                         appKey: key, cpuAvailable: members.allSatisfy(\.cpuAvailable),
                         footprint: members.allSatisfy { $0.footprint != nil }
                            ? members.reduce(0) { $0 + ($1.footprint ?? 0) } : nil)
        }.sorted { a, b in
            if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
            if a.rss != b.rss { return a.rss > b.rss }
            return a.id < b.id
        }
    }

    private static func cStringOf<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let len = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<len], as: UTF8.self)
        }
    }

    // MARK: honest advice

    static func advisories(groups: [PerfAppGroup], system: SystemSnapshot) -> [String] {
        var out: [String] = []

        switch system.thermalState {
        case .critical:
            out.append("Thermal state is \"critical\" — the machine is throttling hard; expect stutters.")
        case .serious:
            out.append("Thermal state is \"serious\" — the machine is throttling.")
        case .fair:
            out.append("Thermal state is \"fair\" — running warm; light throttling is possible.")
        case .nominal: break
        @unknown default: break
        }
        if let limit = system.speedLimitPercent, limit < 100 {
            out.append("CPU speed is capped at \(limit)% of normal by the system (thermal or power limit).")
        }

        if system.loadAvg1 > Double(system.coreCount) * 1.5 {
            out.append("1-minute load average (\(String(format: "%.1f", system.loadAvg1))) is well above "
                        + "the \(system.coreCount) available cores — the CPU is oversubscribed.")
        }

        if system.onBattery, let pct = system.batteryPercent, pct <= 20, !system.isCharging {
            out.append("Running on battery at \(pct)% and not charging.")
        }

        if groups.contains(where: { $0.count >= 8 }) {
            out.append("App totals include waiting helpers. Select an app below to review states, CPU and memory; process count alone does not measure active work.")
        }
        for g in groups.sorted(by: { $0.lifetimeCPUSeconds > $1.lifetimeCPUSeconds }).prefix(40)
        where g.lifetimeCPUSeconds >= 3600 {
            out.append("\(g.name) has used \(String(format: "%.1f", g.lifetimeCPUSeconds / 3600)) hours of CPU since it started.")
        }
        for g in groups.prefix(5) where g.cpuAvailable && g.cpuPercent >= 25 {
            out.append("\(g.name) is using \(String(format: "%.0f", g.cpuPercent))% CPU (100% = one core) right now.")
        }

        if system.contextSwitchesPerSec > 20_000 {
            out.append("The system is context-switching ~\(Int(system.contextSwitchesPerSec).formatted())/sec "
                        + "(summed across visible processes) — heavier than typical.")
        }

        return out
    }
}

// MARK: - Actions (Quit / Force Quit)

enum PerfActions {
    static func canSignal(pid: pid_t, uid: uid_t) -> (ok: Bool, why: String) {
        if pid <= 1 { return (false, "refusing pid \(pid): the kernel or launchd") }
        if uid != getuid() { return (false, "not owned by you; refusing another user's process") }
        return (true, "")
    }

    /// Pure validation is also used by fixture checks; every real action obtains the
    /// current identity again directly before touching AppKit or calling kill().
    static func validate(expected: ProcessIdentity?, current: ProcessIdentity?) -> (ok: Bool, why: String) {
        guard let expected else { return (false, "Process identity is unavailable. Refresh the list and try again.") }
        let gate = canSignal(pid: expected.pid, uid: expected.uid)
        guard gate.ok else { return gate }
        guard expected.pid != getpid() else { return (false, "Use FastMac's Quit menu to close this app.") }
        guard let current else { return (false, "The process exited or its identity is no longer readable.") }
        guard current == expected else {
            return (false, "This PID now belongs to a different process, owner, or executable. Refresh and try again.")
        }
        return (true, "")
    }

    @MainActor
    static func confirmation(identity: ProcessIdentity?, force: Bool) -> String {
        guard let identity else { return "Identity unavailable; refresh the process list before trying again." }
        if let app = NSRunningApplication(processIdentifier: identity.pid), app.bundleURL != nil {
            return force
                ? "Force quits this application immediately. Unsaved changes may be lost."
                : "Asks this application to quit through macOS. It can prompt you to save changes or decline to quit."
        }
        return force
            ? "Sends SIGKILL to this process immediately. It has no chance to save state; unsaved work may be lost."
            : "Sends SIGTERM to this process. It may exit without saving, ignore the request, or take time to stop."
    }

    @MainActor
    static func terminate(identity: ProcessIdentity?, name: String, force: Bool) async -> (ok: Bool, message: String) {
        let check = validate(expected: identity, current: identity.flatMap { ProcessIdentity.capture(pid: $0.pid) })
        guard check.ok, let identity else { return (false, check.why) }
        let accepted: Bool
        let action: String
        if let app = NSRunningApplication(processIdentifier: identity.pid), app.bundleURL != nil {
            // Validate again after looking up the application; an old row must never
            // target an application that just inherited its PID.
            let latest = validate(expected: identity, current: ProcessIdentity.capture(pid: identity.pid))
            guard latest.ok else { return (false, latest.why) }
            accepted = force ? app.forceTerminate() : app.terminate()
            action = force ? "force-quit request" : "macOS quit request"
        } else {
            let latest = validate(expected: identity, current: ProcessIdentity.capture(pid: identity.pid))
            guard latest.ok else { return (false, latest.why) }
            accepted = kill(identity.pid, force ? SIGKILL : SIGTERM) == 0
            action = force ? "SIGKILL" : "SIGTERM"
            if !accepted {
                let reason = String(cString: strerror(errno))
                return (false, "Could not send \(action) to \(name): \(reason)")
            }
        }
        guard accepted else { return (false, "macOS declined the \(action) for \(name).") }
        Audit.log(force ? "perf-force-quit-requested" : "perf-quit-requested", bytes: 0,
                  path: "pid \(identity.pid) \(name) · start \(identity.startedSeconds).\(identity.startedMicroseconds)")
        // A successful signal/request is not proof of exit. Observe for a bounded
        // window without blocking the main thread, then report the distinction.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !isStillRunning(identity) {
                return (true, "\(name) exited after the \(action).")
            }
        }
        if force {
            return (true, "\(action) accepted for \(name); its exit has not been confirmed yet.")
        }
        return (true, "\(action) accepted for \(name); it is still running. It may be waiting for you to save or may have ignored the request.")
    }

    static func isStillRunning(_ identity: ProcessIdentity) -> Bool {
        if let current = ProcessIdentity.capture(pid: identity.pid) {
            return current.startedSeconds == identity.startedSeconds
                && current.startedMicroseconds == identity.startedMicroseconds
        }
        // Unreadable identity does not prove exit. ESRCH does; EPERM means alive.
        if kill(identity.pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    @MainActor
    static func terminate(group: ProcGroup) async -> (ok: Bool, message: String) {
        guard group.signalable, group.identities.count == group.pids.count, !group.identities.isEmpty else {
            return (false, "This group contains unreadable or unowned processes. Refresh before trying again.")
        }
        for identity in group.identities {
            let check = validate(expected: identity, current: ProcessIdentity.capture(pid: identity.pid))
            guard check.ok else { return (false, check.why) }
        }
        // Quitting the main app lets it coordinate its helpers and save dialogs.
        if let app = NSWorkspace.shared.runningApplications.first(where: { app in
            guard let url = app.bundleURL else { return false }
            return url.standardizedFileURL.path == group.appKey
                && group.identities.contains { $0.pid == app.processIdentifier }
        }), let identity = group.identities.first(where: { $0.pid == app.processIdentifier }) {
            return await terminate(identity: identity, name: group.name, force: false)
        }
        if group.appKey.hasSuffix(".app") {
            return (false, "The main app could not be verified. Open \(group.name) and quit it normally; its helpers were not stopped individually.")
        }
        var messages: [String] = []
        var allAccepted = true
        for identity in group.identities {
            let result = await terminate(identity: identity, name: "\(group.name) (pid \(identity.pid))", force: false)
            allAccepted = allAccepted && result.ok
            messages.append(result.message)
        }
        return (allAccepted, messages.joined(separator: "\n"))
    }
}

// MARK: - Service (owns polling; the view owns this via @StateObject)

@MainActor
final class PerfService: ObservableObject {
    @Published var procs: [PerfProcSample] = []
    @Published var groups: [PerfAppGroup] = []
    @Published var system = SystemSnapshot()
    @Published var advisories: [String] = []
    @Published var cpuHistory: [Double] = []     // total system busy% (100 - idle), most recent last
    @Published var sweepMs: Double = 0
    @Published var lastUpdated: Date?
    @Published var actionMessage: String?

    private var visible = false
    private var epoch = 0
    private var tick: AnyCancellable?
    private var pollInFlight = false
    private var cpuState = PerfProbe.CPUState()

    /// Mirrors AppStore.setMemoryVisible's pattern: poll only while the tab is on screen,
    /// and invalidate any in-flight sweep the moment it isn't.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        epoch &+= 1
        let e = epoch
        tick?.cancel(); tick = nil
        pollInFlight = false
        guard visible else { return }
        cpuState = PerfProbe.CPUState()
        cpuHistory = []
        pollOnce(epoch: e)
        tick = Timer.publish(every: 2.5, tolerance: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.pollOnce(epoch: e) }
    }

    private func pollOnce(epoch: Int) {
        guard visible, epoch == self.epoch, !pollInFlight else { return }
        pollInFlight = true
        let prevState = cpuState
        Task.detached(priority: .utility) { [weak self] in
            let result = PerfProbe.sweep(previous: prevState)
            guard let owner = self else { return }
            await MainActor.run {
                guard owner.visible, owner.epoch == epoch else { return }
                owner.cpuState = result.newState
                // Keep the readable sweep so a low-CPU helper is not omitted from
                // an app breakdown. The visible process table is still bounded.
                owner.procs = result.procs
                owner.groups = Array(result.groups.prefix(25))
                owner.system = result.system
                owner.sweepMs = result.sweepMs
                owner.lastUpdated = Date()
                owner.advisories = PerfProbe.advisories(groups: result.groups, system: result.system)
                if result.system.cpuAvailable {
                    owner.cpuHistory.append(result.system.systemUserPercent + result.system.systemSystemPercent)
                }
                if owner.cpuHistory.count > 150 { owner.cpuHistory.removeFirst() }
                owner.pollInFlight = false
            }
        }
    }

    /// Refresh after an action when no sweep is already running. Never overlap a
    /// sweep with an older CPU baseline merely to make the list refresh faster.
    private func pollSoon() {
        pollOnce(epoch: epoch)
    }

    func quit(_ p: PerfProcSample) {
        performAction(p, force: false)
    }

    func forceQuit(_ p: PerfProcSample) {
        performAction(p, force: true)
    }

    private func performAction(_ p: PerfProcSample, force: Bool) {
        actionMessage = "Requesting \(force ? "Force Quit" : "Quit") for \(p.appName)…"
        Task {
            let outcome = await PerfActions.terminate(identity: p.identity, name: p.appName, force: force)
            actionMessage = outcome.message
            pollSoon()
        }
    }
}
