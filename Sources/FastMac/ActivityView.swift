import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ActivityView: View {
    @ObservedObject var activity: ActivityMonitor
    @ObservedObject private var settings = Settings.shared
    @State private var hours = 24.0
    @State private var selected: ActivitySnapshot?
    @State private var note = ""
    @State private var showingBookmark = false
    @State private var bookmarkSnapshot: ActivitySnapshot?
    @State private var confirmingClear = false
    @State private var includeAppNames = false
    @State private var exportJSON = false
    @State private var exportResult: String?
    @State private var selectedAppID: String?
    @State private var appSort = ActivityTrends.Sort.peakMemory
    @State private var appMemoryMetric = ActivityMemoryMetric.resident
    @State private var systemMetric = ActivitySystemMetric.pressure

    private var focused: ActivitySnapshot? { selected ?? activity.latest }
    var snapshotContent: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Activity History", systemImage: "waveform.path.ecg").font(.title2.bold())
                    Spacer()
                    Label(activity.isMonitoring ? "Monitoring" : "Paused",
                          systemImage: activity.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(.secondary)
                    Button("Refresh") { activity.loadHistory(hours: hours); activity.refresh() }
                }
                Text("Local minute samples, up to \(settings.activityRetentionDays) days and 100 MB. Up to 12 leading readable app groups are retained, with room for both memory and CPU consumers. Missing apps and paused monitoring remain gaps.")
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.recordActivityHistory {
                    Label("Recording is off. Existing history and saved moments remain available.", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Time range", selection: $hours) {
                        Text("1 hour").tag(1.0); Text("24 hours").tag(24.0)
                        Text("7 days").tag(168.0); Text("30 days").tag(720.0)
                    }.frame(maxWidth: 300)
                    Button("Live reading") { selected = nil }
                    Spacer()
                    if activity.loading { ProgressView().controlSize(.small) }
                    Button("Save moment…") {
                        bookmarkSnapshot = focused
                        showingBookmark = true
                    }.disabled(focused == nil)
                }
                if !activity.history.isEmpty {
                    rangeSummary
                    appHistory
                }
                charts
                if let sample = focused { details(sample) }
                else { ContentUnavailableView("Waiting for a reading", systemImage: "waveform.path.ecg",
                    description: Text("Enable monitoring in Settings or press Refresh.")) }
                Divider()
                savedMoments
                Divider()
                HStack {
                    Toggle("Include app names in export", isOn: $includeAppNames).toggleStyle(.checkbox)
                    Spacer()
                    Picker("Format", selection: $exportJSON) {
                        Text("CSV").tag(false); Text("JSON").tag(true)
                    }.frame(width: 135)
                    Button("Export displayed range…") { export() }.disabled(activity.history.isEmpty)
                    Button("Clear history…", role: .destructive) { confirmingClear = true }
                }
                Text("Export contains the displayed, possibly downsampled range and measured units. Missing values stay empty; command arguments and project folders are never included.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = activity.error ?? exportResult {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(20)
    }
    var body: some View {
        ScrollView { snapshotContent }
        .onAppear { activity.loadHistory(hours: hours) }
        .onChange(of: hours) { _, _ in selected = nil; activity.loadHistory(hours: hours) }
        .onChange(of: activity.latest?.sampledAt) { before, after in
            guard settings.recordActivityHistory, let after,
                  before == nil || Int(after.timeIntervalSince1970 / 60) != Int(before!.timeIntervalSince1970 / 60) else { return }
            activity.loadHistory(hours: hours)
        }
        .sheet(isPresented: $showingBookmark) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save this moment").font(.headline)
                if let snapshot = bookmarkSnapshot {
                    Text(snapshot.sampledAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Keeps this reading, leading apps and your note. Surrounding history is available while it remains inside the retention window.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("What were you investigating?", text: $note, axis: .vertical).lineLimit(3...5)
                HStack {
                    Spacer()
                    Button("Cancel") { showingBookmark = false }
                    Button("Save") {
                        activity.saveMoment(note: note, snapshot: bookmarkSnapshot)
                        note = ""; showingBookmark = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 440)
        }
        .alert("Clear activity history and saved moments?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { selected = nil; activity.clearHistory() }
        } message: {
            Text("This permanently removes FastMac's recorded metrics and bookmarks. Disk scans, cleanup queues and your files are unaffected. Recording can continue if enabled.")
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if activity.history.isEmpty {
                Text(activity.loading ? "Loading local history…" : "No recorded samples in this range yet.")
                    .foregroundStyle(.secondary).padding(.vertical, 15)
            } else {
                HStack {
                    Text("System history").font(.headline)
                    Spacer()
                    Picker("Metric", selection: $systemMetric) {
                        ForEach(ActivitySystemMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }.frame(width: 300)
                }
                metricChart(systemMetric.value, unit: systemMetric.unit,
                            fixedMaximum: systemMetric.maximum,
                            stepped: systemMetric == .pressure || systemMetric == .thermal)
                Text(systemMetric.explanation).font(.caption).foregroundStyle(.secondary)
                Text("Click a chart to inspect a recorded sample. Large ranges are reduced to at most 1,500 points; short events between samples may not be retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metricChart(_ value: (ActivitySnapshot) -> Double?, unit: String,
                             fixedMaximum: Double? = nil, stepped: Bool = false) -> some View {
        let data = ActivityTrendPoint.make(activity.history, hours: hours, value: value)
        let maximum = fixedMaximum ?? max(1, (data.map(\.value).max() ?? 1) * 1.1)
        return VStack(alignment: .leading, spacing: 4) {
          if data.isEmpty {
            Text("No comparable readings in this range yet.")
                .font(.caption).foregroundStyle(.secondary)
          }
          Chart(data) { point in
            LineMark(x: .value("Time", point.sample.sampledAt),
                     y: .value(unit, point.value), series: .value("Recorded interval", point.segment))
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(stepped ? .stepEnd : .linear)
            // Also show isolated readings on either side of a gap.
            PointMark(x: .value("Time", point.sample.sampledAt), y: .value(unit, point.value))
                .symbolSize(7).foregroundStyle(Color.accentColor)
            if selected?.id == point.id {
                PointMark(x: .value("Time", point.sample.sampledAt), y: .value(unit, point.value))
                    .foregroundStyle(.orange)
            }
        }
        .chartYScale(domain: 0...maximum)
        .chartLegend(.hidden)
        .frame(height: 125)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = gesture.location.x - geometry[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        selected = activity.history.min {
                            abs($0.sampledAt.timeIntervalSince(date)) < abs($1.sampledAt.timeIntervalSince(date))
                        }
                    })
            }
        }
        .accessibilityLabel("\(unit) history")
        }
    }

    private var rangeSummary: some View {
        let samples = activity.history
        let known = samples.filter { ["normal", "warning", "critical"].contains($0.memoryPressure) }.count
        let pressured = samples.filter { ["warning", "critical"].contains($0.memoryPressure) }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading, spacing: 10) {
            reading("Elevated pressure · samples", known > 0 ? "\(pressured) of \(known)" : nil)
            reading("Peak swap · displayed samples", samples.compactMap(\.swapUsed).max().map(fmt))
            reading("Lowest free storage", samples.compactMap(\.diskFree).min().map(fmt))
            reading("Recorded samples", "\(samples.count)")
        }
    }

    private var appHistory: some View {
        let trends = ActivityTrends.apps(in: activity.history, sortedBy: appSort, memoryMetric: appMemoryMetric)
        let app = trends.first { $0.id == selectedAppID } ?? trends.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Which apps use the most?").font(.headline)
                Spacer()
                Picker("Rank by", selection: $appSort) {
                    ForEach(ActivityTrends.Sort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 250)
            }
            Picker("Memory measure", selection: $appMemoryMetric) {
                ForEach(ActivityMemoryMetric.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 350)
            HStack {
                Text("App").frame(maxWidth: .infinity, alignment: .leading)
                Text("Average \(appMemoryMetric.short)").frame(width: 110, alignment: .trailing)
                Text("Peak \(appMemoryMetric.short)").frame(width: 110, alignment: .trailing)
                Text("Peak CPU").frame(width: 90, alignment: .trailing)
                Text("Memory reads").frame(width: 90, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary)
            ForEach(trends.prefix(6)) { row in
                Button { selectedAppID = row.id } label: {
                    HStack {
                        Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.averageBytes.map(fmt) ?? "—").frame(width: 110, alignment: .trailing)
                        Text(row.peakBytes.map(fmt) ?? "—").frame(width: 110, alignment: .trailing)
                        Text(row.peakCPU.map { String(format: "%.1f%%", $0) } ?? "—")
                            .frame(width: 90, alignment: .trailing)
                        Text("\(row.memoryObservations)").frame(width: 90, alignment: .trailing)
                    }.font(.callout.monospacedDigit()).padding(8).contentShape(Rectangle())
                        .background(row.id == app?.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .accessibilityLabel("Inspect \(row.name) history, average \(appMemoryMetric.short) \(row.averageBytes.map(fmt) ?? "unavailable"), peak \(row.peakBytes.map(fmt) ?? "unavailable"), \(row.memoryObservations) memory readings")
            }
            Text("\(appMemoryMetric.explanation) Averages use only observed, displayed samples, not the entire elapsed time. Missing entries do not mean zero use. Peaks may miss brief events or readings removed when a large range is reduced.")
                .font(.caption).foregroundStyle(.secondary)
            if let app {
                HStack {
                    Picker("Inspect app", selection: Binding(get: { app.id }, set: { selectedAppID = $0 })) {
                        ForEach(Array(trends.enumerated()), id: \.element.id) { index, trend in
                            Text("\(index + 1). \(trend.name)").tag(trend.id)
                        }
                    }.frame(maxWidth: 370)
                    Spacer()
                    Button("Inspect memory peak") { selected = app.peakMemorySample }
                        .disabled(app.peakMemorySample == nil)
                }
                Text("\(app.name) · \(appMemoryMetric.rawValue.lowercased())").font(.subheadline.bold())
                metricChart({ sample in
                    sample.apps.first { $0.id == app.id }.flatMap { appMemoryMetric.bytes($0) }.map {
                        Double($0) / 1_073_741_824
                    }
                }, unit: "GiB")
                Text("\(app.name) · CPU, 100% per core").font(.subheadline.bold())
                metricChart({ ActivityTrends.cpu(for: app.id, in: $0) }, unit: "%")
                Text("Seen in \(app.observations) of \(activity.history.count) samples · \(app.memoryObservations) memory readings · peak \(app.peakProcesses) processes · last seen \(app.lastSeen.formatted(date: .abbreviated, time: .shortened)). CPU has \(app.cpuObservations) comparable readings; older or uncalibrated CPU records remain gaps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func details(_ sample: ActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected == nil ? "Latest reading" : "Recorded reading").font(.headline)
            Text(sample.sampledAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
            if selected == nil, Date().timeIntervalSince(sample.sampledAt) > 75 {
                Label("Last reading is stale. Monitoring may be paused.", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 12) {
                reading("CPU · whole machine", sample.cpuPercent.map { String(format: "%.1f%%", $0) })
                reading("Occupied RAM · includes caches", sample.memoryUsed.map(fmt))
                reading("macOS memory pressure", HealthMemoryPressure(rawValue: sample.memoryPressure)?.title)
                reading("Swap", sample.swapUsed.map(fmt))
                reading("Compressed RAM", sample.compressedBytes.map(fmt))
                reading("Swap in", sample.swapInRate.map(rate))
                reading("Swap out", sample.swapOutRate.map(rate))
                reading("Free storage", sample.diskFree.map(fmt))
                reading("Disk read · readable processes", sample.diskReadRate.map(rate))
                reading("Disk write · readable processes", sample.diskWriteRate.map(rate))
                reading("Network download", sample.networkDownloadRate.map(rate))
                reading("Network upload", sample.networkUploadRate.map(rate))
                reading("Battery", sample.batteryPercent.map { "\($0)%" })
                reading("GPU", sample.gpuPercent.map { String(format: "%.1f%%", $0) })
                reading("Thermal state", sample.thermalState)
            }
            Text("Network: \(sample.networkScope). Process coverage: \(sample.readableProcesses) of \(sample.listedProcesses) readable; exited and inaccessible processes can be missing from I/O totals.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Leading apps · CPU uses 100% per fully occupied core").font(.subheadline.bold())
            ForEach(sample.apps) { app in
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text("\(app.processCount) processes").foregroundStyle(.secondary)
                    Text(ActivityTrends.cpu(for: app.id, in: sample).map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                        .monospacedDigit().frame(width: 90, alignment: .trailing)
                    Text(app.rss.map(fmt) ?? "Unavailable").monospacedDigit().frame(width: 100, alignment: .trailing)
                }.font(.callout)
            }
        }
    }
    private func reading(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Unavailable").font(.body.monospacedDigit())
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "Unavailable" }
        return fmt(Int64(value)) + "/s"
    }
    private var savedMoments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved moments").font(.headline)
            if activity.bookmarks.isEmpty { Text("Bookmark a spike or add context for a later investigation.").foregroundStyle(.secondary) }
            ForEach(activity.bookmarks.reversed()) { moment in
                HStack {
                    Button {
                        selected = moment.snapshot
                    } label: {
                        VStack(alignment: .leading) {
                            Text(moment.note.isEmpty ? "Saved reading" : moment.note).lineLimit(2)
                            Text(moment.snapshot.sampledAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Button("Remove") { activity.deleteMoment(moment) }.buttonStyle(.borderless)
                }.padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportJSON ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = exportJSON ? "FastMac-activity.json" : "FastMac-activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if exportJSON {
                try ActivityRepository.json(activity.history, includeAppNames: includeAppNames).write(to: url, options: .atomic)
            } else {
                try ActivityRepository.csv(activity.history, includeAppNames: includeAppNames).write(to: url, atomically: true, encoding: .utf8)
            }
            exportResult = "Exported \(activity.history.count) displayed samples."
        } catch { exportResult = "Export failed: " + error.localizedDescription }
    }
}
