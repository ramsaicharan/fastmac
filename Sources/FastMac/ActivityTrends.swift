import Foundation

enum ActivityMemoryMetric: String, CaseIterable, Identifiable {
    case resident = "Resident memory", footprint = "Memory footprint"
    var id: String { rawValue }
    var short: String { self == .resident ? "RSS" : "footprint" }
    func bytes(_ app: ActivityAppSnapshot) -> Int64? { self == .resident ? app.rss : app.footprint }
    var explanation: String {
        switch self {
        case .resident: "RSS is summed resident memory; shared pages can be counted twice."
        case .footprint: "Footprint is summed kernel accounting, including compressed allocations. It is not additional RAM on top of RSS. Recording starts with this version."
        }
    }
}

/// Reserve room for both memory-heavy idle apps and short CPU-heavy work.
/// No additional process sweep or unbounded per-process log is needed.
enum ActivityAppSelection {
    static func leading(_ groups: [PerfAppGroup]) -> [PerfAppGroup] {
        let memory = groups.sorted {
            let a = max($0.rss, $0.footprint ?? 0), b = max($1.rss, $1.footprint ?? 0)
            return a == b ? $0.id < $1.id : a > b
        }
        let cpu = groups.filter(\.cpuAvailable).sorted {
            $0.cpuPercent == $1.cpuPercent ? $0.id < $1.id : $0.cpuPercent > $1.cpuPercent
        }
        var seen = Set<String>()
        return Array((Array(memory.prefix(6)) + Array(cpu.prefix(6)) + memory).filter {
            seen.insert($0.id).inserted
        }.prefix(12))
    }
}

enum ActivityMemoryRates {
    static func make(current: MemorySample, previous: MemorySample?, elapsed: Double?)
        -> (read: Double?, write: Double?) {
        guard let elapsed, elapsed.isFinite, elapsed > 0, elapsed <= 75, let previous else {
            return (nil, nil)
        }
        func rate(_ now: UInt64?, _ before: UInt64?) -> Double? {
            guard let now, let before, now >= before else { return nil }
            return Double(now - before) * Double(MemoryProbe.pageSize) / elapsed
        }
        return (rate(current.swapInPages, previous.swapInPages),
                rate(current.swapOutPages, previous.swapOutPages))
    }
}

struct ActivityAppTrend: Identifiable {
    let id: String
    let name: String
    let observations: Int
    let memoryObservations: Int
    let averageBytes: Int64?
    let peakBytes: Int64?
    let peakMemorySample: ActivitySnapshot?
    let latestBytes: Int64?
    let lastSeen: Date
    let averageCPU: Double?
    let peakCPU: Double?
    let cpuObservations: Int
    let peakProcesses: Int
    // End-to-end differences cross restarts and missing samples. They are not a
    // growth rate or evidence of a leak, so deliberately do not present one.
}

enum ActivityTrends {
    enum Sort: String, CaseIterable, Identifiable {
        case peakMemory = "Peak memory", averageMemory = "Average memory", peakCPU = "Peak CPU"
        var id: String { rawValue }
    }

    static func apps(in samples: [ActivitySnapshot], sortedBy sort: Sort = .peakMemory,
                     memoryMetric: ActivityMemoryMetric = .resident) -> [ActivityAppTrend] {
        var entries: [String: [(ActivitySnapshot, ActivityAppSnapshot)]] = [:]
        for sample in samples.sorted(by: { $0.sampledAt < $1.sampledAt }) {
            var seen = Set<String>()
            for app in sample.apps where seen.insert(app.id).inserted {
                entries[app.id, default: []].append((sample, app))
            }
        }
        return entries.compactMap { id, values -> ActivityAppTrend? in
            guard let last = values.last else { return nil }
            let memory = values.filter { (memoryMetric.bytes($0.1) ?? -1) >= 0 }
            let peak = memory.max { (memoryMetric.bytes($0.1) ?? 0) < (memoryMetric.bytes($1.1) ?? 0) }
            let cpu = values.compactMap { sample, app -> Double? in
                guard sample.hasComparableAppCPU, let cpu = app.cpuPercent,
                      cpu.isFinite, cpu >= 0 else { return nil }
                return cpu
            }
            let averageMemory = memory.isEmpty ? nil : Int64(clamping: Int64(
                min(Double(Int64.max - 1024), memory.reduce(0.0) {
                    $0 + Double(memoryMetric.bytes($1.1) ?? 0)
                } / Double(memory.count))))
            return ActivityAppTrend(id: id, name: last.1.name, observations: values.count,
                memoryObservations: memory.count, averageBytes: averageMemory,
                peakBytes: peak.flatMap { memoryMetric.bytes($0.1) },
                peakMemorySample: peak?.0, latestBytes: memoryMetric.bytes(last.1), lastSeen: last.0.sampledAt,
                averageCPU: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
                peakCPU: cpu.max(), cpuObservations: cpu.count,
                peakProcesses: values.map { $0.1.processCount }.max() ?? 0)
        }.sorted { lhs, rhs in
            let a: Double, b: Double
            switch sort {
            case .peakMemory: a = Double(lhs.peakBytes ?? -1); b = Double(rhs.peakBytes ?? -1)
            case .averageMemory: a = Double(lhs.averageBytes ?? -1); b = Double(rhs.averageBytes ?? -1)
            case .peakCPU: a = lhs.peakCPU ?? -1; b = rhs.peakCPU ?? -1
            }
            return a == b ? lhs.id < rhs.id : a > b
        }
    }

    static func cpu(for appID: String, in sample: ActivitySnapshot) -> Double? {
        guard sample.hasComparableAppCPU else { return nil }
        return sample.apps.first { $0.id == appID }?.cpuPercent
    }
}

/// Shared chart segmentation: missing readings, sleep, and sampler restarts are
/// gaps. A missing top-app entry never becomes a zero-valued measurement.
struct ActivityTrendPoint: Identifiable {
    let sample: ActivitySnapshot
    let value: Double
    let segment: Int
    var id: String { sample.id }

    static func make(_ samples: [ActivitySnapshot], hours: Double,
                     value: (ActivitySnapshot) -> Double?) -> [ActivityTrendPoint] {
        let maximumGap = max(120, hours * 3600 / 1499 * 2.5)
        var segment = 0
        var previous: ActivitySnapshot?
        return samples.compactMap { sample in
            defer { previous = sample }
            if let last = previous, last.sessionID != sample.sessionID
                || sample.sampledAt.timeIntervalSince(last.sampledAt) > maximumGap { segment += 1 }
            guard let reading = value(sample), reading.isFinite, reading >= 0 else {
                segment += 1; return nil
            }
            return ActivityTrendPoint(sample: sample, value: reading, segment: segment)
        }
    }
}
