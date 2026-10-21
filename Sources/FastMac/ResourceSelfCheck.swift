import Foundation
import Darwin
import IOKit.ps

enum ResourceSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        func counters(_ seconds: TimeInterval, _ received: UInt64, _ sent: UInt64, name: String = "en0") -> NetworkCounterSnapshot {
            NetworkCounterSnapshot(at: origin.addingTimeInterval(seconds), uptime: 500 + seconds,
                                   counters: [NetworkInterfaceCounter(name: name, received: received, sent: sent)])
        }
        let first = counters(0, 1_000, 500), second = counters(2, 3_000, 1_500)
        let rate = ResourceProbe.networkRate(current: second, previous: first)
        check("network rates derive from byte deltas and monotonic elapsed time", rate.downloadBytesPerSecond == 1_000 && rate.uploadBytesPerSecond == 500)
        check("network baseline is unavailable rather than zero", ResourceProbe.networkRate(current: first, previous: nil).downloadBytesPerSecond == nil)
        check("stable zero traffic is measured as zero", ResourceProbe.networkRate(current: counters(2, 1_000, 500), previous: first).downloadBytesPerSecond == 0)
        check("network counter reset discards interval", ResourceProbe.networkRate(current: counters(2, 100, 1_500), previous: first).downloadBytesPerSecond == nil)
        check("network interface change discards interval", ResourceProbe.networkRate(current: counters(2, 3_000, 1_500, name: "en1"), previous: first).downloadBytesPerSecond == nil)
        check("long sleep or monitoring gap discards interval", ResourceProbe.networkRate(current: counters(120, 3_000, 1_500), previous: first).downloadBytesPerSecond == nil)
        var backwards = second; backwards.at = origin.addingTimeInterval(-3)
        check("wall clock moving backwards discards interval", ResourceProbe.networkRate(current: backwards, previous: first).downloadBytesPerSecond == nil)
        var unavailable = second; unavailable.counters = []; unavailable.unavailableReason = "Unavailable"
        check("missing interfaces have nil counters and rates", unavailable.downloadBytes == nil && ResourceProbe.networkRate(current: unavailable, previous: first).downloadBytesPerSecond == nil)
        let active = UInt32(IFF_UP | IFF_RUNNING)
        check("physical filter rejects VPN, AWDL, loopback and bridge", ["utun4", "awdl0", "lo0", "bridge0", "en", "enfoo"].allSatisfy { !ResourceProbe.isPhysicalInterface(name: $0, flags: active) })
        check("physical filter accepts active en and rejects down en", ResourceProbe.isPhysicalInterface(name: "en0", flags: active) && !ResourceProbe.isPhysicalInterface(name: "en0", flags: 0))
        let interfaces = [NetworkInterfaceCounter(name: "en0", received: 1, sent: 1), NetworkInterfaceCounter(name: "en1", received: 1, sent: 1)]
        check("default physical interface avoids aggregation", ResourceProbe.selectInterfaces(interfaces, primary: "en1").map(\.name) == ["en1"])
        check("VPN default reports only available physical transport", ResourceProbe.selectInterfaces(interfaces, primary: "utun0").map(\.name) == ["en0", "en1"])
        var multiFirst = first, multiSecond = second
        multiFirst.counters = [NetworkInterfaceCounter(name: "en0", received: 2_000, sent: 100), NetworkInterfaceCounter(name: "en1", received: 100, sent: 100)]
        multiSecond.counters = [NetworkInterfaceCounter(name: "en0", received: 100, sent: 200), NetworkInterfaceCounter(name: "en1", received: 9_000, sent: 200)]
        check("one interface reset cannot hide behind another's traffic", ResourceProbe.networkRate(current: multiSecond, previous: multiFirst).downloadBytesPerSecond == nil)

        let noBattery = ResourceProbe.parseBattery(powerSource: nil, registry: ["CycleCount": 2])
        check("desktop battery absence remains explicit", noBattery.present == false && noBattery.percent == nil && noBattery.cycleCount == nil)
        check("not-present power source is not a laptop battery", ResourceProbe.parseBattery(powerSource: [kIOPSIsPresentKey: false], registry: nil).present == false)
        let source: [String: Any] = [kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80, kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        let battery = ResourceProbe.parseBattery(powerSource: source, registry: ["CycleCount": 321, "DesignCapacity": 5_000, "AppleRawMaxCapacity": 4_000])
        check("battery charge scales documented capacities", battery.percent == 50 && battery.isCharging == true && battery.isOnBattery == false)
        check("battery raw capacity estimate and cycles are typed", battery.healthPercent == 80 && battery.cycleCount == 321)
        let missing = ResourceProbe.parseBattery(powerSource: [:], registry: ["MaxCapacity": 100, "DesignCapacity": 5_000, "Temperature": 3_000])
        check("percent-scaled max capacity is never interpreted as battery health", missing.healthPercent == nil)
        check("unvalidated temperature units stay unavailable", missing.temperatureCelsius == nil)
        check("missing battery fields remain nil", missing.percent == nil && missing.cycleCount == nil && missing.isCharging == nil)
        check("booleans and strings never become numeric readings", ResourceProbe.number(true) == nil && ResourceProbe.number("82") == nil)
        check("GPU missing or malformed counters stay unavailable", ResourceProbe.parseGPUUtilization([:]) == nil && ResourceProbe.parseGPUUtilization(["Device Utilization %": "23"]) == nil && ResourceProbe.parseGPUUtilization(["Device Utilization %": 101]) == nil)
        check("GPU genuine zero and bounded numeric values are supported", ResourceProbe.parseGPUUtilization(["Device Utilization %": 0]) == 0 && ResourceProbe.parseGPUUtilization(["Device Utilization %": 23.5]) == 23.5)

        let fixture = Data("p42\0cnode\0\nf4\0n127.0.0.1:3000\0\nf5\0n[::1]:3000\0\np43\0cpython3\0\nf7\0n*:8000\0\n".utf8)
        let listeners = ProjectProbe.parseListeners(fixture)
        check("lsof machine parser preserves PID command and endpoint records", listeners.count == 2 && listeners.first?.pid == 42 && listeners.first?.command == "node" && listeners.first?.endpoints.count == 2)
        check("lsof duplicate endpoints collapse", ProjectProbe.parseListeners(Data("p42\0cnode\0n*:3000\0n*:3000\0".utf8)).first?.endpoints.count == 1)
        check("truncated endpoint fields are discarded", ProjectProbe.parseListeners(Data("p42\0cnode\0n*:30".utf8)).isEmpty)
        check("IPv6 loopback and wildcard offer explicit localhost actions", ProjectProbe.parseEndpoint("[::1]:3000")?.localhostURL?.absoluteString == "http://localhost:3000" && ProjectProbe.parseEndpoint("*:8080")?.allowsLocalhost == true)
        check("nonloopback bind has no misleading localhost action", ProjectProbe.parseEndpoint("192.168.1.2:3000")?.localhostURL == nil)
        check("invalid ports are rejected", ["*:0", "*:65536", "*:oops", "3000"].allSatisfy { ProjectProbe.parseEndpoint($0) == nil })
        check("known runtime versions are recognized without broad prefix guesses", ProjectProbe.runtimeName("python3.12") == "Python" && ProjectProbe.runtimeName("python-unrelated") == nil && ProjectProbe.runtimeName("node") == "Node.js")
        let a = RuntimeProjectProcess(pid: 42, runtime: "Node.js", command: "node", directory: "/fixture/project", endpoints: [], identity: nil)
        let b = RuntimeProjectProcess(pid: 43, runtime: "Python", command: "python3", directory: "/fixture/project", endpoints: [], identity: nil)
        let c = RuntimeProjectProcess(pid: 44, runtime: "Node.js", command: "node", directory: nil, endpoints: [], identity: nil)
        let d = RuntimeProjectProcess(pid: 45, runtime: "Node.js", command: "node", directory: nil, endpoints: [], identity: nil)
        let groups = ProjectProbe.group([a, b, c, d])
        check("verified cwd groups runtimes while unknown cwd remains separate", groups.count == 3 && groups.first(where: { $0.directory == "/fixture/project" })?.processes.count == 2)
        check("missing process identity disables stop", !a.canStop && !c.canStop)
        var measured = a; measured.residentBytes = 10_000
        var measuredOther = b; measuredOther.residentBytes = 20_000
        let partial = RuntimeProjectGroup(directory: "/fixture/project", processes: [measured, b])
        check("project RSS sums only available readings and reports partial coverage", partial.residentBytes == 10_000 && partial.residentCoverage == 1)
        check("project RSS adds measured process snapshots", RuntimeProjectGroup(directory: "/fixture/project", processes: [measured, measuredOther]).residentBytes == 30_000)
        check("project missing RSS remains unavailable instead of zero", RuntimeProjectGroup(directory: nil, processes: [c, d]).residentBytes == nil)
        var zero = a; zero.residentBytes = 0
        check("genuine zero RSS remains a measured zero", RuntimeProjectGroup(directory: nil, processes: [zero]).residentBytes == 0)
        let aged = RuntimeProjectProcess(pid: 42, runtime: "Node.js", command: "node", directory: "/fixture/project", endpoints: [],
                                         identity: ProcessIdentity(pid: 42, uid: getuid(), startedSeconds: 1_000, startedMicroseconds: 250_000, path: "/fixture/node"))
        check("project age uses captured start seconds and microseconds", aged.age(at: Date(timeIntervalSince1970: 1_030.5)) == 30.25)
        check("project missing or future start time has no invented age", a.age(at: origin) == nil && aged.age(at: Date(timeIntervalSince1970: 999)) == nil)

        let start = ProcessInfo.processInfo.systemUptime
        let timeout = ProjectProbe.runBounded(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05, byteLimit: 1_024)
        check("discovery helper timeout is bounded", timeout.timedOut && ProcessInfo.processInfo.systemUptime - start < 1)
        let bounded = ProjectProbe.runBounded(executable: "/usr/bin/yes", arguments: ["fixture"], timeout: 0.2, byteLimit: 128)
        check("discovery output budget stops an unbounded helper", bounded.truncated && bounded.data.count <= 128)

        // Live reads stay limited to non-identifying system counters. Do not run
        // ProjectProbe.discover here: fixture tests must not enumerate local cwd.
        let probeStart = ProcessInfo.processInfo.systemUptime
        let liveNetwork = ResourceProbe.networkCounters()
        let liveBattery = ResourceProbe.battery()
        let liveGPU = ResourceProbe.gpu()
        check("live resource probes finish within a lightweight sampling budget", ProcessInfo.processInfo.systemUptime - probeStart < 1)
        check("live network counter absence has an explanation", !liveNetwork.counters.isEmpty || liveNetwork.unavailableReason != nil)
        check("live battery charge is optional and bounded", liveBattery.percent.map { (0...100).contains($0) } ?? true)
        check("live GPU utilization is optional and bounded", liveGPU.utilizationPercent.map { $0 >= 0 && $0 <= 100 } ?? true)
        return lines
    }
}
