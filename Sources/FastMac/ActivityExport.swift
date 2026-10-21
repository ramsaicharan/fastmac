import Foundation

extension ActivityRepository {
    /// A purpose-built interchange shape: internal identities and storage metadata
    /// never enter the encoder. App names are an explicit, default-off choice.
    static func json(_ samples: [ActivitySnapshot], includeAppNames: Bool = false) throws -> Data {
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let document = ActivityJSONDocument(includesAppNames: includeAppNames,
            samples: samples.map {
                ActivityJSONSample(snapshot: $0, timestamp: format.string(from: $0.sampledAt),
                                   includeAppNames: includeAppNames)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

private struct ActivityJSONDocument: Encodable {
    let schemaVersion = 1
    let timestampFormat = "ISO 8601 UTC with fractional seconds"
    let includesAppNames: Bool
    let units = [
        "cpu_whole_machine_percent": "percent",
        "memory_bytes": "bytes", "memory_total_bytes": "bytes", "swap_bytes": "bytes",
        "compressed_bytes": "bytes", "swap_in_bytes_per_second": "bytes/second",
        "swap_out_bytes_per_second": "bytes/second",
        "disk_free_bytes": "bytes", "disk_total_bytes": "bytes",
        "readable_process_disk_read_bytes_per_second": "bytes/second",
        "readable_process_disk_write_bytes_per_second": "bytes/second",
        "network_download_bytes_per_second": "bytes/second",
        "network_upload_bytes_per_second": "bytes/second",
        "battery_percent": "percent", "gpu_percent": "percent",
        "readable_processes": "count", "listed_processes": "count",
        "top_apps.cpu_one_core_percent": "percent", "top_apps.rss_bytes": "bytes",
        "top_apps.footprint_bytes": "bytes",
        "top_apps.process_count": "count"
    ]
    let conventions = [
        "cpu_whole_machine_percent": "100% means all logical cores are busy; range 0...100.",
        "top_apps.cpu_one_core_percent": "100% means one full core; multithreaded applications may exceed 100%.",
        "legacy_cpu": "App CPU is null for old records without validated Mach timebase conversion and a declared CPU scale.",
        "macos_memory_pressure": "macOS pressure signal, independent of estimated occupied memory.",
        "unavailable_values": "Unavailable or warming-up numeric readings are explicit JSON null; known zero remains zero."
    ]
    let scope = [
        "disk_io": "Sum of counter deltas for readable user-owned processes with a stable identity. New, exited and unreadable processes are omitted; this is not all volume I/O.",
        "network": "Default active physical Ethernet/Wi-Fi interface when available; otherwise active physical en* interfaces. Excludes VPN tunnels, virtual interfaces, loopback, bridges and peer-to-peer links. VPN physical transport includes overhead; no application attribution.",
        "network_scope": "Each sample identifies the physical interface scope used for its network reading.",
        "top_apps.rss_bytes": "Sum of resident process sizes; pages shared between helper processes may be counted more than once.",
        "top_apps.footprint_bytes": "Summed kernel memory accounting, including compressed allocations; not additional RAM on top of RSS. Unavailable if any member lacks a counter.",
        "swap_rates": "System VM page counter deltas, expressed as bytes before on-disk compression. Missing for old records or discontinuous intervals.",
        "top_apps": "At most the leading 12 application summaries, present only when app names are explicitly included."
    ]
    let samples: [ActivityJSONSample]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", timestampFormat = "timestamp_format"
        case includesAppNames = "includes_app_names"
        case units, conventions, scope, samples
    }
}

private struct ActivityJSONSample: Encodable {
    let snapshot: ActivitySnapshot
    let timestamp: String
    let includeAppNames: Bool

    enum CodingKeys: String, CodingKey {
        case timestamp
        case cpuWholeMachinePercent = "cpu_whole_machine_percent"
        case memoryBytes = "memory_bytes", memoryTotalBytes = "memory_total_bytes", swapBytes = "swap_bytes"
        case macOSMemoryPressure = "macos_memory_pressure"
        case compressed = "compressed_bytes", swapIn = "swap_in_bytes_per_second", swapOut = "swap_out_bytes_per_second"
        case diskFreeBytes = "disk_free_bytes", diskTotalBytes = "disk_total_bytes"
        case diskRead = "readable_process_disk_read_bytes_per_second"
        case diskWrite = "readable_process_disk_write_bytes_per_second"
        case download = "network_download_bytes_per_second", upload = "network_upload_bytes_per_second"
        case networkScope = "network_scope", batteryPercent = "battery_percent", gpuPercent = "gpu_percent"
        case thermalState = "thermal_state", readableProcesses = "readable_processes", listedProcesses = "listed_processes"
        case topApps = "top_apps"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeNullable(snapshot.cpuPercent, forKey: .cpuWholeMachinePercent)
        try container.encodeNullable(snapshot.memoryUsed, forKey: .memoryBytes)
        try container.encodeNullable(snapshot.memoryTotal, forKey: .memoryTotalBytes)
        try container.encodeNullable(snapshot.swapUsed, forKey: .swapBytes)
        try container.encodeNullable(snapshot.compressedBytes, forKey: .compressed)
        try container.encodeNullable(snapshot.swapInRate, forKey: .swapIn)
        try container.encodeNullable(snapshot.swapOutRate, forKey: .swapOut)
        try container.encode(snapshot.memoryPressure, forKey: .macOSMemoryPressure)
        try container.encodeNullable(snapshot.diskFree, forKey: .diskFreeBytes)
        try container.encodeNullable(snapshot.diskTotal, forKey: .diskTotalBytes)
        try container.encodeNullable(snapshot.diskReadRate, forKey: .diskRead)
        try container.encodeNullable(snapshot.diskWriteRate, forKey: .diskWrite)
        try container.encodeNullable(snapshot.networkDownloadRate, forKey: .download)
        try container.encodeNullable(snapshot.networkUploadRate, forKey: .upload)
        try container.encode(snapshot.networkScope, forKey: .networkScope)
        try container.encodeNullable(snapshot.batteryPercent, forKey: .batteryPercent)
        try container.encodeNullable(snapshot.gpuPercent, forKey: .gpuPercent)
        try container.encode(snapshot.thermalState, forKey: .thermalState)
        try container.encode(snapshot.readableProcesses, forKey: .readableProcesses)
        try container.encode(snapshot.listedProcesses, forKey: .listedProcesses)
        let apps = includeAppNames ? snapshot.apps.prefix(12).map {
            ActivityJSONApp($0, cpuKnown: snapshot.hasComparableAppCPU)
        } : []
        try container.encode(apps, forKey: .topApps)
    }
}

private struct ActivityJSONApp: Encodable {
    let name: String
    let processCount: Int
    let rssBytes: Int64?
    let footprintBytes: Int64?
    let cpuOneCorePercent: Double?

    init(_ snapshot: ActivityAppSnapshot, cpuKnown: Bool) {
        name = snapshot.name
        processCount = snapshot.processCount
        rssBytes = snapshot.rss
        footprintBytes = snapshot.footprint
        cpuOneCorePercent = cpuKnown ? snapshot.cpuPercent : nil
    }
    enum CodingKeys: String, CodingKey {
        case name, processCount = "process_count", rssBytes = "rss_bytes", cpuOneCorePercent = "cpu_one_core_percent"
        case footprintBytes = "footprint_bytes"
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(processCount, forKey: .processCount)
        try container.encodeNullable(rssBytes, forKey: .rssBytes)
        try container.encodeNullable(footprintBytes, forKey: .footprintBytes)
        try container.encodeNullable(cpuOneCorePercent, forKey: .cpuOneCorePercent)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<Value: Encodable>(_ value: Value?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}
