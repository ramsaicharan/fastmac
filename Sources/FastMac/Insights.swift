import SwiftUI

/// Ranked observations, not a claim that correlation proves a slowdown's cause.
/// The same immutable findings can later feed the popup without a second sampler.
struct AttentionFinding: Identifiable {
    let id: String
    let severity: HealthStatus
    let title: String
    let evidence: String
    let interpretation: String
    let destination: ViewKind
    let action: String
    let observedAt: Date
}

extension HealthStatus {
    var priority: Int {
        switch self { case .critical: 3; case .attention: 2; case .unknown: 1; case .comfortable: 0 }
    }
}

struct InsightReport {
    var findings: [AttentionFinding]
    var coverage: String
    var sampleCount: Int
}

enum InsightEngine {
    static func evaluate(health: HealthSample?, samples: [ActivitySnapshot], now: Date = Date()) -> InsightReport {
        let recent = samples.filter { $0.sampledAt <= now && now.timeIntervalSince($0.sampledAt) <= 3600 }
            .sorted { $0.sampledAt == $1.sampledAt ? $0.apps.count > $1.apps.count : $0.sampledAt < $1.sampledAt }
        // No interpolation over pauses, restarts or unreadable periods.
        var contiguous: [ActivitySnapshot] = []
        for sample in recent.suffix(240) {
            if let last = contiguous.last {
                if sample.sampledAt == last.sampledAt { continue }
                if sample.sessionID != last.sessionID || sample.sampledAt.timeIntervalSince(last.sampledAt) > 95 {
                    contiguous.removeAll(keepingCapacity: true)
                }
            }
            contiguous.append(sample)
        }
        let live = contiguous.last.flatMap { now.timeIntervalSince($0.sampledAt) <= 90 ? $0 : nil }
        let freshHealth = health.flatMap { (0...90).contains(now.timeIntervalSince($0.sampledAt)) ? $0 : nil }
        var findings: [AttentionFinding] = []
        if let h = freshHealth {
            let contributions = live?.apps.filter { ($0.rss ?? 0) > 0 }.sorted { ($0.rss ?? 0) > ($1.rss ?? 0) }.prefix(3)
                .map { "\($0.name): \(fmt($0.rss ?? 0)) RSS" }.joined(separator: "; ") ?? "App readings unavailable."
            if h.memoryStatus.priority >= 2 {
                findings.append(.init(id: "memory-pressure", severity: h.memoryStatus,
                    title: "Memory demand needs attention", evidence: "macOS pressure: \(h.memoryPressure.title). \(contributions)",
                    interpretation: "These are large measured consumers, not proven causes. RSS can include shared pages. Review work you can close; routine RAM purging is unnecessary.",
                    destination: .memory, action: "Review memory", observedAt: h.sampledAt))
            }
            if h.storageStatus.priority >= 2 {
                findings.append(.init(id: "storage-headroom", severity: h.storageStatus,
                    title: "Storage headroom is low", evidence: "\(fmt(h.diskFree)) free of \(fmt(h.diskTotal)).",
                    interpretation: "Low free space can constrain apps and swap. Review files before moving them to Trash. No scan or cleanup has been started.",
                    destination: .quick, action: "Review storage", observedAt: h.sampledAt))
            }
            if h.thermalStatus.priority >= 2 {
                findings.append(.init(id: "thermal", severity: h.thermalStatus,
                    title: "Your Mac reports thermal pressure", evidence: "macOS thermal state: \(h.thermalTitle).",
                    interpretation: "Inspect demanding work and pause optional jobs. This does not measure a temperature or identify a hardware fault.",
                    destination: .performance, action: "Inspect performance", observedAt: h.sampledAt))
            }
        }
        if let live {
            let tail = Array(contiguous.reversed().prefix { $0.cpuPercent.map { $0.isFinite && (80...100).contains($0) } ?? false }.reversed())
            if tail.count >= 3, let start = tail.first, live.sampledAt.timeIntervalSince(start.sampledAt) >= 120 {
                let leader = live.apps.filter { ($0.cpuPercent ?? -1).isFinite }.max { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
                findings.append(.init(id: "sustained-cpu", severity: .attention, title: "CPU demand has stayed high",
                    evidence: "At least \(Int(live.sampledAt.timeIntervalSince(start.sampledAt) / 60)) minutes of sampled whole-machine CPU at 80% or higher. \(leader.map { "Largest listed app: \($0.name)." } ?? "")",
                    interpretation: "A build or render may explain this. High CPU alone does not mean an app is frozen.", destination: .performance,
                    action: "Review busy processes", observedAt: live.sampledAt))
            }
            if let first = contiguous.first, live.sampledAt.timeIntervalSince(first.sampledAt) >= 120 {
                let old = Dictionary(first.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let changes = live.apps.compactMap { app -> (ActivityAppSnapshot, Int64)? in
                    guard let before = old[app.id]?.rss, let after = app.rss, before >= 0, after >= before else { return nil }
                    let delta = after - before
                    return delta >= 512 * 1_048_576 ? (app, delta) : nil
                }.sorted { $0.1 > $1.1 }
                for (app, delta) in changes.prefix(2) {
                    findings.append(.init(id: "growth-" + app.id, severity: .comfortable,
                        title: "\(app.name)'s resident memory increased", evidence: "+\(fmt(delta)) across \(Int(live.sampledAt.timeIntervalSince(first.sampledAt) / 60)) minutes; \(fmt(app.rss ?? 0)) in the latest reading.",
                        interpretation: "A change to investigate, not a leak diagnosis. Group membership and shared pages can change. Apps missing from either endpoint are excluded.",
                        destination: .activity, action: "Explore activity history", observedAt: live.sampledAt))
                }
            }
        }
        if freshHealth == nil || freshHealth?.status == .unknown || live == nil {
            findings.append(.init(id: "coverage", severity: .unknown, title: "Some evidence is unavailable",
                evidence: "\(freshHealth == nil ? "Health needs a current reading. " : "")\(live == nil ? "No activity reading from the last 90 seconds. " : "")\(freshHealth?.status == .unknown ? "One or more health signals are unavailable." : "")",
                interpretation: "Refresh to collect readings. Recording can remain off; longer comparisons need saved history or an active observation period.",
                destination: .activity, action: "Review history coverage", observedAt: now))
        }
        findings.sort { $0.severity.priority != $1.severity.priority ? $0.severity.priority > $1.severity.priority : $0.id < $1.id }
        return InsightReport(findings: findings,
            coverage: "\(contiguous.count) continuous readings in the most recent session. Gaps over 95 seconds reset comparisons. Saved history retains only its largest app groups; missing apps are not treated as zero.", sampleCount: contiguous.count)
    }
}

struct InsightsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var health: HealthMonitor
    @ObservedObject var activity: ActivityMonitor
    var automaticallyLoads = true
    @State private var history: [ActivitySnapshot] = []
    @State private var message: String?
    @State private var request = UUID()
    @State private var loading = false

    private var report: InsightReport {
        InsightEngine.evaluate(health: health.sample, samples: history + activity.recent + (activity.latest.map { [$0] } ?? []))
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What needs attention").font(.largeTitle.bold())
                            Text("Measured conditions and recent changes, with the evidence behind each.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { health.refresh(); activity.refresh(); load() }.disabled(loading)
                    }
                    if loading { ProgressView("Reading recent history…") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if report.findings.isEmpty {
                        Label("Current readings look comfortable", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                        Text("No intervention is indicated by these readings. This does not rule out problems outside our measurements.")
                    }
                    ForEach(report.findings) { finding in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(finding.title, systemImage: finding.severity.icon).font(.headline).foregroundStyle(finding.severity.color)
                            Text(finding.evidence).textSelection(.enabled)
                            Text(finding.interpretation).font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button(finding.action) { store.view = finding.destination }
                                Spacer()
                                Text(finding.observedAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text(report.coverage).font(.caption).foregroundStyle(.secondary)
                    Text("All analysis runs locally. Actions open a review; diagnosis never quits an app or changes files.").font(.caption).foregroundStyle(.secondary)
                }.padding(26).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if automaticallyLoads { load() } }
        .onDisappear { request = UUID(); loading = false }
    }
    private func load() {
        let id = UUID(); request = id; loading = true
        activity.repository.load(from: Date().addingTimeInterval(-3600), limit: 240) { samples, error in
            DispatchQueue.main.async {
                guard request == id else { return }
                history = samples; message = error; loading = false
            }
        }
    }
}
