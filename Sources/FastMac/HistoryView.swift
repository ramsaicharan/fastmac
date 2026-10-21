import SwiftUI

/// Loads and holds saved scan history. Deliberately not `AppStore` — this view (and
/// this store) must work with nothing in the environment, per the file-ownership
/// rules for this feature.
@MainActor
final class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []

    func reload() { entries = History.loadAll() }
    func delete(_ entry: HistoryEntry) {
        History.delete(entry)
        entries.removeAll { $0.id == entry.id }
    }
}

struct HistoryView: View {
    @StateObject private var store = HistoryStore()
    @State private var compareBeforeID: String?
    @State private var compareAfterID: String?
    @AppStorage(MenuBarController.enabledKey) private var menuBarEnabled = true

    /// Starts a new live scan; the persisted summary cannot restore a disk map.
    var onScanAgain: (String) -> Void = { _ in }

    private var before: HistoryEntry? { store.entries.first { $0.id == compareBeforeID } }
    private var after: HistoryEntry? { store.entries.first { $0.id == compareAfterID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The latest 200 completed scan summaries are saved locally, including up to 40 child folders each. A summary cannot restore the full disk map. Scan Again starts a new scan; cancelled scans are not saved.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Toggle("Show menu-bar icon", isOn: $menuBarEnabled)
                    .toggleStyle(.switch)

                if store.entries.isEmpty {
                    emptyState
                } else {
                    trendSection
                    scansSection
                    compareSection
                }
            }
            .padding(18)
        }
        .onAppear { store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: History.didChange).receive(on: RunLoop.main)) { _ in store.reload() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No scan history yet").font(.headline)
            Text("Run a scan from the toolbar; its summary is saved here automatically once it completes.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    // MARK: trend

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trend").font(.headline)
            Text("Scanned-root size and free disk space at each completed scan. Each line uses its own scale; readings from different roots are not directly comparable.")
                .font(.caption).foregroundStyle(.secondary)
            TrendChart(entries: store.entries)
                .frame(height: 130)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 16) {
                legend(.blue, "Scanned size")
                legend(.green, "Free disk")
            }
        }
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: scan list

    private var scansSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scans").font(.headline).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(store.entries.reversed()) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.root).font(.callout).lineLimit(1)
                            Text("\(e.scannedAt.formatted(date: .abbreviated, time: .shortened)) · \(fmtCount(e.files)) files · \(fmtCount(e.dirs)) dirs")
                                .font(.caption2).foregroundStyle(.secondary)
                            if e.partial {
                                Text("Partial summary · \(e.errors ?? 0) unreadable items")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(fmt(e.bytes)).monospacedDigit().frame(width: 84, alignment: .trailing)
                        Button("Scan Again") { onScanAgain(e.root) }
                            .help("Run a new scan of this folder; the saved summary does not contain a full disk map")
                        Button(role: .destructive) { store.delete(e) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
    }

    // MARK: compare

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare two scans").font(.headline).padding(.top, 6)
            HStack(spacing: 12) {
                picker("Before", selection: $compareBeforeID)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                picker("After", selection: $compareAfterID)
            }
            if let before, let after {
                let rows = History.diff(before, after)
                if before.root != after.root {
                    Text("Choose two scans of the same folder to compare them.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("No comparable folders between these two summaries.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    diffTable(rows)
                    if !before.canInferMissingChildren || !after.canInferMissingChildren {
                        Text("A summary is partial or keeps only its largest folders. Missing rows are not treated as folders appearing or vanishing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Pick two saved scans to see which folders grew, shrank, appeared or vanished between them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func picker(_ label: String, selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose…").tag(String?.none)
            ForEach(store.entries) { e in
                Text("\(e.scannedAt.formatted(date: .abbreviated, time: .shortened)) — \(fmt(e.bytes))")
                    .tag(String?.some(e.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
    }

    private func diffTable(_ rows: [HistoryDiffRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.prefix(60)) { r in
                HStack {
                    Circle().fill(color(for: r.status)).frame(width: 7, height: 7)
                    Text(r.name).lineLimit(1)
                    Text(badge(for: r.status))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt(r.before)).monospacedDigit().font(.caption)
                        .foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(fmt(r.after)).monospacedDigit().frame(width: 72, alignment: .trailing)
                    Text((r.delta >= 0 ? "+" : "") + fmt(r.delta))
                        .monospacedDigit().font(.caption).foregroundStyle(color(for: r.status))
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private func color(for status: HistoryDiffRow.Status) -> Color {
        switch status {
        case .grew: .red; case .shrank: .green
        case .appeared: .orange; case .vanished: .blue; case .unchanged: .secondary
        }
    }
    private func badge(for status: HistoryDiffRow.Status) -> String {
        switch status {
        case .grew: "grew"; case .shrank: "shrank"
        case .appeared: "new"; case .vanished: "gone"; case .unchanged: "—"
        }
    }
}

/// Two overlaid lines — scanned bytes and free disk space — each independently
/// normalized to the chart height, in the same Canvas-drawn style as MemoryView's
/// history chart.
private struct TrendChart: View {
    let entries: [HistoryEntry]

    var body: some View {
        Canvas { ctx, size in
            guard entries.count > 1 else { return }
            let span = Double(entries.count - 1)
            func x(_ i: Int) -> Double { Double(i) / span * size.width }

            drawLine(ctx, size: size, x: x, values: entries.map { Optional(Double($0.bytes)) }, color: .blue)
            drawLine(ctx, size: size, x: x,
                     values: entries.map { $0.diskFreeAtScan.map(Double.init) }, color: .green)
        }
    }

    private func drawLine(_ ctx: GraphicsContext, size: CGSize, x: (Int) -> Double,
                          values: [Double?], color: Color) {
        let maxV = max(values.compactMap { $0 }.max() ?? 1, 1)
        let h = Double(size.height)
        func y(_ v: Double) -> Double { h - (v / maxV) * h * 0.92 - 4 }
        var p = Path()
        var connected = false
        for i in values.indices {
            guard let value = values[i] else { connected = false; continue }
            let pt = CGPoint(x: x(i), y: y(value))
            if connected { p.addLine(to: pt) } else { p.move(to: pt) }
            connected = true
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }
}
