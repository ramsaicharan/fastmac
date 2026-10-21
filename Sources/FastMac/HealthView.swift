import SwiftUI

struct HealthView: View {
    @ObservedObject var health: HealthMonitor

    var body: some View { ScrollView { snapshotContent } }

    /// Production and rendered previews share this content. ImageRenderer cannot
    /// draw the platform scroll container on macOS.
    var snapshotContent: some View { HealthDashboardContent(health: health) }
}

private struct HealthDashboardContent: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var health: HealthMonitor

    private var status: HealthStatus { health.sample?.status ?? .unknown }
    private var recommendations: [HealthRecommendation] {
        HealthRecommendations.make(sample: health.sample, stagedCount: store.staged.count)
    }
    private var primaryRecommendation: HealthRecommendation? {
        recommendations.sorted { $0.urgency.priority > $1.urgency.priority }.first { $0.urgency == .attention || $0.urgency == .critical }
            ?? recommendations.first { $0.id == "performance" }
    }
    private var nextSteps: [HealthRecommendation] {
        Array(recommendations.filter { $0.id != primaryRecommendation?.id }.prefix(4))
    }
    private var primaryTitle: String {
        switch primaryRecommendation?.destination {
        case .memory: "Review memory"
        case .performance: "Review busy apps"
        case .quick: "Find space to free"
        default: "Review your Mac"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            header
            hero
            if let sample = health.sample { metrics(sample) }
            nextStepsSection
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, DS.Space.lg + DS.Space.xxs)
        .padding(.bottom, DS.Space.xl)
        .frame(maxWidth: 1080)
        .frame(maxWidth: .infinity)
        .animation(DS.Motion.standard, value: status)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.xs) {
            VStack(alignment: .leading, spacing: DS.Space.xxs + 2) {
                Text("Mac Health").font(.dsLargeTitle)
                HStack(spacing: DS.Space.xs) {
                    StatusDot(color: health.isMonitoring ? DS.Palette.good : .secondary, pulsing: health.isMonitoring)
                    Text(liveText).font(.dsCaption).foregroundStyle(.secondary)
                    InfoButton("FastMac reads memory pressure, free storage and thermal state every 15 seconds. Folder scans run only when you ask. Storage review is suggested below 20 GB or 10% free, and urgent below 5 GB or 5%. Pause monitoring in Settings.")
                }
            }
            Spacer()
            Button { store.view = .activity } label: {
                Label("History", systemImage: "chart.xyaxis.line")
            }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .help("Open activity history")
            Button { health.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(DSIconButtonStyle(size: 30))
                .help("Read your Mac's current health without starting a folder scan")
                .accessibilityLabel("Refresh")
        }
    }

    private var liveText: String {
        guard let sample = health.sample else {
            return health.isMonitoring ? "Taking the first reading…" : "Monitoring paused"
        }
        let time = sample.sampledAt.formatted(date: .omitted, time: .shortened)
        return health.isMonitoring ? "Live · updated \(time)" : "Paused · last reading \(time)"
    }

    // MARK: Hero

    private var heroTitle: String {
        guard let sample = health.sample else {
            return health.isMonitoring ? "Reading your Mac…" : "Monitoring paused"
        }
        return sample.status == .comfortable ? "Everything looks good" : sample.statusTitle
    }

    private var heroDetail: String {
        health.sample?.statusDetail ?? (health.isMonitoring
            ? "Your first health reading will appear in a moment."
            : "Refresh for a current reading, or resume monitoring in Settings.")
    }

    private var hero: some View {
        let emphasised = status == .attention || status == .critical
        let shape = RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
        return HStack(alignment: .top, spacing: DS.Space.lg - DS.Space.xxs) {
            StatusGlyph(status: status)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(heroTitle).font(.dsTitle)
                Text(heroDetail).font(.dsBody).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.xs) {
                    Button { store.view = primaryRecommendation?.destination ?? .performance } label: {
                        HStack(spacing: 6) {
                            Text(primaryTitle)
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(DSButtonStyle(kind: emphasised ? .primary : .secondary))
                    Button("What changed?") { store.view = .insights }
                        .buttonStyle(DSButtonStyle(kind: .quiet))
                        .help("Review measured changes and the evidence behind them")
                }
                .padding(.top, DS.Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(DS.Palette.surface)
            shape.fill(LinearGradient(colors: [status.color.opacity(emphasised ? 0.12 : 0.08), status.color.opacity(0)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(shape.strokeBorder(DS.Palette.hairline))
        .shadow(color: .black.opacity(0.035), radius: 1.5, y: 1)
    }

    // MARK: Metrics

    private func metrics(_ sample: HealthSample) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            MetricCard(title: "Memory", symbol: "memorychip", value: sample.memoryPressure.title,
                       unit: sample.memoryPressure == .unknown ? nil : "pressure",
                       detail: memoryDetail(sample), destination: ViewKind.memory.title) {
                LevelMeter(level: memoryLevel(sample), steps: 3, tint: sample.memoryStatus.color)
            } action: { store.view = .memory }

            MetricCard(title: "Storage", symbol: "internaldrive",
                       value: sample.diskAvailable ? fmt(sample.diskFree) : "Unavailable",
                       unit: sample.diskAvailable ? "free" : nil,
                       detail: sample.diskAvailable
                           ? "\(fmt(sample.diskTotal - sample.diskFree)) used of \(fmt(sample.diskTotal))"
                           : "Volume reading unavailable",
                       destination: ViewKind.quick.title) {
                MeterBar(fraction: sample.diskFreeFraction.map { 1 - $0 },
                         tint: sample.storageStatus == .comfortable ? DS.Palette.accent : sample.storageStatus.color)
            } action: { store.view = .quick }

            MetricCard(title: "Thermal", symbol: "thermometer.medium", value: sample.thermalTitle,
                       detail: "Reported by macOS", destination: ViewKind.performance.title) {
                LevelMeter(level: thermalLevel(sample), steps: 4, tint: sample.thermalStatus.color)
            } action: { store.view = .performance }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func memoryDetail(_ sample: HealthSample) -> String {
        guard sample.memoryAvailable else { return "Memory counters unavailable" }
        let ram = "\(fmt(sample.memory.total)) RAM"
        return sample.swapAvailable ? "\(ram) · \(fmt(sample.memory.swapUsed)) swap used" : ram
    }

    private func memoryLevel(_ sample: HealthSample) -> Int {
        switch sample.memoryPressure {
        case .normal: 1
        case .warning: 2
        case .critical: 3
        case .unknown: 0
        }
    }

    private func thermalLevel(_ sample: HealthSample) -> Int {
        switch sample.thermalState {
        case .nominal: 1
        case .fair: 2
        case .serious: 3
        case .critical: 4
        @unknown default: 0
        }
    }

    // MARK: Next steps

    private var nextStepsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SectionHeader("Suggested next steps")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 240), spacing: DS.Space.sm), count: 2),
                      spacing: DS.Space.sm) {
                ForEach(nextSteps) { stepCard($0) }
            }
        }
    }

    private func stepCard(_ recommendation: HealthRecommendation) -> some View {
        Button { store.view = recommendation.destination } label: {
            HStack(alignment: .center, spacing: DS.Space.sm) {
                IconPlate(symbol: recommendation.icon,
                          tint: recommendation.urgency == .comfortable ? DS.Palette.accent : recommendation.urgency.color,
                          size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reviewTitle(recommendation)).font(.dsBodyEmphasis)
                    Text(reviewDetail(recommendation)).font(.dsCaption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(DSCardButtonStyle(padding: DS.Space.sm + 2))
        .accessibilityElement(children: .combine)
        .accessibilityHint(recommendation.buttonTitle)
    }

    private func reviewTitle(_ recommendation: HealthRecommendation) -> String {
        switch recommendation.id {
        case "thermal": "Review heavy workloads"
        case "storage-headroom": "Free up storage"
        case "cleanup-queue": "Your cleanup queue"
        case "ai-storage": "AI models & caches"
        case "startup": "A lighter startup"
        case "performance": "Apps & helper processes"
        case "caches": "Caches & build files"
        default: recommendation.title
        }
    }

    private func reviewDetail(_ recommendation: HealthRecommendation) -> String {
        switch recommendation.id {
        case "thermal": "Find demanding apps and pause optional work."
        case "storage-headroom": "Review measured files before choosing what to remove."
        case "cleanup-queue": "\(store.staged.count) item\(store.staged.count == 1 ? "" : "s") ready for your review."
        case "ai-storage": "Find local models and AI app storage."
        case "startup": "Review login and background items."
        case "performance": "See which apps are using CPU and memory."
        case "caches": "Review browser and developer storage."
        default: recommendation.detail
        }
    }
}

/// The hero's status mark: a tinted disc whose symbol morphs when status changes.
private struct StatusGlyph: View {
    let status: HealthStatus
    var body: some View {
        ZStack {
            Circle().fill(status.color.opacity(0.14))
            Circle().strokeBorder(status.color.opacity(0.28), lineWidth: 1)
            Image(systemName: status.icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(status.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
    }
}

/// One live reading: label, headline value, a visual gauge and one line of context.
private struct MetricCard<Visual: View>: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String?
    let detail: String
    let destination: String
    let visual: Visual
    let action: () -> Void

    init(title: String, symbol: String, value: String, unit: String? = nil, detail: String,
         destination: String, @ViewBuilder visual: () -> Visual, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.unit = unit
        self.detail = detail
        self.destination = destination
        self.visual = visual()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.xs) {
                    IconPlate(symbol: symbol, size: 26)
                    Text(title).font(.dsBodyEmphasis).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.dsMetric).lineLimit(1).minimumScaleFactor(0.7).dsNumeric(value)
                    if let unit { Text(unit).font(.dsBodyEmphasis).foregroundStyle(.secondary) }
                }
                visual
                Text(detail).font(.dsCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(DSCardButtonStyle())
        .help("Open \(destination)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)\(unit.map { " \($0)" } ?? ""). \(detail)")
        .accessibilityHint("Opens \(destination)")
    }
}
