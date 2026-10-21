import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

struct NetworkInterfaceCounter: Sendable, Equatable {
    let name: String
    let received: UInt64
    let sent: UInt64
}

struct NetworkCounterSnapshot: Sendable, Equatable {
    var at: Date = Date()
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var counters: [NetworkInterfaceCounter] = []
    var scopeDescription: String = "Physical network interfaces"
    var counterSource: String = "Kernel interface byte counters"
    var unavailableReason: String?
    var interfaces: [String] { counters.map(\.name).sorted() }
    var downloadBytes: UInt64? { counters.isEmpty ? nil : counters.reduce(0) { $0 + $1.received } }
    var uploadBytes: UInt64? { counters.isEmpty ? nil : counters.reduce(0) { $0 + $1.sent } }
}

struct NetworkRateSnapshot: Sendable, Equatable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var status: String = "Waiting for another reading"
}

struct BatteryResourceSnapshot: Sendable, Equatable {
    var at: Date = Date()
    /// nil means the API failed; false means the API found no internal battery.
    var present: Bool?
    var percent: Int?
    var isCharging: Bool?
    var isOnBattery: Bool?
    var healthPercent: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var detail: String = "Battery reading unavailable"
}

struct GPUResourceSnapshot: Sendable, Equatable {
    var at: Date = Date()
    var utilizationPercent: Double?
    var deviceCount: Int = 0
    var detail: String = "This Mac does not expose a supported GPU utilization counter."
}

