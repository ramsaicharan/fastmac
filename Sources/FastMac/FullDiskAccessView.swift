import SwiftUI
import AppKit

/// Walks the user through Full Disk Access: opens the exact Settings page, offers
/// FastMac's icon to drag into the list, and notices the moment access is granted.
struct FullDiskAccessSheet: View {
    let reason: FullDiskAccessPrompt
    /// Renders start from a known status and never poll.
    var initialStatus: FullDiskAccess.Status?
    var polls = true
    let onScan: () -> Void
    let onScanWithout: () -> Void
    let onClose: () -> Void

    @State private var status: FullDiskAccess.Status?
    @State private var openedSettings = false

    private var current: FullDiskAccess.Status? { status ?? initialStatus }
    private var granted: Bool { reason == .granted || current == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg - DS.Space.xxs) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                IconPlate(symbol: granted ? "checkmark.shield.fill" : "lock.shield",
                          tint: granted ? DS.Palette.good : DS.Palette.accent, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.dsTitle)
                    Text(message).font(.dsBody).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !granted { steps.transition(.opacity) }
            statusRow
            Text("FastMac only reads file sizes. Nothing is uploaded, and nothing is removed without your review.")
                .font(.dsCaption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(DS.Space.xl - DS.Space.xxs)
        .frame(width: 560)
        .animation(DS.Motion.standard, value: granted)
        .task { await watchForAccess() }
    }

    // MARK: Copy

    private var title: String {
        if granted { return "Full Disk Access is on" }
        return reason == .beforeScan ? "Scan everything on your Mac" : "Measure the folders macOS keeps private"
    }

    private var message: String {
        if granted {
            return reason == .beforeScan
                ? "FastMac can now measure every folder on your Mac."
                : "Rescan to include Mail, Messages, Safari and app data. They’ll move out of “Couldn’t read”."
        }
        return reason == .beforeScan
            ? "macOS keeps some folders private: Mail, Messages, Safari and app data. Without Full Disk Access, FastMac can’t measure them and they show up as “Couldn’t read”."
            : "Mail, Messages, Safari and app data couldn’t be measured in this scan. Allow Full Disk Access, then rescan to account for them."
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            step(1, "Open System Settings", "FastMac opens Privacy & Security → Full Disk Access for you.")
            HStack(alignment: .center, spacing: DS.Space.md) {
                step(2, "Turn on FastMac",
                     "Not in the list? Drag this icon into it, or click + and choose FastMac. macOS asks for your password.")
                appTile
            }
            step(3, "Choose “Quit & Reopen” if macOS asks", "FastMac reopens and offers to rescan.")
        }
        .padding(DS.Space.md)
        .background(DS.Palette.fill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    private func step(_ number: Int, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Text("\(number)")
                .font(.dsCaptionEmphasis).foregroundStyle(DS.Palette.accent)
                .frame(width: 22, height: 22)
                .background(DS.Palette.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.dsBodyEmphasis)
                Text(detail).font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The real app bundle, draggable straight into the Settings list.
    private var appTile: some View {
        VStack(spacing: DS.Space.xxs) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 44, height: 44)
            Text("FastMac").font(.dsCaptionEmphasis)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(DS.Palette.accent)
        }
        .padding(DS.Space.xs)
        .frame(width: 104)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            .strokeBorder(DS.Palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .help("Drag FastMac into the Full Disk Access list")
        .accessibilityLabel("FastMac app icon. Drag into the Full Disk Access list, or use Show in Finder.")
    }

    // MARK: Status and actions

    @ViewBuilder private var statusRow: some View {
        if granted {
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .font(.dsBodyEmphasis).foregroundStyle(DS.Palette.good)
        } else if openedSettings {
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to turn on FastMac…").font(.dsBody).foregroundStyle(.secondary)
            }
        } else if current == .unknown {
            Label("Access couldn’t be checked automatically. After turning it on, rescan to confirm.",
                  systemImage: "questionmark.circle")
                .font(.dsCaption).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.xs) {
            Spacer()
            if granted {
                Button("Later", action: onClose)
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(reason == .beforeScan ? "Scan Mac" : "Rescan Mac") {
                    UserDefaults.standard.removeObject(forKey: FullDiskAccess.pendingRescanKey)
                    onScan()
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            } else {
                if reason == .beforeScan {
                    Button("Scan Without It", action: onScanWithout)
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .help("Scan the folders macOS lets FastMac read. You won’t be asked again before scans.")
                } else {
                    Button("Not Now", action: onClose)
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                }
                Button {
                    UserDefaults.standard.set(true, forKey: FullDiskAccess.pendingRescanKey)
                    FullDiskAccess.openSettings()
                    openedSettings = true
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                .buttonStyle(DSButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Cheap file-open probes, once a second and a half, only while the sheet is open.
    private func watchForAccess() async {
        guard polls, reason != .granted else { return }
        while !Task.isCancelled {
            let now = FullDiskAccess.check()
            if now != status { status = now }
            if now == .granted {
                UserDefaults.standard.removeObject(forKey: FullDiskAccess.pendingRescanKey)
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}
