import Foundation

enum ActivitySystemMetric: String, CaseIterable, Identifiable {
    case pressure = "Memory pressure", cpu = "Whole-machine CPU", memory = "Occupied memory"
    case swap = "Swap space used", compressed = "Compressed RAM"
    case swapIn = "Swap in", swapOut = "Swap out", diskFree = "Free storage"
    case diskRead = "Disk read", diskWrite = "Disk write"
    case download = "Network download", upload = "Network upload"
    case gpu = "GPU", battery = "Battery", thermal = "Thermal state"
    var id: String { rawValue }
    var unit: String {
        switch self {
        case .pressure, .thermal: "Level"
        case .cpu, .gpu, .battery: "%"
        case .memory, .swap, .compressed, .diskFree: "GiB"
        default: "MiB/s"
        }
    }
    var maximum: Double? {
        switch self { case .pressure: 2; case .thermal: 3; case .cpu, .gpu, .battery: 100; default: nil }
    }
    var explanation: String {
        switch self {
        case .pressure: "0 normal · 1 elevated · 2 critical. macOS pressure is more useful than occupied RAM alone. Unknown readings are gaps."
        case .thermal: "0 normal · 1 warm · 2 serious · 3 critical. Thermal state is the macOS signal, not a temperature measurement."
        case .swap: "Space occupied by swapped memory can remain high after pressure eases. Check swap-in and swap-out rates for current activity."
        case .swapIn, .swapOut: "VM page-counter deltas in bytes per second, before on-disk compression. Recording starts with this version; gaps need a fresh baseline."
        case .compressed: "Physical RAM occupied by the memory compressor. Recording starts with this version."
        case .memory: "Occupied VM pages include file-backed caches. This estimate differs from Activity Monitor’s Memory Used and is not memory pressure."
        case .diskRead, .diskWrite: "Totals for readable user-owned processes with stable identities; exited and inaccessible processes are excluded."
        case .download, .upload: "Traffic across the monitored physical network interface; no attribution to individual apps."
        case .gpu: "GPU utilization when the driver exposes a supported counter. Missing readings are gaps."
        case .cpu: "Whole-machine CPU: 100% means all logical cores are busy."
        case .battery: "Battery charge percentage while available."
        case .diskFree: "Free disk space available for apps, documents, and swap."
        }
    }
    func value(_ sample: ActivitySnapshot) -> Double? {
        func gib(_ value: Int64?) -> Double? { value.map { Double($0) / 1_073_741_824 } }
        func rate(_ value: Double?) -> Double? { value.map { $0 / 1_048_576 } }
        switch self {
        case .pressure: return ["normal": 0.0, "warning": 1.0, "critical": 2.0][sample.memoryPressure]
        case .thermal: return ["normal": 0.0, "nominal": 0.0, "warm": 1.0, "fair": 1.0,
                              "serious": 2.0, "hot": 2.0, "critical": 3.0][sample.thermalState.lowercased()]
        case .cpu: return sample.cpuPercent
        case .memory: return gib(sample.memoryUsed)
        case .swap: return gib(sample.swapUsed)
        case .compressed: return gib(sample.compressedBytes)
        case .swapIn: return rate(sample.swapInRate)
        case .swapOut: return rate(sample.swapOutRate)
        case .diskFree: return gib(sample.diskFree)
        case .diskRead: return rate(sample.diskReadRate)
        case .diskWrite: return rate(sample.diskWriteRate)
        case .download: return rate(sample.networkDownloadRate)
        case .upload: return rate(sample.networkUploadRate)
        case .gpu: return sample.gpuPercent
        case .battery: return sample.batteryPercent.map(Double.init)
        }
    }
}
