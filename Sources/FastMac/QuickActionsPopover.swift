import SwiftUI
import AppKit

/// A short path from an observed problem to a reviewed action. App identity is
/// captured in the pending action so live readings cannot change its target.
@MainActor
struct QuickActionsPopover: View {
    @ObservedObject var health: HealthMonitor
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject var model: QuickActionsModel
    let onNavigate: (ViewKind) -> Void
    let onSettings: () -> Void
    let onRefresh: () -> Void
    @State private var sort: AppSort = .memory
    @State private var pending: PendingQuit?
    @Namespace private var sortSelection

    fileprivate enum AppSort: String, CaseIterable { case memory = "Memory", cpu = "CPU" }
    private struct PendingQuit { let app: QuickActionApp; let force: Bool }
    private var accent: Color { DS.Palette.accent }
    private var sample: HealthSample? { health.sample }
    private var paused: Bool { !health.isMonitoring }
    private var hasOldReading: Bool {
        guard let date = activity.latest?.sampledAt ?? sample?.sampledAt else { return false }
        return Date().timeIntervalSince(date) > QuickActionsPolicy.metricsMaximumAge
    }
    private var statusColor: Color { paused || hasOldReading ? .secondary : sample?.status.color ?? .secondary }
    private var orderedApps: [QuickActionApp] {
        model.apps.sorted { a, b in
            if (a.response == .didNotRespond) != (b.response == .didNotRespond) {
                return a.response == .didNotRespond
            }
            let lhs = sort == .memory ? a.residentBytes.map(Double.init) : a.cpuPercent
            let rhs = sort == .memory ? b.residentBytes.map(Double.init) : b.cpuPercent
            if lhs != rhs { return (lhs ?? -1) > (rhs ?? -1) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View { content(scrollApps: true) }
    var snapshotContent: some View { content(scrollApps: false) }

    /// The live panel supplies the vibrancy background; previews draw on a plain canvas.
    private func content(scrollApps: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            header
            metrics
            if let notice { noticeBanner(notice) }
            appHeading
            if scrollApps {
                ScrollView { appList(orderedApps) }
                    .scrollIndicators(.never)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                appList(Array(orderedApps.prefix(4)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            appTools
            footer
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.primary)
        .disabled(pending != nil)
        .accessibilityHidden(pending != nil)
        .overlay { if let pending { confirmation(pending).transition(.opacity) } }
        .animation(DS.Motion.quick, value: pending == nil)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [accent, accent.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text("FastMac").font(.dsHeadline)
            Spacer()
            StatusPill(text: paused ? "Paused" : hasOldReading ? "Older reading" : sample == nil ? "Reading…" : "Live",
                       color: statusColor, pulsing: !paused && !hasOldReading && sample != nil)
            Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(DSIconButtonStyle())
                .help("Refresh readings and open apps")
                .accessibilityLabel("Refresh readings and open apps")
                .disabled(model.busyAppID != nil)
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(spacing: DS.Space.xs) {
            metric("Memory", value: memoryValue, detail: pressureText, symbol: "memorychip",
                   color: paused ? .secondary : sample?.memoryStatus.color ?? .secondary,
                   fraction: memoryFraction, route: .memory)
            metric("CPU", value: activity.latest?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                   detail: "All apps", symbol: "cpu", color: accent,
                   fraction: activity.latest?.cpuPercent.map { $0 / 100 }, route: .performance)
            metric("Storage", value: diskFree.map(fmt) ?? "—", detail: "Free", symbol: "internaldrive",
                   color: accent, fraction: diskUsedFraction, route: .health)
        }
    }

    private func metric(_ label: String, value: String, detail: String, symbol: String,
                        color: Color, fraction: Double?, route: ViewKind) -> some View {
        Button { onNavigate(route) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(label)
                }
                .font(.dsEyebrow).foregroundStyle(.secondary)
                Text(value).font(.dsMetricCompact)
                    .lineLimit(1).minimumScaleFactor(0.7).dsNumeric(value)
                MeterBar(fraction: fraction, tint: color, height: 4)
                Text(detail).font(.dsCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(DS.Space.sm - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DSTileButtonStyle())
        .accessibilityLabel("\(label): \(value), \(detail). Open details")
    }

    private var memoryValue: String {
        if let used = activity.latest?.memoryUsed { return fmt(used) }
        if let sample, sample.memoryAvailable { return fmt(sample.memory.used) }
        return "—"
    }
    private var memoryFraction: Double? {
        guard let used = activity.latest?.memoryUsed, let total = activity.latest?.memoryTotal, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
    private var diskFree: Int64? {
        if let free = activity.latest?.diskFree { return free }
        guard let sample, sample.diskAvailable else { return nil }
        return sample.diskFree
    }
    private var diskUsedFraction: Double? {
        if let free = activity.latest?.diskFree, let total = activity.latest?.diskTotal, total > 0 {
            return 1 - Double(free) / Double(total)
        }
        return sample?.diskFreeFraction.map { 1 - $0 }
    }
    private var pressureText: String {
        guard let sample else { return "Pressure unknown" }
        return "\(sample.memoryPressure.title) pressure"
    }

    // MARK: Notice

    /// Shown only when something deserves attention, so the calm state stays quiet.
    private var notice: (symbol: String, text: String, color: Color)? {
        if paused { return ("pause.circle.fill", "Monitoring is paused. Refresh for a new reading.", .secondary) }
        if hasOldReading { return ("clock.fill", "These readings are a few minutes old.", .secondary) }
        if let sample, sample.memoryPressure == .warning || sample.memoryPressure == .critical {
            return ("exclamationmark.circle.fill", "Memory is under pressure. Quit an app you aren’t using.", sample.memoryStatus.color)
        }
        return nil
    }

    private func noticeBanner(_ notice: (symbol: String, text: String, color: Color)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Image(systemName: notice.symbol).foregroundStyle(notice.color)
            Text(notice.text).foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.dsCaption)
        .padding(.horizontal, DS.Space.sm - 2).padding(.vertical, DS.Space.xs)
        .background(notice.color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }

    // MARK: Apps

    private var appHeading: some View {
        HStack(spacing: 6) {
            Text("Open apps").font(.system(size: 13, weight: .semibold))
            Text("\(model.apps.count)")
                .font(.dsCaptionEmphasis).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(DS.Palette.fill, in: Capsule())
            InfoButton("Memory is approximate resident memory for each app, including helpers where shown. Quitting an app does not guarantee that amount is freed. CPU counts 100% per fully used core, so busy apps can exceed 100%.")
            Spacer()
            sortPicker
        }
    }

    private var sortPicker: some View {
        HStack(spacing: 0) {
            ForEach(AppSort.allCases, id: \.self) { item in
                Button { withAnimation(DS.Motion.quick) { sort = item } } label: {
                    Text(item.rawValue).font(.dsCaptionEmphasis)
                        .foregroundStyle(sort == item ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if sort == item {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(DS.Palette.surface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "sort", in: sortSelection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(item.rawValue)")
                .accessibilityAddTraits(sort == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.Palette.fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }

    private func appList(_ apps: [QuickActionApp]) -> some View {
        VStack(spacing: 2) {
            if apps.isEmpty {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "app.dashed").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("No other open apps").font(.dsBodyEmphasis)
                    Text("Background services are listed in Performance.").font(.dsCaption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xl)
            } else {
                ForEach(apps) { app in
                    QuickAppRow(app: app, sortByMemory: sort == .memory,
                                busy: model.busyAppID == app.id, disabled: model.busyAppID != nil,
                                help: appHelp(app),
                                onQuit: { pending = PendingQuit(app: app, force: false) },
                                onForceQuit: { pending = PendingQuit(app: app, force: true) })
                }
            }
        }
        .animation(DS.Motion.standard, value: orderedApps.map(\.id))
    }

    private func appHelp(_ app: QuickActionApp) -> String {
        let at = app.metricsAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "unavailable"
        return "\(app.memoryIncludesHelpers ? "App and helpers" : "Main app only"). Resident memory is approximate; closing an app does not guarantee this amount is freed. CPU 100% = one core. Reading: \(at)."
            + (app.responseCheckedAt.map { " Response checked \($0.formatted(date: .omitted, time: .standard))." } ?? "")
    }

    private var appTools: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { model.checkResponsiveness() } label: {
                    Label(model.isChecking ? "Checking responses…" : "Check responses", systemImage: "waveform.path")
                }
                .buttonStyle(DSButtonStyle(kind: .quiet, compact: true))
                .disabled(model.isChecking || model.busyAppID != nil)
                .help("Ask each open app for a reply. A missed reply is a cue to review, not proof an app is frozen.")
                Spacer()
                Button { onNavigate(.performance) } label: {
                    HStack(spacing: 3) {
                        Text("All processes")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .quiet, compact: true, tint: .secondary))
            }
            .padding(.horizontal, -(DS.Space.xs + 2))
            if !model.accessibilityTrusted && model.statusMessage != nil {
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain).font(.dsCaptionEmphasis).foregroundStyle(accent)
            }
            if let message = model.actionMessage ?? model.statusMessage {
                Text(message).font(.dsCaption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: DS.Space.sm - 2) {
            Divider()
            HStack(spacing: DS.Space.xs) {
                Button { onNavigate(.health) } label: {
                    Label("Open Dashboard", systemImage: "square.grid.2x2")
                }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                Button { onNavigate(.quick) } label: {
                    Label("Free up space", systemImage: "sparkles")
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(DSIconButtonStyle(size: 32))
                    .help("Settings").accessibilityLabel("Settings")
            }
            HStack {
                Text(readingText).lineLimit(1)
                Spacer()
                Button(paused ? "Resume monitoring" : "Pause") { Settings.shared.healthMonitoringEnabled.toggle() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(paused ? "Resume monitoring" : "Pause monitoring")
            }
            .font(.dsCaption).foregroundStyle(.secondary)
        }
    }

    private var readingText: String {
        guard let date = activity.latest?.sampledAt ?? sample?.sampledAt else { return "Awaiting a reading" }
        let prefix = paused ? "Last reading" : Date().timeIntervalSince(date) > 75 ? "Older reading" : "Updated"
        return "\(prefix) \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Confirmation

    private func confirmation(_ action: PendingQuit) -> some View {
        ZStack {
            DS.Palette.canvas.opacity(0.97)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                IconPlate(symbol: action.force ? "exclamationmark.triangle.fill" : "rectangle.portrait.and.arrow.right",
                          tint: action.force ? DS.Palette.warning : accent, size: 44)
                Text("\(action.force ? "Force quit" : "Quit") \(action.app.name)?")
                    .font(.dsTitle).fixedSize(horizontal: false, vertical: true)
                Text(PerfActions.confirmation(identity: action.app.identity, force: action.force))
                    .font(.dsBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if action.force {
                    Text("Try a normal Quit first if the app still responds.").font(.dsCaption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { pending = nil }.keyboardShortcut(.defaultAction)
                    Spacer()
                    Button(action.force ? "Force Quit" : "Quit", role: action.force ? .destructive : nil) {
                        pending = nil
                        Task { @MainActor in
                            _ = await model.terminate(action.app, force: action.force)
                            model.refresh(snapshot: activity.latest)
                        }
                    }
                }
                .controlSize(.large).padding(.top, DS.Space.xs)
            }
            .padding(DS.Space.xl - 4)
        }
        .accessibilityAddTraits(.isModal).onExitCommand { pending = nil }
    }
}

/// One open app. The sorted reading leads; Quit and Force Quit appear on hover,
/// stay visible for an app that missed a response check, and are always
/// available to assistive technologies as named actions.
private struct QuickAppRow: View {
    let app: QuickActionApp
    let sortByMemory: Bool
    let busy: Bool
    let disabled: Bool
    let help: String
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @State private var hovering = false

    private var memoryText: String {
        app.residentBytes.map { fmt($0) + (app.memoryIncludesHelpers ? "" : " app only") } ?? "Memory —"
    }
    private var cpuText: String { app.cpuPercent.map { String(format: "%.0f%% CPU", $0) } ?? "CPU —" }
    private var showsActions: Bool { !busy && !disabled && (hovering || app.response == .didNotRespond) }

    var body: some View {
        HStack(spacing: DS.Space.sm - 2) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.fill").resizable().foregroundStyle(DS.Palette.accent.opacity(0.7)) }
            }
            .frame(width: 26, height: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.dsBodyEmphasis).lineLimit(1)
                if app.response != .unchecked {
                    Text(app.response.label).font(.dsCaption)
                        .foregroundStyle(app.response == .didNotRespond ? DS.Palette.warning : .secondary)
                } else {
                    Text(sortByMemory ? cpuText : memoryText)
                        .font(.dsCaption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                Text(sortByMemory ? memoryText : cpuText)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(showsActions || busy ? 0 : 1)
                if busy {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 4) {
                    Button("Quit", action: onQuit)
                        .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                    Button(action: onForceQuit) { Image(systemName: "xmark.octagon") }
                        .buttonStyle(DSIconButtonStyle(size: 26))
                        .foregroundStyle(app.response == .didNotRespond ? DS.Palette.warning : .secondary)
                        .help("Force Quit \(app.name)… Unsaved work may be lost.")
                }
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
            }
        }
        .padding(.horizontal, DS.Space.sm - 3).padding(.vertical, 7)
        .background(hovering ? DS.Palette.fill : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.sm + 1, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(memoryText), \(cpuText)"
            + (app.response == .unchecked ? "" : ", \(app.response.label)"))
        .accessibilityAction(named: "Quit \(app.name)") { if !disabled { onQuit() } }
        .accessibilityAction(named: "Force Quit \(app.name)") { if !disabled { onForceQuit() } }
    }
}
