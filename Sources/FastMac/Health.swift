import Foundation
import Combine
import Darwin

/// OS pressure levels, deliberately separate from percentages of occupied RAM.
enum HealthMemoryPressure: String, CaseIterable {
    case normal, warning, critical, unknown

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        case .unknown: "Unavailable"
        }
    }

    /// The sysctl exposes dispatch flags, not XNU's internal 0...4 level enum.
    static func fromKernelFlag(_ flag: Int32) -> HealthMemoryPressure {
        switch UInt32(bitPattern: flag) {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue): .normal
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue): .warning
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue): .critical
        default: .unknown
        }
    }
}

enum HealthStatus: String, CaseIterable {
    case comfortable, attention, critical, unknown

    var title: String {
        switch self {
        case .comfortable: "Comfortable"
        case .attention: "Review recommended"
        case .critical: "Needs attention"
        case .unknown: "Some readings unavailable"
        }
    }

    var icon: String {
        switch self {
        case .comfortable: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct HealthSample {
    var memory: MemorySample
    var memoryPressure: HealthMemoryPressure
    var diskFree: Int64
    var diskTotal: Int64
    var thermalState: ProcessInfo.ThermalState
    var sampledAt: Date = Date()
    var memoryAvailable: Bool = true
    var swapAvailable: Bool = true

    var diskAvailable: Bool { diskTotal > 0 && diskFree >= 0 && diskFree <= diskTotal }
    var diskFreeFraction: Double? {
        diskAvailable ? Double(diskFree) / Double(diskTotal) : nil
    }

    /// Headroom policies, not performance measurements. Both thresholds are shown in UI.
    var storageStatus: HealthStatus {
        guard let fraction = diskFreeFraction else { return .unknown }
        if diskFree < 5 * 1_073_741_824 || fraction < 0.05 { return .critical }
        if diskFree < 20 * 1_073_741_824 || fraction < 0.10 { return .attention }
        return .comfortable
    }

    var thermalTitle: String {
        switch thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unavailable"
        }
    }

    var thermalStatus: HealthStatus {
        switch thermalState {
        case .nominal: .comfortable
        case .fair, .serious: .attention
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    var memoryStatus: HealthStatus {
        switch memoryPressure {
        case .normal: memoryAvailable ? .comfortable : .unknown
        case .warning: .attention
        case .critical: .critical
        case .unknown: .unknown
        }
    }

    var status: HealthStatus {
        let signals = [storageStatus, thermalStatus, memoryStatus]
        if signals.contains(.critical) { return .critical }
        if signals.contains(.attention) { return .attention }
        if signals.contains(.unknown) { return .unknown }
        return .comfortable
    }

    var statusTitle: String { status.title }
    var statusDetail: String {
        var reasons: [String] = []
        if storageStatus == .critical || storageStatus == .attention {
            reasons.append("\(fmt(diskFree)) of storage is free")
        }
        if memoryStatus == .critical || memoryStatus == .attention {
            reasons.append("macOS reports \(memoryPressure.title.lowercased()) memory pressure")
        }
        if thermalStatus == .critical || thermalStatus == .attention {
            reasons.append("thermal state is \(thermalTitle.lowercased())")
        }
        if !reasons.isEmpty { return reasons.joined(separator: " · ") + "." }
        if status == .unknown {
            return "Available readings look comfortable. Unavailable readings are marked below."
        }
        return "Storage headroom, macOS memory pressure, and thermal state look comfortable."
    }
}

enum HealthProbe {
    /// Fixed-cost reads only. No process enumeration, shell command, or folder traversal.
    static func sample() -> HealthSample {
        let (memory, memoryAvailable, swapAvailable) = readMemory()
        let disk = MemoryProbe.diskFree()
        var flag: Int32 = 0
        var flagSize = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &flag, &flagSize, nil, 0) == 0
            && flagSize == MemoryLayout<Int32>.size
            ? HealthMemoryPressure.fromKernelFlag(flag) : .unknown
        return HealthSample(memory: memory, memoryPressure: pressure,
                            diskFree: disk.free, diskTotal: disk.total,
                            thermalState: ProcessInfo.processInfo.thermalState,
                            memoryAvailable: memoryAvailable, swapAvailable: swapAvailable)
    }

    private static func readMemory() -> (MemorySample, Bool, Bool) {
        var memory = MemorySample()
        memory.total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        // This monitor lives for days. Release the send right obtained by each read.
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = MemoryProbe.pageSize
            memory.free = Int64(info.free_count) * page
            memory.app = (Int64(info.active_count) + Int64(info.inactive_count)
                          + Int64(info.speculative_count)) * page
            memory.wired = Int64(info.wire_count) * page
            memory.compressor = Int64(info.compressor_page_count) * page
            memory.stored = Int64(info.total_uncompressed_pages_in_compressor) * page
            memory.fileBacked = Int64(info.external_page_count) * page
            memory.purgeable = Int64(info.purgeable_count) * page
            memory.swapInPages = info.swapins
            memory.swapOutPages = info.swapouts
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapAvailable = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            && swapSize == MemoryLayout<xsw_usage>.size
        if swapAvailable {
            memory.swapUsed = Int64(clamping: swap.xsu_used)
            memory.swapTotal = Int64(clamping: swap.xsu_total)
        }
        return (memory, result == KERN_SUCCESS && memory.total > 0, swapAvailable)
    }
}

struct HealthRecommendation: Identifiable {
    let id: String
    let title: String
    let detail: String
    let buttonTitle: String
    let icon: String
    let destination: ViewKind
    let urgency: HealthStatus
}

enum HealthRecommendations {
    /// Pure policy; generic inspections do not claim an issue before it is measured.
    static func make(sample: HealthSample?, stagedCount: Int = 0) -> [HealthRecommendation] {
        var result: [HealthRecommendation] = []
        if let sample, sample.memoryStatus == .attention || sample.memoryStatus == .critical {
            result.append(HealthRecommendation(
                id: "memory-pressure", title: "Reduce current memory demand",
                detail: "macOS reports \(sample.memoryPressure.title.lowercased()) pressure. Inspect memory use, then close apps or model sessions you no longer need.",
                buttonTitle: "Inspect memory", icon: "memorychip", destination: .memory,
                urgency: sample.memoryStatus))
        }
        if let sample, sample.thermalStatus == .attention || sample.thermalStatus == .critical {
            result.append(HealthRecommendation(
                id: "thermal", title: "Review work keeping your Mac warm",
                detail: "macOS reports a \(sample.thermalTitle.lowercased()) thermal state. Inspect CPU use and pause optional builds or model inference if needed.",
                buttonTitle: "Inspect performance", icon: "thermometer.medium", destination: .performance,
                urgency: sample.thermalStatus))
        }
        if let sample, sample.storageStatus == .attention || sample.storageStatus == .critical {
            result.append(HealthRecommendation(
                id: "storage-headroom", title: "Make room for apps and swap",
                detail: "\(fmt(sample.diskFree)) is free. Review measured cleanup candidates and keep the files and models you still use.",
                buttonTitle: "Find cleanup candidates", icon: "internaldrive", destination: .quick,
                urgency: sample.storageStatus))
        }
        if stagedCount > 0 {
            result.append(HealthRecommendation(
                id: "cleanup-queue", title: "Review your cleanup queue",
                detail: "\(stagedCount) item\(stagedCount == 1 ? " is" : "s are") queued. Review the exact paths before moving them to the Trash.",
                buttonTitle: "Review queue", icon: "tray.full", destination: .cleanup, urgency: .comfortable))
        }
        result.append(HealthRecommendation(
            id: "ai-storage", title: "Inspect AI app and model storage",
            detail: "Measure local models and selected AI app caches. Findings appear after you request the targeted scan.",
            buttonTitle: "Review AI storage", icon: "sparkles", destination: .aiStorage, urgency: .comfortable))
        result.append(HealthRecommendation(
            id: "startup", title: "Review what starts with your Mac",
            detail: "Inspect login and background items. Disable only the services you recognize and no longer need.",
            buttonTitle: "Review startup items", icon: "power", destination: .startup, urgency: .comfortable))
        if !result.contains(where: { $0.id == "thermal" }) {
            result.append(HealthRecommendation(
                id: "performance", title: "Find busy apps and helper processes",
                detail: "Open live performance when you feel a slowdown to measure CPU, memory, and process activity.",
                buttonTitle: "Inspect performance", icon: "speedometer", destination: .performance, urgency: .comfortable))
        }
        result.append(HealthRecommendation(
            id: "caches", title: "Review caches and build artifacts",
            detail: "Measure browser caches, developer caches, old installers, and other categories before choosing what to clean.",
            buttonTitle: "Review storage categories", icon: "square.stack.3d.up", destination: .categories, urgency: .comfortable))
        return result
    }
}

@MainActor
final class HealthMonitor: ObservableObject {
    nonisolated static let interval: TimeInterval = 15
    nonisolated static let tolerance: TimeInterval = 3

    @Published private(set) var sample: HealthSample?
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastProbeMilliseconds: Double = 0

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var lastPressureEvent: HealthMemoryPressure?
    private var generation = 0

    init() {}

    /// Render-check fixtures only: seeds visible state without sampling, creating
    /// a pressure listener, or installing a timer. Production uses init().
    init(fixtureSample: HealthSample?, isMonitoring: Bool) {
        self.sample = fixtureSample
        self.isMonitoring = isMonitoring
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        generation &+= 1
        let epoch = generation
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring, self.generation == epoch,
                      let events = self.pressureSource?.data else { return }
                if events.contains(.critical) { self.lastPressureEvent = .critical }
                else if events.contains(.warning) { self.lastPressureEvent = .warning }
                else if events.contains(.normal) { self.lastPressureEvent = .normal }
                self.refresh()
            }
        }
        source.resume()
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring, self.generation == epoch else { return }
                self.refresh()
            }
        }
        timer.tolerance = Self.tolerance
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        lastPressureEvent = nil
        isMonitoring = false
    }

    /// A manual refresh is valid while paused, without restarting the background timer.
    func refresh() {
        let start = ProcessInfo.processInfo.systemUptime
        var reading = HealthProbe.sample()
        if reading.memoryPressure == .unknown, let lastPressureEvent {
            reading.memoryPressure = lastPressureEvent
        }
        sample = reading
        lastProbeMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
    }
}
