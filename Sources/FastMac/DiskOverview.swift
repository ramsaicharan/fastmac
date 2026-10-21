import Foundation

/// The startup disk as macOS accounts for it. A scan measures only what FastMac can
/// read; this fills in the rest, so every byte on the disk has a labelled place:
/// what was scanned, what macOS keeps on its own volumes, what could not be read,
/// and what is free.
struct DiskOverview: Equatable, Sendable {
    struct Volume: Equatable, Sendable {
        let name: String
        let role: String
        let used: Int64
    }

    var name: String
    var capacity: Int64
    var free: Int64
    /// Space macOS can reclaim on demand: caches, local snapshots, evictable iCloud files.
    var purgeable: Int64
    /// Per-volume use inside the startup container. Empty when diskutil is unavailable.
    var volumes: [Volume]

    var used: Int64 { max(0, capacity - free) }

    /// Preboot, Recovery, VM and Update. A whole-disk scan cannot walk these, and
    /// nothing in them is user data.
    var supportVolumesUsed: Int64 {
        volumes.filter { !Self.walkableRoles.contains($0.role) }.reduce(0) { $0 + $1.used }
    }

    private static let walkableRoles: Set<String> = ["System", "Data", ""]

    /// Splits the disk into labelled parts for a scan of `scannedPath` that measured
    /// `scannedBytes`. Parts always sum to `capacity`; nothing is double counted.
    func segments(scannedPath: String, scannedBytes: Int64) -> [DiskSegment] {
        let scanned = min(max(0, scannedBytes), used)
        var parts: [DiskSegment] = []
        if scannedPath == "/" {
            let support = min(supportVolumesUsed, used - scanned)
            let unread = max(0, used - scanned - support)
            parts.append(DiskSegment(kind: .scanned, bytes: scanned))
            if support > 0 { parts.append(DiskSegment(kind: .macOSVolumes, bytes: support)) }
            if unread > 0 { parts.append(DiskSegment(kind: .unread, bytes: unread)) }
        } else {
            parts.append(DiskSegment(kind: .scanned, bytes: scanned))
            let elsewhere = max(0, used - scanned)
            if elsewhere > 0 { parts.append(DiskSegment(kind: .elsewhere, bytes: elsewhere)) }
        }
        parts.append(DiskSegment(kind: .free, bytes: max(0, free)))
        return parts
    }
}

struct DiskSegment: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case scanned, macOSVolumes, unread, elsewhere, free
    }
    let kind: Kind
    let bytes: Int64
    var id: String { kind.rawValue }
}

enum DiskOverviewProbe {
    /// Reads capacity from the volume APIs and per-volume use from diskutil. Runs
    /// two short read-only commands, so call it off the main actor.
    static func read(path: String = "/") -> DiskOverview? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey,
        ]), let total = values.volumeTotalCapacity, total > 0,
           let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return DiskOverview(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            capacity: Int64(total),
            free: Int64(available),
            purgeable: max(0, important - Int64(available)),
            volumes: containerVolumes(path: path))
    }

    private static func containerVolumes(path: String) -> [DiskOverview.Volume] {
        let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", path], timeout: 8)
        guard info.status == 0,
              let plist = propertyList(info.stdout) as? [String: Any],
              let container = plist["APFSContainerReference"] as? String,
              container.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
        let list = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist", container], timeout: 8)
        guard list.status == 0 else { return [] }
        return volumes(fromAPFSList: list.stdout, container: container)
    }

    /// Pure parsing, separated so the self-check can feed it a fixture.
    static func volumes(fromAPFSList text: String, container: String) -> [DiskOverview.Volume] {
        guard let plist = propertyList(text) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]],
              let match = containers.first(where: { ($0["ContainerReference"] as? String) == container }),
              let volumes = match["Volumes"] as? [[String: Any]] else { return [] }
        return volumes.compactMap { volume in
            guard let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value, used >= 0 else { return nil }
            return DiskOverview.Volume(
                name: volume["Name"] as? String ?? "Volume",
                role: (volume["Roles"] as? [String])?.first ?? "",
                used: used)
        }
    }

    private static func propertyList(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
