import Foundation
import Darwin

struct MemorySample {
    var total: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressor: Int64 = 0     // RAM the compressor occupies
    var stored: Int64 = 0         // data it holds, uncompressed
    var free: Int64 = 0
    var fileBacked: Int64 = 0
    var purgeable: Int64 = 0
    var swapUsed: Int64 = 0
    var swapTotal: Int64 = 0
    // Cumulative VM page counters; rates require a second, continuous reading.
    var swapInPages: UInt64?
    var swapOutPages: UInt64?
    var at = Date()

    var used: Int64 { app + wired + compressor }
    var ratio: Double { compressor > 0 ? Double(stored) / Double(compressor) : 0 }
    var reclaimable: Int64 { fileBacked + purgeable }

    /// Estimate from wired/compressed and non-reclaimable pages. This is not macOS
    /// memory pressure, which Mac Health reads from the OS pressure event source.
    var estimatedLoadPercent: Double {
        guard total > 0 else { return 0 }
        let hard = wired + compressor + max(0, app - reclaimable)
        return min(100, max(0, Double(hard) / Double(total) * 100))
    }

    /// Compatibility for existing menu/CLI consumers; label this as an estimate.
    var pressure: Double { estimatedLoadPercent }

    enum Level { case good, warn, bad }
    var level: Level {
        if swapUsed > 1 << 30 || pressure > 80 { return .bad }
        if swapUsed > 256 << 20 || pressure > 60 { return .warn }
        return .good
    }
    var verdict: String {
        switch level {
        case .bad:  "high estimated memory load or swap use"
        case .warn: "moderate estimated memory load or swap use"
        case .good: "estimated memory load is comfortable"
        }
    }
}

struct ProcGroup: Identifiable, Hashable {
    let name: String
    let rss: Int64
    let count: Int
    var id: String { appKey.isEmpty ? name : appKey }
    var share: Double = 0
    /// Every pid in this group, so the UI can offer to quit what it is showing.
    /// Sorted largest-resident first for display; action selection uses app identity.
    var pids: [pid_t] = []
    /// True when every PID has a readable, stable identity owned by this user,
    /// excluding FastMac itself.
    var signalable: Bool = false
    var appKey: String = ""
    var identities: [ProcessIdentity] = []
}

