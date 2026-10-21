import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var health: HealthMonitor
    @State private var pendingQuit: ProcGroup?
    @State private var quitResult: QuitResult?
    @State private var quittingGroupID: String?

    private struct QuitResult: Identifiable { let id = UUID(); let title: String; let body: String }

    private var levelColor: Color {
        (health.sample?.memoryStatus ?? .unknown).color
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RAM metrics use macOS kernel and process APIs; opening this tab does not scan your home folder or read the disk map.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                // verdict
                HStack(spacing: 8) {
                    Circle().fill(levelColor).frame(width: 8, height: 8)
                    Text("macOS memory pressure: \(health.sample?.memoryPressure.title ?? "Unavailable")").font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(levelColor.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(levelColor.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // headline cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 11)], spacing: 11) {
                    StatCard(label: "In use", value: fmt(store.mem.used),
                             sub: "of \(fmt(store.mem.total)) installed",
                             bar: Double(store.mem.used) / Double(max(store.mem.total, 1)),
                             tint: levelColor)
                    StatCard(label: "Estimated memory load",
                             value: String(format: "%.0f%%", store.mem.estimatedLoadPercent),
                             sub: "\(fmt(store.mem.free)) free · \(fmt(store.mem.reclaimable)) reclaimable",
                             bar: store.mem.estimatedLoadPercent / 100, tint: levelColor)
                    StatCard(label: "Compressor",
                             value: String(format: "%.1f×", store.mem.ratio),
                             sub: "\(fmt(store.mem.stored)) squeezed into \(fmt(store.mem.compressor))",
                             bar: nil, tint: .yellow)
                    StatCard(label: "Swap on disk", value: fmt(store.mem.swapUsed),
                             sub: "of \(fmt(store.mem.swapTotal)) allocated",
                             bar: Double(store.mem.swapUsed) / Double(max(store.mem.swapTotal, 1)),
                             tint: .blue)
                }

                Text("Health severity follows macOS memory pressure, as on Mac Health. Occupancy, estimated load and swap are accounting details; high usage alone does not mean a problem.")
                    .font(.caption2).foregroundStyle(.secondary)

                // breakdown
                Text("Breakdown").font(.headline)
                GeometryReader { g in
                    let t = Double(max(store.mem.total, 1))
                    HStack(spacing: 0) {
                        seg(g.size.width * Double(store.mem.app) / t, .blue)
                        seg(g.size.width * Double(store.mem.wired) / t, .purple)
                        seg(g.size.width * Double(store.mem.compressor) / t, .yellow)
                        seg(g.size.width * Double(store.mem.free) / t, Color.secondary.opacity(0.3))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(height: 32)
                HStack(spacing: 16) {
                    legend(.blue, "App", store.mem.app)
                    legend(.purple, "Wired", store.mem.wired)
                    legend(.yellow, "Compressed", store.mem.compressor)
                    legend(Color.secondary.opacity(0.3), "Free", store.mem.free)
                }

                // history
                let minutes = store.history.count > 1
                    ? store.history.last!.at.timeIntervalSince(store.history.first!.at) / 60 : 0
                Text("Last \(String(format: "%.1f", minutes)) minutes")
                    .font(.headline).padding(.top, 6)
                MemoryChart(history: store.history)
                    .frame(height: 120)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // processes
                Text("Top consumers, grouped by app").font(.headline).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(store.procs) { p in
                        HStack {
                            Text(p.name).lineLimit(1)
                            Spacer()
                            Text("\(p.count)").monospacedDigit()
                                .foregroundStyle(p.count > 20 ? .orange : .secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(fmt(p.rss)).monospacedDigit().frame(width: 84, alignment: .trailing)
                            Text(String(format: "%.1f%%", p.share)).font(.caption)
                                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            if p.signalable, !p.pids.isEmpty {
                                Button("Quit") { pendingQuit = p }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(quittingGroupID != nil)
                                    .help("Ask the application to quit, or send SIGTERM to its processes when no application is registered.")
                            } else {
                                RiskBadge(risk: .blocked, note: .needsAdmin, compact: true)
                                    .help("This group contains unowned, unreadable, or FastMac processes and cannot be quit here.")
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                Text("""
                     Resident memory sums can count shared pages more than once. Process counts \
                     include waiting helpers and do not measure active work. Select an app in \
                     Performance to review its helper states, CPU and memory footprint.
                     """)
                    .font(.caption2).foregroundStyle(.tertiary)

                // disk
                Text("Disk").font(.headline).padding(.top, 6)
                if store.diskAvailable {
                    let usedPct = Double(store.diskTotal - store.diskFree) / Double(store.diskTotal)
                    HStack {
                        Text("Free").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(fmt(store.diskFree)) of \(fmt(store.diskTotal))").monospacedDigit()
                    }
                    ProgressView(value: min(1, max(0, usedPct)))
                        .tint(usedPct > 0.9 ? .red : usedPct > 0.8 ? .orange : .green)
                } else {
                    Text("Disk reading unavailable").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .onReceive(store.$dashboardActive) { active in store.setMemoryVisible(active) }
        .onDisappear { store.setMemoryVisible(false) }
        .confirmationDialog("Quit \(pendingQuit?.name ?? "this group")?",
                            isPresented: Binding(get: { pendingQuit != nil },
                                                 set: { if !$0 { pendingQuit = nil } }),
                            titleVisibility: .visible) {
            Button("Quit", role: .destructive) {
                guard let group = pendingQuit else { return }
                pendingQuit = nil
                quittingGroupID = group.id
                Task {
                    let result = await PerfActions.terminate(group: group)
                    quittingGroupID = nil
                    quitResult = QuitResult(title: result.ok ? "Quit result" : "Could not quit", body: result.message)
                }
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("Asks the owning application to quit through macOS when available. Otherwise sends SIGTERM to the \(pendingQuit?.count ?? 0) listed processes. They may exit without saving or decline to stop. Unsaved work may be lost.")
        }
        .alert(item: $quitResult) { result in
            Alert(title: Text(result.title), message: Text(result.body), dismissButton: .default(Text("OK")))
        }
    }

    private func seg(_ w: Double, _ c: Color) -> some View {
        Rectangle().fill(c).frame(width: max(0, w))
    }
    private func legend(_ c: Color, _ label: String, _ v: Int64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text("\(label) \(fmt(v))").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StatCard: View {
    let label: String, value: String, sub: String
    let bar: Double?
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary).kerning(0.6)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let bar {
                ProgressView(value: min(1, max(0, bar))).tint(tint).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Stacked area of app / wired / compressed, with swap overlaid as a dashed line.
private struct MemoryChart: View {
    let history: [MemorySample]

    var body: some View {
        Canvas { ctx, size in
            guard history.count > 1, let total = history.last?.total, total > 0 else { return }
            let span = Double(history.count - 1)
            func x(_ i: Int) -> Double { Double(i) / span * size.width }
            func y(_ v: Int64) -> Double { size.height - Double(v) / Double(total) * size.height }

            var floor = [Int64](repeating: 0, count: history.count)
            let bands: [(KeyPath<MemorySample, Int64>, Color)] = [
                (\.app, .blue), (\.wired, .purple), (\.compressor, .yellow)
            ]
            for (key, color) in bands {
                var p = Path()
                p.move(to: CGPoint(x: x(0), y: y(floor[0])))
                for i in history.indices { p.addLine(to: CGPoint(x: x(i), y: y(floor[i] + history[i][keyPath: key]))) }
                for i in history.indices.reversed() { p.addLine(to: CGPoint(x: x(i), y: y(floor[i]))) }
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.72)))
                for i in history.indices { floor[i] += history[i][keyPath: key] }
            }

            let swapMax = Double(history.map(\.swapTotal).max() ?? 1)
            if swapMax > 0 {
                var p = Path()
                for i in history.indices {
                    let yy = size.height - Double(history[i].swapUsed) / swapMax * size.height * 0.92
                    if i == 0 { p.move(to: CGPoint(x: x(i), y: yy)) }
                    else { p.addLine(to: CGPoint(x: x(i), y: yy)) }
                }
                ctx.stroke(p, with: .color(.red.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                ctx.draw(Text("swap").font(.system(size: 9)).foregroundColor(.red),
                         at: CGPoint(x: size.width - 8, y: 12), anchor: .trailing)
            }
        }
    }
}
