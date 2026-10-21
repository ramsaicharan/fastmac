import SwiftUI

// A self-contained view: no @EnvironmentObject AppStore. The host wires staging through
// `onStage(paths, reason)`, matching the shape of AppStore.stage(_:sizes:reason:) used
// elsewhere in the app (ListViews.swift), so the call site is a one-line closure:
//
//   CategoriesView(onStage: { paths, reason in store.stage(paths, reason: reason) })
//
struct CategoriesView: View {
    var onStage: ([String], String) -> Void
    var scanRoot: String? = nil

    @State private var groups: [CategoryGroup] = []
    @State private var running = false
    @State private var lastElapsed: Double = 0
    @State private var lastRunAt: Date?
    @State private var staged: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if running && groups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Running category analyzers…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .onAppear { if groups.isEmpty { run() } }
    }

    // MARK: pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Category Analyzers").font(.headline)
                Text("iOS backups, Mail, browsers, dev caches, stale build output, old installers, VM disk images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = lastRunAt {
                Text("\(String(format: "%.2fs", lastElapsed)) · \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button { run() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(running)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Nothing scanned yet").font(.title3.weight(.medium))
            Text("Runs seven targeted analyzers that explain, not just size, the biggest hidden folders on a dev machine.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Run analyzers") { run() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let grandTotal = groups.reduce(Int64(0)) { $0 + $1.totalSize }
                HStack {
                    Text("\(fmt(grandTotal)) across \(groups.reduce(0) { $0 + $1.findings.count }) findings")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 2)

                ForEach(groups) { g in
                    CategoryGroupCard(group: g, staged: $staged, onStage: onStage)
                }
            }
            .padding(14)
        }
    }

    // MARK: run

    private func run() {
        guard !running else { return }
        running = true
        let root = scanRoot
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let result = Categories.sweep(root: root)
            let elapsed = Date().timeIntervalSince(t0)
            await MainActor.run {
                groups = result.sorted { $0.totalSize > $1.totalSize }
                lastElapsed = elapsed
                lastRunAt = Date()
                running = false
            }
        }
    }
}

// MARK: - Group card

private struct CategoryGroupCard: View {
    let group: CategoryGroup
    @Binding var staged: Set<String>
    let onStage: ([String], String) -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: group.icon).foregroundStyle(Color.accentColor).frame(width: 16)
                Text(group.name).font(.subheadline.weight(.semibold))
                if group.needsFullDiskAccess {
                    Text("needs Full Disk Access").font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18)).foregroundStyle(.orange)
                        .clipShape(Capsule())
                        .help("Could not read:\n" + group.unreadablePaths.joined(separator: "\n"))
                }
                Spacer()
                Text(fmt(group.totalSize)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text(group.explanation).font(.caption).foregroundStyle(.secondary)

            if group.findings.isEmpty {
                Text(group.needsFullDiskAccess
                     ? "Blocked without Full Disk Access — grant it in System Settings › Privacy & Security to measure this."
                     : "Nothing found here.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else if expanded {
                Divider().padding(.vertical, 2)
                ForEach(group.findings) { f in
                    CategoryFindingRow(finding: f, staged: $staged, onStage: onStage)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Finding row

private struct CategoryFindingRow: View {
    let finding: CategoryFinding
    @Binding var staged: Set<String>
    let onStage: ([String], String) -> Void

    private var isStaged: Bool { staged.contains(finding.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title).font(.caption.weight(.medium)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(finding.tier).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(finding.tier == "safe" ? Color.green.opacity(0.18)
                                                            : Color.orange.opacity(0.18))
                        .foregroundStyle(finding.tier == "safe" ? Color.green : Color.orange)
                        .clipShape(Capsule())
                    if let days = finding.ageDays {
                        Text("\(days)d").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(finding.detail).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                if let logical = finding.logicalSize {
                    Text("logical size \(fmt(logical))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(fmt(finding.size)).font(.caption).monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Button(isStaged ? "Staged" : "Stage") {
                onStage(finding.paths, "category: \(finding.title)")
                staged.insert(finding.id)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(isStaged)
        }
        .padding(.vertical, 4)
        .overlay(Divider(), alignment: .bottom)
        .contextMenu {
            Button("Reveal in Finder") {
                if let p = finding.paths.first {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            }
            ForEach(finding.paths, id: \.self) { p in
                Text(p).font(.caption)
            }
        }
    }
}
