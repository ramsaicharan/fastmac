import SwiftUI
import AppKit

// MARK: - System Maintenance
//
// Self-contained: no AppStore in the environment. Owns its own loading state and talks
// directly to MaintenanceService. See HANDOFF.md for the ViewKind case + sidebar entry
// another agent should add to host this inside the main window.

struct MaintenanceView: View {
    var automaticallyLoads = true

    private static let copyText1 = "\"Purgeable\" is the gap between free space today and what macOS "
                    + "could reclaim under storage pressure — the local Time Machine "
                    + "snapshots below, evictable iCloud files, and some system caches. "
                    + "It is not a folder you can open and empty, and FastMac cannot "
                    + "reclaim it directly for you; macOS releases it on its own when "
                    + "the disk actually gets tight. Thinning snapshots below is the one "
                    + "part of it you can act on directly."
    private static let copyText2 = "These are the *local cache* of your Time Machine backups — APFS "
                + "snapshots macOS keeps on this Mac's own disk so you can browse recent "
                + "history even when the backup disk isn't connected. They are invisible "
                + "in Finder, routinely add up to tens or hundreds of gigabytes, and show "
                + "up in \"purgeable\" space above. Thinning one here does not touch your "
                + "actual backup on the backup disk — only this local convenience copy."
    private static let copyText3 = "Each item below is opt-in and explained before you run it. Anything "
                + "that needs admin rights is shown as a command to run yourself in "
                + "Terminal — FastMac never asks for your password."
    @State private var space: VolumeSpace?
    @State private var snapshots: [LocalSnapshot] = []
    @State private var loadingSnapshots = true
    @State private var actions: [MaintAction] = []
    /// Computed once per load — several verdicts shell out (Spotlight status, cache
    /// sizing), so the view body must never call `action.verdict()` itself; a SwiftUI
    /// body can be re-evaluated many times per second and none of that belongs on it.
    @State private var verdicts: [String: MaintVerdict] = [:]
    @State private var loadingActions = true
    @State private var confirmSnapshot: LocalSnapshot?
    @State private var busyActionID: String?
    @State private var resultMessage: String?
    @State private var copiedCommandID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                purgeableSection
                Divider()
                snapshotsSection
                Divider()
                actionsSection
            }
            .padding(18)
        }
        .task { if automaticallyLoads { load() } }
        .alert("Thin this local snapshot?", isPresented: Binding(
            get: { confirmSnapshot != nil }, set: { if !$0 { confirmSnapshot = nil } })) {
            Button("Cancel", role: .cancel) { confirmSnapshot = nil }
            Button("Thin Snapshot", role: .destructive) { performDelete() }
        } message: {
            Text("This deletes the local cache of a Time Machine backup, not the backup "
                + "itself — your actual backup disk is untouched. Deleted with:\n\n"
                + "tmutil deletelocalsnapshots \(confirmSnapshot?.dateToken ?? "")")
        }
        .alert("Maintenance", isPresented: Binding(
            get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { resultMessage = nil }
        } message: { Text(resultMessage ?? "") }
    }

    private func load() {
        space = PurgeableSpace.info(volume: "/")
        loadingSnapshots = true
        loadingActions = true
        Task.detached(priority: .utility) {
            let list = TimeMachineSnapshots.listAll()
            await MainActor.run {
                snapshots = list
                loadingSnapshots = false
            }
        }
        loadActions()
    }

    /// Off the main thread: `MaintenanceService.actions()` and every verdict closure
    /// may shell out (mdutil, getconf) or stat the filesystem.
    private func loadActions() {
        Task.detached(priority: .utility) {
            let list = MaintenanceService.actions()
            let v = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.verdict()) })
            await MainActor.run {
                actions = list
                verdicts = v
                loadingActions = false
            }
        }
    }

    // MARK: Purgeable space

    @ViewBuilder private var purgeableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Purgeable Space").font(.title3.weight(.semibold))
            if let space {
                HStack(spacing: 22) {
                    stat("Volume total", fmt(space.totalBytes))
                    stat("Free now", fmt(space.availableBytes))
                    stat("Purgeable", fmt(space.purgeableBytes), tint: .orange)
                }
                Text(Self.copyText1)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Could not read volume space for /.").foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Local Time Machine snapshots

    @ViewBuilder private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time Machine Local Snapshots").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { load() }.controlSize(.small)
            }
            Text(Self.copyText2)
                .font(.caption).foregroundStyle(.secondary)

            if loadingSnapshots {
                ProgressView().padding(.vertical, 10)
            } else if snapshots.isEmpty {
                Text("No local snapshots right now — nothing to thin. (Checked "
                    + TimeMachineSnapshots.candidateVolumes().joined(separator: " and ") + ".)")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                Table(snapshots) {
                    TableColumn("Date") { s in Text(s.displayDate) }
                    TableColumn("Volume") { s in Text(s.volume).font(.caption.monospaced()) }
                    TableColumn("") { s in
                        Button("Thin…") { confirmSnapshot = s }
                            .buttonStyle(.bordered).controlSize(.small)
                    }.width(70)
                }
                .frame(minHeight: min(CGFloat(snapshots.count) * 28 + 30, 260))
            }
        }
    }

    private func performDelete() {
        guard let s = confirmSnapshot else { return }
        confirmSnapshot = nil
        Task.detached(priority: .userInitiated) {
            let r = TimeMachineSnapshots.delete(s)
            await MainActor.run {
                if r.status == 0 {
                    snapshots.removeAll { $0.id == s.id }
                    resultMessage = "Snapshot from \(s.displayDate) thinned."
                } else {
                    resultMessage = "Could not thin that snapshot: "
                        + (r.stderr.isEmpty ? "exit code \(r.status)" : r.stderr)
                }
            }
        }
    }

    // MARK: Safe maintenance actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Safe Maintenance Actions").font(.title3.weight(.semibold))
            Text(Self.copyText3)
                .font(.caption).foregroundStyle(.secondary)

            if loadingActions {
                ProgressView().padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(actions) { action in
                        actionRow(action, verdicts[action.id]
                            ?? MaintVerdict(headline: "—", worthDoing: false))
                        if action.id != actions.last?.id { Divider() }
                    }
                }
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func actionRow(_ action: MaintAction, _ verdict: MaintVerdict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.body.weight(.medium))
                    Text(action.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verdict.headline).font(.caption.weight(.semibold))
                        .foregroundStyle(verdict.worthDoing ? .green : .secondary)
                    if let perform = action.perform {
                        Button(busyActionID == action.id ? "Running…" : "Run") {
                            run(action, perform)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(busyActionID != nil || !verdict.worthDoing)
                    }
                }
            }
            if let cmd = action.adminCommand {
                HStack {
                    Text(cmd).font(.caption.monospaced())
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .textSelection(.enabled)
                    Button(copiedCommandID == action.id ? "Copied" : "Copy") {
                        copyToPasteboard(cmd, id: action.id)
                    }.controlSize(.small)
                }
                Text("Needs admin rights — FastMac deliberately does not run this. "
                    + "Paste it into Terminal yourself.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    private func copyToPasteboard(_ text: String, id: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedCommandID = id
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedCommandID == id { copiedCommandID = nil }
        }
    }

    private func run(_ action: MaintAction, _ perform: @escaping () -> Shell.Result) {
        guard busyActionID == nil else { return }
        busyActionID = action.id
        Task.detached(priority: .userInitiated) {
            let r = perform()
            await MainActor.run {
                busyActionID = nil
                resultMessage = r.status == 0
                    ? "\(action.title): done."
                    : "\(action.title) reported a problem: "
                        + (r.stderr.isEmpty ? "exit code \(r.status)" : r.stderr)
            }
            // Re-measure off the main thread — a completed action (e.g. clearing the
            // QuickLook cache) changes what the *next* verdict should say.
            let list = MaintenanceService.actions()
            let v = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.verdict()) })
            await MainActor.run { actions = list; verdicts = v }
        }
    }
}