/// Stateless read-only probes. Call from a utility task, never from an NSMenu update.
enum ResourceProbe {
    static func networkCounters() -> NetworkCounterSnapshot {
        var result = NetworkCounterSnapshot()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            result.unavailableReason = "macOS did not return network interface counters."
            return result
        }
        defer { freeifaddrs(head) }
        let wide = wideInterfaceCounters()
        var physical: [NetworkInterfaceCounter] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var seen = Set<String>()
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let item = entry.pointee
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let rawName = item.ifa_name, let rawData = item.ifa_data else { continue }
            let name = String(cString: rawName)
            guard isPhysicalInterface(name: name, flags: item.ifa_flags), seen.insert(name).inserted else { continue }
            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            let index = if_nametoindex(rawName)
            if let counts = wide[index] {
                physical.append(NetworkInterfaceCounter(name: name, received: counts.0, sent: counts.1))
            } else if wide.isEmpty {
                // Legacy if_data counters can wrap. A decreasing counter invalidates the
                // interval instead of inventing a rate across the wrap or a reset.
                physical.append(NetworkInterfaceCounter(name: name, received: UInt64(data.ifi_ibytes), sent: UInt64(data.ifi_obytes)))
            }
        }
        if wide.isEmpty { result.counterSource = "Kernel interface byte counters (legacy 32-bit)" }
        let primary = primaryInterface()
        result.counters = selectInterfaces(physical, primary: primary)
        if result.counters.isEmpty {
            result.unavailableReason = "No active physical Ethernet or Wi-Fi interface was found."
        } else if result.counters.count == 1, result.counters.first?.name == primary {
            result.scopeDescription = "Default physical interface · \(result.interfaces.joined(separator: ", "))"
        } else {
            result.scopeDescription = "Active physical interfaces · \(result.interfaces.joined(separator: ", "))"
        }
        return result
    }

    static func isPhysicalInterface(name: String, flags: UInt32) -> Bool {
        name.hasPrefix("en") && name.count > 2 && name.dropFirst(2).allSatisfy(\.isNumber)
        && flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0
        && flags & UInt32(IFF_LOOPBACK) == 0
    }

    static func selectInterfaces(_ values: [NetworkInterfaceCounter], primary: String?) -> [NetworkInterfaceCounter] {
        if let primary, let preferred = values.first(where: { $0.name == primary }) { return [preferred] }
        // VPN tunnel, AWDL, loopback, bridges and their physical transport must never
        // be summed together. When the default route is a tunnel, report only en*.
        return values.sorted { $0.name < $1.name }
    }

    static func networkRate(current: NetworkCounterSnapshot, previous: NetworkCounterSnapshot?, maximumGap: TimeInterval = 90) -> NetworkRateSnapshot {
        guard !current.counters.isEmpty, current.unavailableReason == nil else {
            return NetworkRateSnapshot(status: current.unavailableReason ?? "Network counters unavailable")
        }
        guard let previous, !previous.counters.isEmpty, previous.unavailableReason == nil else {
            return NetworkRateSnapshot()
        }
        guard current.interfaces == previous.interfaces, current.counterSource == previous.counterSource else {
            return NetworkRateSnapshot(status: "Interfaces changed · collecting a new baseline")
        }
        let elapsed = current.uptime - previous.uptime
        let wallElapsed = current.at.timeIntervalSince(previous.at)
        guard elapsed >= 0.2, elapsed <= maximumGap, wallElapsed >= 0, wallElapsed <= maximumGap else {
            return NetworkRateSnapshot(status: "Sampling gap · collecting a new baseline")
        }
        let old = Dictionary(uniqueKeysWithValues: previous.counters.map { ($0.name, $0) })
        var received = 0.0, sent = 0.0
        for item in current.counters {
            guard let before = old[item.name], item.received >= before.received, item.sent >= before.sent else {
                return NetworkRateSnapshot(status: "Counter reset · collecting a new baseline")
            }
            received += Double(item.received - before.received)
            sent += Double(item.sent - before.sent)
        }
        return NetworkRateSnapshot(downloadBytesPerSecond: received / elapsed,
                                   uploadBytesPerSecond: sent / elapsed, status: "Current network throughput")
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "FastMac Resource Probe" as CFString, nil, nil) else { return nil }
        for family in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = state["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    /// getifaddrs supplies topology; the route sysctl supplies 64-bit counters. The
    /// public Darwin if_data64/if_msghdr2 definitions specify the byte counter types.
    private static func wideInterfaceCounters() -> [UInt32: (UInt64, UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 4 * 1024 * 1024 else { return [:] }
        var bytes = [UInt8](repeating: 0, count: size)
        let rc = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard rc == 0 else { return [:] }
        return bytes.withUnsafeBytes { raw in
            var result: [UInt32: (UInt64, UInt64)] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                if raw[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    result[UInt32(header.ifm_index)] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                }
                offset += length
            }
            return result
        }
    }

    static func battery() -> BatteryResourceSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryResourceSnapshot()
        }
        let internalSource = sources.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        return parseBattery(powerSource: internalSource, registry: registryProperties(className: "AppleSmartBattery"))
    }

    /// Capacity health is a raw full-charge/design-capacity estimate, not the
    /// recalibrated maximum-capacity percentage shown in macOS Battery Settings.
    /// No serial number, model identity or charging history is retained.
    static func parseBattery(powerSource: [String: Any]?, registry: [String: Any]?) -> BatteryResourceSnapshot {
        guard let source = powerSource, source[kIOPSIsPresentKey] as? Bool != false else {
            return BatteryResourceSnapshot(present: false, detail: "No internal battery detected.")
        }
        var result = BatteryResourceSnapshot(present: true, detail: "IOPowerSources · additional readings depend on hardware support.")
        if let current = number(source[kIOPSCurrentCapacityKey]), let max = number(source[kIOPSMaxCapacityKey]), max > 0,
           current >= 0, current <= max { result.percent = Int((current / max * 100).rounded()) }
        result.isCharging = source[kIOPSIsChargingKey] as? Bool
        if let state = source[kIOPSPowerSourceStateKey] as? String { result.isOnBattery = state == kIOPSBatteryPowerValue }
        if let cycle = number(registry?["CycleCount"]), cycle >= 0, cycle <= 100_000, cycle.rounded() == cycle {
            result.cycleCount = Int(cycle)
        }
        // AppleRawMaxCapacity and DesignCapacity both use raw charge units. Do not
        // substitute MaxCapacity: that key is percent-scaled on some Apple Macs.
        if let design = number(registry?["DesignCapacity"]), design > 0,
           let full = number(registry?["AppleRawMaxCapacity"]), full > 0 {
            let percent = full / design * 100
            if percent >= 20, percent <= 150 { result.healthPercent = percent }
        }
        // Temperature unit interpretations vary between registry providers. Until
        // validated per hardware family, temperature remains explicitly unavailable.
        return result
    }

    static func gpu() -> GPUResourceSnapshot {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return GPUResourceSnapshot() }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        var count = 0
        while count < 16 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            count += 1
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let percent = parseGPUUtilization(stats) { values.append(percent) }
        }
        guard let busiest = values.max() else {
            return GPUResourceSnapshot(deviceCount: count)
        }
        return GPUResourceSnapshot(utilizationPercent: busiest, deviceCount: count,
                                   detail: "Busiest available IOAccelerator counter · experimental, hardware dependent.")
    }

    static func parseGPUUtilization(_ stats: [String: Any]) -> Double? {
        guard let value = number(stats["Device Utilization %"]), value >= 0, value <= 100 else { return nil }
        return value
    }

    private static func registryProperties(className: String) -> [String: Any]? {
        guard let matching = IOServiceMatching(className) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // Read only the needed fields; do not copy the complete battery registry.
        var result: [String: Any] = [:]
        for key in ["CycleCount", "DesignCapacity", "AppleRawMaxCapacity"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { result[key] = value }
        }
        return result
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

struct ListeningEndpoint: Sendable, Hashable, Identifiable {
    let address: String
    let port: Int
    let allowsLocalhost: Bool
    var id: String { address }
    var localhostURL: URL? { allowsLocalhost ? URL(string: "http://localhost:\(port)") : nil }
}

struct RuntimeProjectProcess: Sendable, Identifiable {
    let pid: pid_t
    let runtime: String
    let command: String
    let directory: String?
    let endpoints: [ListeningEndpoint]
    let identity: ProcessIdentity?
    var residentBytes: Int64? = nil
    var id: pid_t { pid }
    var canStop: Bool { identity?.uid == getuid() && pid > 1 && pid != getpid() }

    func age(at: Date) -> TimeInterval? {
        guard let identity else { return nil }
        let started = Double(identity.startedSeconds) + Double(identity.startedMicroseconds) / 1_000_000
        let age = at.timeIntervalSince1970 - started
        return age >= 0 ? age : nil
    }
}

struct RuntimeProjectGroup: Sendable, Identifiable {
    let directory: String?
    let processes: [RuntimeProjectProcess]
    var id: String { directory ?? "unresolved-\(processes.first?.pid ?? 0)" }
    var title: String { directory.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "Working directory unavailable" }
    var residentCoverage: Int { processes.filter { $0.residentBytes != nil }.count }
    /// Sum of readable process RSS only; shared framework pages can be counted twice.
    var residentBytes: Int64? {
        let values = processes.compactMap(\.residentBytes)
        guard !values.isEmpty else { return nil }
        var sum: Int64 = 0
        for value in values {
            let next = sum.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            sum = next.partialValue
        }
        return sum
    }
}

struct ProjectDiscoveryResult: Sendable {
    var at: Date = Date()
    var groups: [RuntimeProjectGroup] = []
    var listenerCount: Int = 0
    var unrecognizedCount: Int = 0
    var incomplete: Bool = false
    var message: String = ""
}

/// Manual, bounded listening-server discovery. Reads executable identity and the
/// kernel's working directory, never a process's arguments or environment.
enum ProjectProbe {
    struct ListenerRecord: Sendable {
        let pid: pid_t
        var command: String
        var endpoints: [ListeningEndpoint]
    }

    static func discover() -> ProjectDiscoveryResult {
        let command = runBounded(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F0pcn"], timeout: 3, byteLimit: 1_048_576)
        var result = ProjectDiscoveryResult(incomplete: command.timedOut || command.truncated)
        if let error = command.error {
            result.incomplete = true
            result.message = "Listening-server discovery unavailable: \(error)"
            return result
        }
        let listeners = parseListeners(command.data)
        result.listenerCount = listeners.count
        var processes: [RuntimeProjectProcess] = []
        for record in listeners.prefix(256) {
            let identity = ProcessIdentity.capture(pid: record.pid)
            let executable = identity.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? record.command
            guard let runtime = runtimeName(executable) ?? runtimeName(record.command) else {
                result.unrecognizedCount += 1
                continue
            }
            let directory = identity?.uid == getuid() ? workingDirectory(pid: record.pid) : nil
            let resident = identity?.uid == getuid() ? residentMemory(pid: record.pid) : nil
            // The PID may exit or be reused while lsof/cwd are sampled. An unverified
            // record remains inspectable, but is never eligible for a stop action.
            let verified = identity.flatMap { ProcessIdentity.capture(pid: $0.pid) == $0 ? $0 : nil }
            processes.append(RuntimeProjectProcess(pid: record.pid, runtime: runtime, command: record.command,
                                                   directory: verified == nil ? nil : directory,
                                                   endpoints: record.endpoints, identity: verified,
                                                   residentBytes: verified == nil ? nil : resident))
        }
        if listeners.count > 256 { result.incomplete = true }
        result.groups = group(processes)
        if result.incomplete {
            result.message = "Discovery reached its time or size limit. These are partial results."
        } else if command.exitCode != 0 && command.exitCode != 1 {
            result.incomplete = true
            result.message = "macOS returned partial listening-server results. Some processes may be inaccessible."
        } else {
            result.message = "\(processes.count) recognized runtime process\(processes.count == 1 ? "" : "es") · \(result.unrecognizedCount) other listener\(result.unrecognizedCount == 1 ? "" : "s") omitted."
        }
        return result
    }

    static func parseListeners(_ data: Data) -> [ListenerRecord] {
        var records: [pid_t: ListenerRecord] = [:]
        var current: pid_t?
        let fields = data.split(separator: 0)
        for (index, bytes) in fields.enumerated() {
            // A timeout/size limit may cut a field in half. Do not promote its
            // truncated suffix into a valid-looking port number.
            if index == fields.count - 1, data.last != 0, bytes != Data([10])[...] { continue }
            var field = String(decoding: bytes, as: UTF8.self)
            while field.first == "\n" { field.removeFirst() }
            guard let prefix = field.first else { continue }
            let value = String(field.dropFirst())
            switch prefix {
            case "p":
                current = pid_t(value).flatMap { $0 > 1 ? $0 : nil }
                if let pid = current { records[pid] = ListenerRecord(pid: pid, command: "Runtime", endpoints: []) }
            case "c":
                if let pid = current { records[pid]?.command = value }
            case "n":
                if let pid = current, let endpoint = parseEndpoint(value), records[pid]?.endpoints.contains(endpoint) == false {
                    records[pid]?.endpoints.append(endpoint)
                }
            default: break
            }
        }
        return records.values.filter { !$0.endpoints.isEmpty }.sorted { $0.pid < $1.pid }
    }

    static func parseEndpoint(_ raw: String) -> ListeningEndpoint? {
        let address = raw.components(separatedBy: " (LISTEN)").first ?? raw
        guard let separator = address.lastIndex(of: ":"), let port = Int(address[address.index(after: separator)...]), (1...65535).contains(port) else { return nil }
        let host = String(address[..<separator])
        let local = host == "*" || host == "0.0.0.0" || host == "[::]" || host == "[::1]" || host == "::1" || host == "localhost" || host.hasPrefix("127.")
        return ListeningEndpoint(address: address, port: port, allowsLocalhost: local)
    }

    static func runtimeName(_ name: String) -> String? {
        let value = name.lowercased()
        switch value {
        case "node", "nodejs": return "Node.js"
        case "bun": return "Bun"
        case "deno": return "Deno"
        case "java": return "Java"
        case "go": return "Go"
        case "dotnet": return ".NET"
        case "swift": return "Swift"
        default:
            for (prefix, title) in [("python", "Python"), ("ruby", "Ruby"), ("php", "PHP")] {
                if value == prefix || (value.hasPrefix(prefix) && value.dropFirst(prefix.count).allSatisfy { $0.isNumber || $0 == "." }) { return title }
            }
            return nil
        }
    }

    static func group(_ processes: [RuntimeProjectProcess]) -> [RuntimeProjectGroup] {
        let grouped = Dictionary(grouping: processes) { $0.directory ?? "unresolved-\($0.pid)" }
        return grouped.values.map { RuntimeProjectGroup(directory: $0.first?.directory, processes: $0.sorted { $0.pid < $1.pid }) }
            .sorted { ($0.directory ?? "~\($0.id)") < ($1.directory ?? "~\($1.id)") }
    }

    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.hasPrefix("/") ? path : nil
    }

    private static func residentMemory(pid: pid_t) -> Int64? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size,
              task.pti_resident_size <= UInt64(Int64.max) else { return nil }
        return Int64(task.pti_resident_size)
    }

    struct CommandResult {
        var data = Data()
        var timedOut = false
        var truncated = false
        var exitCode: Int32?
        var error: String?
    }

    /// Both pipes are drained nonblocking, so output cannot deadlock the child.
    /// The timeout terminates only this exact spawned helper, never a discovered PID.
    static func runBounded(executable: String, arguments: [String], timeout: TimeInterval, byteLimit: Int) -> CommandResult {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        child.standardOutput = output; child.standardError = error
        var result = CommandResult()
        do { try child.run() } catch {
            result.error = error.localizedDescription
            return result
        }
        let stdout = output.fileHandleForReading.fileDescriptor
        let stderr = error.fileHandleForReading.fileDescriptor
        _ = fcntl(stdout, F_SETFL, fcntl(stdout, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderr, F_SETFL, fcntl(stderr, F_GETFL) | O_NONBLOCK)
        defer { try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close() }
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ fd: Int32, retain: Bool) {
            // Bound one drain too: a writer that continually produces output must
            // still return control to the deadline check.
            for _ in 0..<128 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if retain {
                    let remaining = max(0, byteLimit - result.data.count)
                    result.data.append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { result.truncated = true }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        while child.isRunning {
            drain(stdout, retain: true); drain(stderr, retain: false)
            if result.truncated || ProcessInfo.processInfo.systemUptime >= deadline {
                result.timedOut = !result.truncated
                child.terminate()
                let stopDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while child.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline { usleep(10_000) }
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
                break
            }
            usleep(10_000)
        }
        drain(stdout, retain: true); drain(stderr, retain: false)
        if !child.isRunning { result.exitCode = child.terminationStatus }
        return result
    }
}