enum MemoryProbe {
    static let physical: Int64 = {
        var v: Int64 = 0; var sz = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &v, &sz, nil, 0)
        return v
    }()

    static let pageSize: Int64 = {
        var v: UInt = 0; var sz = MemoryLayout<UInt>.size
        if sysctlbyname("vm.pagesize", &v, &sz, nil, 0) == 0, v > 0 { return Int64(v) }
        return Int64(vm_kernel_page_size)
    }()

    /// Reads the kernel's VM counters directly — no vm_stat subprocess.
    static func sample() -> MemorySample {
        var s = MemorySample()
        s.total = physical

        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let p = pageSize
            s.free       = Int64(info.free_count) * p
            s.app        = Int64(info.active_count + info.inactive_count + info.speculative_count) * p
            s.wired      = Int64(info.wire_count) * p
            s.compressor = Int64(info.compressor_page_count) * p
            s.stored     = Int64(info.total_uncompressed_pages_in_compressor) * p
            s.fileBacked = Int64(info.external_page_count) * p
            s.purgeable  = Int64(info.purgeable_count) * p
        }

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0 {
            s.swapUsed = Int64(xsw.xsu_used)
            s.swapTotal = Int64(xsw.xsu_total)
        }
        return s
    }

    /// Top consumers grouped by owning app, via libproc.
    static func processes(limit: Int = 14) -> [ProcGroup] {
        let cap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard cap > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cap) / MemoryLayout<pid_t>.size)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<pid_t>.size

        var totals: [String: (name: String, rss: Int64, count: Int,
                              members: [(ProcessIdentity?, pid_t, Int64)], mine: Bool)] = [:]
        var observed: [(identity: ProcessIdentity?, pid: pid_t, path: String, rss: Int64, verified: Bool)] = []
        var nodes: [AppProcessOwnership.Node] = []
        var grand: Int64 = 0
        let pathMax = 4 * Int(MAXPATHLEN)
        var pathBuf = [CChar](repeating: 0, count: pathMax)

        for pid in pids.prefix(n) where pid > 0 {
            let identity = ProcessIdentity.capture(pid: pid)
            // Task info avoids rusage's slow/denied cross-user process queries.
            var ti = proc_taskinfo()
            let tiSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }
            let rss = Int64(ti.pti_resident_size)
            guard rss > 0 else { continue }
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(cString: pathBuf) : ""
            let verified = identity?.uid == getuid() && identity?.path == path
                && identity == ProcessIdentity.capture(pid: pid)
            observed.append((identity, pid, path, rss, verified && pid != getpid()))
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if verified, let identity, proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
               info.pbsi_uid == identity.uid {
                nodes.append(.init(identity: identity, parentPID: pid_t(bitPattern: info.pbsi_ppid)))
            }
        }
        let owners = AppProcessOwnership.overrides(nodes)
        for process in observed {
            let owner = owners[process.pid] ?? appOwner(path: process.path)
            guard !owner.name.isEmpty else { continue }
            let key = owner.bundle.isEmpty ? "pid \(process.pid)" : URL(fileURLWithPath: owner.bundle).standardizedFileURL.path
            var e = totals[key] ?? (owner.name, 0, 0, [], true)
            e.rss += process.rss; e.count += 1
            e.members.append((process.identity, process.pid, process.rss))
            e.mine = e.mine && process.verified
            totals[key] = e
            grand += process.rss
        }

        return totals.map { key, v in
            let members = v.members.sorted { $0.2 > $1.2 }
            return ProcGroup(name: v.name, rss: v.rss, count: v.count,
                             share: grand > 0 ? Double(v.rss) / Double(grand) * 100 : 0,
                             pids: members.map { $0.1 }, signalable: v.mine,
                             appKey: key, identities: members.compactMap { $0.0 })
        }.sorted { $0.rss > $1.rss }.prefix(limit).map { $0 }
    }

    /// Identify the owning application for a process path.
    ///
    /// Two subtleties that produced visibly wrong output before:
    ///  • helper binaries nest one `.app` inside another — the first `.app` is the
    ///    outer owner, which keeps helpers in the same application group;
    ///  • a CLI shipped inside its host app's Application Support directory produces a
    ///    bundle whose name differs from the real app only by case ("claude" vs "Claude"),
    ///    which reads as a duplicate row. Qualify it instead of pretending it is the same
    ///    thing or silently merging two unrelated programs.
    static func appOwner(path: String) -> (name: String, bundle: String) {
        guard let r = path.range(of: ".app/") else {
            let n = (path as NSString).lastPathComponent
            return (n, path)
        }
        // Outermost bundle: everything up to the FIRST ".app/" is the owner.
        let bundle = String(path[path.startIndex..<r.lowerBound]) + ".app"
        var name = (bundle as NSString).lastPathComponent
        name = String(name.dropLast(4))          // strip ".app"

        // A versioned CLI inside another app's support directory.
        if bundle.contains("/claude-code/") { name = "Claude Code" }
        else if bundle.contains("/Application Support/") {
            // Name it for its host so it cannot masquerade as the top-level app.
            let parts = bundle.components(separatedBy: "/Application Support/")
            if parts.count > 1 {
                let host = parts[1].components(separatedBy: "/").first ?? ""
                if !host.isEmpty, host.lowercased() != name.lowercased() {
                    name = "\(name) (\(host))"
                } else if !host.isEmpty {
                    name = "\(host) helper"
                }
            }
        }
        return (name, bundle)
    }

    /// Helpers share the outer application path; unrelated applications that happen
    /// to have the same display name remain separate groups.
    static func appKey(path: String, fallback: String) -> String {
        guard !path.isEmpty else { return fallback }
        return URL(fileURLWithPath: appOwner(path: path).bundle).standardizedFileURL.path
    }

    static func diskFree(_ path: String = "/System/Volumes/Data") -> (free: Int64, total: Int64) {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return (0, 0) }
        let bs = Int64(st.f_bsize)
        return (Int64(st.f_bavail) * bs, Int64(st.f_blocks) * bs)
    }
}

/// PID alone can be reused between polling and confirmation. Capture the kernel's
/// start time and owner as well as its executable, then revalidate before every action.
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let uid: uid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let path: String

    static func capture(pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               startedSeconds: info.pbi_start_tvsec,
                               startedMicroseconds: info.pbi_start_tvusec,
                               path: String(cString: path))
    }
}
