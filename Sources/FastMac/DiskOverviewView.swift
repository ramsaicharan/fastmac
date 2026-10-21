import SwiftUI

/// Shows a scan in the context of the whole startup disk: one bar that always adds
/// up to the disk's capacity, and a legend naming every part of it.
struct DiskOverviewBar: View {
    let result: ScanResult
    let disk: DiskOverview
    var onScanMac: () -> Void
    var onRequestAccess: () -> Void = {}
    @State private var fullDiskAccess: FullDiskAccess.Status?

    private var segments: [DiskSegment] {
        disk.segments(scannedPath: result.root.path, scannedBytes: result.bytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                Text(disk.name).font(.dsBodyEmphasis)
                Text("\(fmt(disk.used)) used of \(fmt(disk.capacity))")
                    .font(.dsCaption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                action
            }
            bar
            legend
        }
        .padding(.horizontal, 14).padding(.vertical, DS.Space.sm - 2)
        .task { fullDiskAccess = FullDiskAccess.check() }
    }

    @ViewBuilder private var action: some View {
        if !result.isWholeDisk {
            Button { onScanMac() } label: { Label("Scan entire Mac", systemImage: "internaldrive") }
                .buttonStyle(DSButtonStyle(kind: .quiet, compact: true))
                .help("Measure every folder on \(disk.name), not just this one")
        } else if fullDiskAccess != .granted && segments.contains(where: { $0.kind == .unread }) {
            Button { onRequestAccess() } label: {
                Label("Allow Full Disk Access…", systemImage: "lock.open")
            }
            .buttonStyle(DSButtonStyle(kind: .quiet, compact: true))
            .help("Measure Mail, Messages, Safari and app data too. FastMac walks you through it.")
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(color(segment.kind))
                        .frame(width: max(segment.bytes > 0 ? 2 : 0,
                                          proxy.size.width * fraction(segment.bytes)))
                        .help("\(title(segment.kind)): \(fmt(segment.bytes))")
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\(title($0.kind)) \(fmt($0.bytes))" }.joined(separator: ", "))
    }

    private var legend: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(segments) { segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(color(segment.kind)).frame(width: 8, height: 8)
                    Text(title(segment.kind)).foregroundStyle(.secondary)
                    Text(fmt(segment.bytes)).monospacedDigit()
                    if let info = info(segment.kind) { InfoButton(info) }
                }
                .font(.dsCaption)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    private func fraction(_ bytes: Int64) -> CGFloat {
        disk.capacity > 0 ? CGFloat(Double(bytes) / Double(disk.capacity)) : 0
    }

    private func title(_ kind: DiskSegment.Kind) -> String {
        switch kind {
        case .scanned:
            result.isWholeDisk ? "Scanned"
                : result.root.path == NSHomeDirectory() ? "Home folder" : "This folder"
        case .macOSVolumes: "macOS volumes"
        case .unread: "Couldn’t read"
        case .elsewhere: "Rest of disk"
        case .free: "Free"
        }
    }

    private func color(_ kind: DiskSegment.Kind) -> Color {
        switch kind {
        case .scanned: DS.Palette.accent
        case .elsewhere: DS.Palette.accent.opacity(0.32)
        case .macOSVolumes: Color.gray.opacity(0.55)
        case .unread: DS.Palette.warning.opacity(0.6)
        case .free: DS.Palette.fillStrong
        }
    }

    private func info(_ kind: DiskSegment.Kind) -> String? {
        switch kind {
        case .scanned:
            result.errors > 0
                ? "\(fmtCount(result.errors)) item\(result.errors == 1 ? "" : "s") could not be opened during this scan. Their size is part of “Couldn’t read”."
                : nil
        case .macOSVolumes:
            "Preboot, Recovery, VM (swap and sleep image) and Update volumes. macOS manages these itself; nothing in them should be deleted by hand."
        case .unread:
            "Used space FastMac could not measure: folders protected by macOS privacy controls"
                + (fullDiskAccess == .granted ? "" : " (allow Full Disk Access to include them)")
                + ", admin-only system data, the Spotlight index, document versions and local snapshots."
                + (disk.purgeable > 0 ? " macOS can reclaim about \(fmt(disk.purgeable)) of purgeable space on its own." : "")
        case .elsewhere:
            "Used space outside this folder: apps, system files and other users’ data. Scan entire Mac to see all of it."
        case .free:
            disk.purgeable > 0
                ? "Plus about \(fmt(disk.purgeable)) that macOS can free automatically when space runs low."
                : nil
        }
    }
}
