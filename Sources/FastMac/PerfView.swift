import SwiftUI

/// Owns its PerfService; AppStore tells it when the dashboard is visible.
/// Deliberately styled to feel like MemoryView's sibling — same StatCard/legend/Canvas-chart
/// vocabulary — but everything here is CPU, thermal, power and process-signal data instead
/// of memory data.
struct PerfView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var service = PerfService()
    @State private var explainingProcess: PerfProcSample?
    @State private var helperSnapshot: AppHelperSnapshot?
    @State private var search = ""
    @State private var pendingAction: (proc: PerfProcSample, force: Bool)?

    private var thermalColor: Color {
        switch service.system.thermalState {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    private var busyPercent: Double {
        min(100, service.system.systemUserPercent + service.system.systemSystemPercent)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Live performance reads process, thermal and power info via macOS kernel and IOKit APIs, sampled on a timer; it does not scan your disk map.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                HStack(spacing: 8) {
                    Circle().fill(thermalColor).frame(width: 8, height: 8)
                    Text(verdictText).font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(thermalColor.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(thermalColor.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let msg = service.actionMessage {
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(msg).font(.caption)
                        Spacer()
                        Button { service.actionMessage = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.borderless).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                // headline cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 11)], spacing: 11) {
                    StatCard(label: "CPU busy", value: service.system.cpuAvailable ? String(format: "%.0f%%", busyPercent) : "Unavailable",
                             sub: service.system.cpuAvailable
                                ? "\(String(format: "%.0f", service.system.systemIdlePercent))% idle · \(service.system.coreCount) cores"
                                : "Waiting for two continuous readings",
                             bar: service.system.cpuAvailable ? busyPercent / 100 : nil,
                             tint: busyPercent > 80 ? .red : busyPercent > 50 ? .orange : .green)
                    StatCard(label: "Load average",
                             value: String(format: "%.2f", service.system.loadAvg1),
                             sub: "\(String(format: "%.2f", service.system.loadAvg5)) / \(String(format: "%.2f", service.system.loadAvg15)) (5m / 15m)",
                             bar: service.system.loadAvg1 / Double(max(1, service.system.coreCount)),
                             tint: service.system.loadAvg1 > Double(service.system.coreCount) ? .orange : .blue)
                    StatCard(label: "Uptime", value: uptimeText, sub: "since last boot",
                             bar: nil, tint: .purple)
                    StatCard(label: service.system.onBattery ? "Battery" : "Power",
                             value: service.system.onBattery ? "\(service.system.batteryPercent ?? 0)%" : "AC Power",
                             sub: service.system.onBattery
                                ? (service.system.isCharging ? "Charging" : "On battery") : "Plugged in",
                             bar: service.system.onBattery
                                ? Double(service.system.batteryPercent ?? 0) / 100 : nil,
                             tint: service.system.onBattery && (service.system.batteryPercent ?? 100) < 20 ? .red : .green)
                }

                // history
                Text("CPU over time").font(.headline).padding(.top, 6)
                PerfChart(history: service.cpuHistory)
                    .frame(height: 100)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if !service.advisories.isEmpty {
                    Text("What's worth knowing").font(.headline).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(service.advisories, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(line).font(.callout)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // grouped by app
                Text("Top consumers, grouped by app").font(.headline).padding(.top, 6)
                VStack(spacing: 0) {
                    HStack {
                        Text("App").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("Procs").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 44, alignment: .trailing)
                        Text("CPU¹").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 56, alignment: .trailing)
                        Text("RSS").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 84, alignment: .trailing)
                    }
                    Divider()
                    ForEach(service.groups.prefix(14)) { g in
                        HStack {
                            Button {
                                helperSnapshot = AppHelperSnapshot(group: g,
                                    members: service.procs.filter { $0.appKey == g.id }, at: service.lastUpdated ?? Date())
                            } label: { Label(g.name, systemImage: "info.circle").lineLimit(1) }
                                .buttonStyle(.borderless).help("See helper roles, waiting states and memory; review the owning app")
                            Spacer()
                            Text("\(g.count)").monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(g.cpuAvailable ? String(format: "%.1f%%", g.cpuPercent) : "—").monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            Text(fmt(g.rss)).monospacedDigit().frame(width: 84, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                Text("""
                     Process CPU uses Activity Monitor's convention: 100% means one full core. An app \
                     using several cores can exceed 100%; the CPU busy card is the separate whole-system \
                     percentage. Resident size can double-count pages shared by an app's helpers.
                     """)
                    .font(.caption2).foregroundStyle(.tertiary)

                // individual processes
                Text("Processes").font(.headline).padding(.top, 6)
                TextField("Filter by process, app or PID", text: $search).textFieldStyle(.roundedBorder)
                VStack(spacing: 0) {
                    HStack {
                        Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("PID").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
                        Text("CPU¹").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
                        Text("RSS").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 76, alignment: .trailing)
                        Text("Disk R/W").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 110, alignment: .trailing)
                        Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 150, alignment: .trailing)
                    }
                    Divider()
                    ForEach(service.procs.filter { search.isEmpty || "\($0.comm) \($0.appName) \($0.pid)".localizedCaseInsensitiveContains(search) }.prefix(100)) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Button { explainingProcess = p } label: {
                                    Label(p.comm.isEmpty ? p.appName : p.comm, systemImage: "info.circle").lineLimit(1)
                                }.buttonStyle(.borderless).help("Explain this process")
                                Text("\(p.appName) · \(p.runState.label)").font(.caption2).foregroundStyle(.secondary)
                                if p.lifetimeCPUSeconds >= 3600 {
                                    Text("\(String(format: "%.1f", p.lifetimeCPUSeconds / 3600))h CPU lifetime")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Text("\(p.pid)").monospacedDigit().font(.caption)
                                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            Text(p.cpuAvailable ? String(format: "%.1f%%", p.cpuPercent) : "—").monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                            Text(fmt(p.rss)).monospacedDigit().font(.caption).frame(width: 76, alignment: .trailing)
                            Text(diskIOText(p)).monospacedDigit().font(.caption2)
                                .foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            HStack(spacing: 4) {
                                if !p.path.isEmpty {
                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
                                    } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("Reveal in Finder")
                                }
                                Button {
                                    pendingAction = (p, false)
                                } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.orange)
                                .disabled(!p.owned || p.identity == nil || p.pid <= 1 || p.pid == getpid()).help("Request Quit through macOS, or send SIGTERM to a standalone process")
                                Button {
                                    pendingAction = (p, true)
                                } label: { Image(systemName: "xmark.octagon.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.red)
                                .disabled(!p.owned || p.identity == nil || p.pid <= 1 || p.pid == getpid()).help("Force Quit immediately; unsaved work may be lost")
                            }
                            .frame(width: 150, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                Text("""
                     Disk R/W shows lifetime byte counters, not transfer speed; a dash means unavailable. \
                     Quit asks registered macOS applications to close and uses SIGTERM for standalone \
                     processes. Force Quit can lose unsaved work. Owner, start time and executable are \
                     rechecked immediately before each request, and accepted requests are recorded locally.
                     """)
                    .font(.caption2).foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    if let t = service.lastUpdated {
                        Text("Updated \(t.formatted(date: .omitted, time: .standard))")
                    }
                    Text("· sweep took \(String(format: "%.1f", service.sweepMs)) ms")
                    Text("· \(String(format: "%.0f", service.system.contextSwitchesPerSec))/s context switches (approx.)")
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(18)
        }
        .sheet(item: $explainingProcess) { ProcessExplanationView(process: $0) }
        .sheet(item: $helperSnapshot) { AppHelpersView(snapshot: $0) }
        .onReceive(store.$dashboardActive) { active in service.setVisible(active) }
        .onDisappear { service.setVisible(false) }
        .alert(pendingAction?.force == true ? "Force Quit \(pendingAction?.proc.appName ?? "")?"
                                             : "Quit \(pendingAction?.proc.appName ?? "")?",
               isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.force == true ? "Force Quit" : "Quit", role: .destructive) {
                if let pa = pendingAction {
                    if pa.force { service.forceQuit(pa.proc) } else { service.quit(pa.proc) }
                }
                pendingAction = nil
            }
        } message: {
            if let pa = pendingAction {
                Text("pid \(pa.proc.pid) · \(pa.proc.comm)\n" + PerfActions.confirmation(identity: pa.proc.identity, force: pa.force))
            }
        }
    }

    private var verdictText: String {
        var parts = ["Thermal state is \"\(service.system.thermalLabel)\""]
        if let limit = service.system.speedLimitPercent, limit < 100 {
            parts.append("CPU capped at \(limit)%")
        }
        if service.system.cpuAvailable {
            parts.append("\(String(format: "%.0f", busyPercent))% busy across \(service.system.coreCount) cores")
        } else {
            parts.append("CPU usage awaits two readings")
        }
        return parts.joined(separator: " · ")
    }

    private var uptimeText: String {
        let total = Int(service.system.uptime)
        let days = total / 86400, hours = (total % 86400) / 3600, mins = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private func diskIOText(_ p: PerfProcSample) -> String {
        guard let r = p.diskRead, let w = p.diskWrite else { return "—" }
        return "\(fmt(r))↓ \(fmt(w))↑"
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

/// Simple filled area of total system CPU busy% over time — same visual language as
/// MemoryView's MemoryChart, one series instead of stacked bands.
private struct PerfChart: View {
    let history: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard history.count > 1 else { return }
            let span = Double(history.count - 1)
            func x(_ i: Int) -> Double { Double(i) / span * size.width }
            func y(_ v: Double) -> Double { size.height - min(1, max(0, v / 100)) * size.height }

            var p = Path()
            p.move(to: CGPoint(x: x(0), y: size.height))
            for i in history.indices { p.addLine(to: CGPoint(x: x(i), y: y(history[i]))) }
            p.addLine(to: CGPoint(x: x(history.count - 1), y: size.height))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color.blue.opacity(0.55)))

            var line = Path()
            for i in history.indices {
                let pt = CGPoint(x: x(i), y: y(history[i]))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            ctx.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1.5))
        }
    }
}
