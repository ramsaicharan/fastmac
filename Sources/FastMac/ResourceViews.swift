import SwiftUI
import AppKit
import Combine

@MainActor
final class ResourceDashboardModel: ObservableObject {
    @Published private(set) var counters: NetworkCounterSnapshot?
    @Published private(set) var network = NetworkRateSnapshot()
    @Published private(set) var battery = BatteryResourceSnapshot()
    @Published private(set) var gpu = GPUResourceSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    private var refreshTask: Task<Void, Never>?
    private var epoch = 0

    init(counters: NetworkCounterSnapshot? = nil, network: NetworkRateSnapshot = NetworkRateSnapshot(),
         battery: BatteryResourceSnapshot = BatteryResourceSnapshot(), gpu: GPUResourceSnapshot = GPUResourceSnapshot(),
         lastUpdated: Date? = nil) {
        self.counters = counters; self.network = network; self.battery = battery
        self.gpu = gpu; self.lastUpdated = lastUpdated
    }

    /// A one-time reading and one baseline interval. The shared activity monitor
    /// owns recurring sampling; this detail panel never starts another timer.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        epoch &+= 1
        let request = epoch
        refreshTask = Task { [weak self] in
            let first = await Task.detached(priority: .utility) {
                (ResourceProbe.networkCounters(), ResourceProbe.battery(), ResourceProbe.gpu())
            }.value
            guard let self, !Task.isCancelled, self.epoch == request else { return }
            self.counters = first.0; self.battery = first.1; self.gpu = first.2
            self.network = NetworkRateSnapshot(status: "Measuring a one-second interval…")
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let second = await Task.detached(priority: .utility) { ResourceProbe.networkCounters() }.value
            guard !Task.isCancelled, self.epoch == request else { return }
            self.counters = second
            self.network = ResourceProbe.networkRate(current: second, previous: first.0)
            self.lastUpdated = Date(); self.isRefreshing = false
        }
    }

    func cancel() {
        epoch &+= 1
        refreshTask?.cancel(); refreshTask = nil
        isRefreshing = false
    }
}

@MainActor
struct ResourceDetailsView: View {
    @StateObject private var model: ResourceDashboardModel

    init(model: ResourceDashboardModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ResourceDashboardModel())
    }

    var body: some View {
        ScrollView { snapshotContent }
            .onAppear { model.refresh() }
            .onDisappear { model.cancel() }
    }

    var snapshotContent: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Resources").font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("Network throughput, battery condition and available graphics readings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing)
                }
                networkPanel
                batteryPanel
                graphicsPanel
                HStack {
                    Text("Readings refresh when you open this panel or choose Refresh.")
                    Spacer()
                    if let at = model.lastUpdated { Text("Updated \(at.formatted(date: .omitted, time: .standard))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(26)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var networkPanel: some View {
        resourcePanel(title: "Network", icon: "network") {
            HStack(spacing: 24) {
                resourceMetric("Download", value: rate(model.network.downloadBytesPerSecond), detail: "Bytes received per second")
                resourceMetric("Upload", value: rate(model.network.uploadBytesPerSecond), detail: "Bytes sent per second")
            }
            Text(model.network.status).font(.caption).foregroundStyle(.secondary)
            if let counters = model.counters {
                Text(counters.scopeDescription).font(.caption.weight(.medium))
                Text(counters.counterSource).font(.caption).foregroundStyle(.secondary)
            }
            Text("These are interface throughput readings. Virtual interfaces, VPN tunnels, loopback and peer-to-peer links are excluded to avoid counting traffic twice. With a VPN, the physical transport includes its overhead. This panel does not attribute traffic to apps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var batteryPanel: some View {
        resourcePanel(title: "Battery", icon: "battery.75percent") {
            if model.battery.present == false {
                Label("No internal battery", systemImage: "desktopcomputer").font(.title3.weight(.medium))
                Text("Desktop Macs and external UPS devices are not treated as laptop batteries.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.battery.present == nil {
                Text("Battery reading unavailable").font(.title3.weight(.medium))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20)], alignment: .leading, spacing: 20) {
                    resourceMetric("Charge", value: model.battery.percent.map { "\($0)%" } ?? "Unavailable", detail: powerState)
                    resourceMetric("Capacity estimate", value: model.battery.healthPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable", detail: "Raw full-charge / design capacity")
                    resourceMetric("Cycle count", value: model.battery.cycleCount.map(String.init) ?? "Unavailable", detail: "Reported by the battery controller")
                    resourceMetric("Temperature", value: model.battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "Unavailable", detail: "Needs a validated hardware counter")
                }
                Text("Capacity is a hardware estimate and can vary with charging and calibration. It can differ from Maximum Capacity in macOS Battery Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.battery.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var graphicsPanel: some View {
        resourcePanel(title: "Graphics", icon: "cpu") {
            resourceMetric("GPU utilization", value: model.gpu.utilizationPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable", detail: "Busiest exposed device")
            Text(model.gpu.detail).font(.caption).foregroundStyle(.secondary)
            Text("GPU counters vary by Mac and macOS release. Missing readings remain unavailable; thermal state elsewhere in FastMac does not represent a temperature in degrees.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var powerState: String {
        if model.battery.isCharging == true { return "Charging" }
        if model.battery.isOnBattery == true { return "Running on battery" }
        if model.battery.isOnBattery == false { return "Connected to power" }
        return "Power state unavailable"
    }

    private func resourcePanel<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func resourceMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max), max(0, value))), countStyle: .decimal) + "/s"
    }
}

@MainActor
final class ProjectsModel: ObservableObject {
    @Published private(set) var result: ProjectDiscoveryResult?
    @Published private(set) var isRefreshing = false
    @Published var actionMessage: String?
    @Published private(set) var stoppingPID: pid_t?
    private var epoch = 0

    init(result: ProjectDiscoveryResult? = nil) { self.result = result }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        epoch &+= 1
        let request = epoch
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { ProjectProbe.discover() }.value
            guard let self, self.epoch == request else { return }
            self.result = found; self.isRefreshing = false
        }
    }

    func stop(_ process: RuntimeProjectProcess) {
        guard stoppingPID == nil else { return }
        stoppingPID = process.pid
        Task { [weak self] in
            let outcome = await PerfActions.terminate(identity: process.identity, name: process.command, force: false)
            guard let self else { return }
            self.actionMessage = outcome.message; self.stoppingPID = nil
            self.refresh()
        }
    }
}

@MainActor
struct ProjectsView: View {
    var agentSessions: AgentSessionsService?
    @State private var showingSessions = false
    @StateObject private var model: ProjectsModel
    @State private var pendingStop: RuntimeProjectProcess?

    init(model: ProjectsModel? = nil, agentSessions: AgentSessionsService? = nil) {
        self.agentSessions = agentSessions
        _model = StateObject(wrappedValue: model ?? ProjectsModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            if agentSessions != nil {
                Picker("Projects view", selection: $showingSessions) {
                    Text("Servers & ports").tag(false)
                    Text("Agent sessions").tag(true)
                }.pickerStyle(.segmented).padding(16)
            }
            ScrollView {
                if showingSessions, let agentSessions { AgentSessionsView(service: agentSessions).padding(26) }
                else { snapshotContent }
            }
        }
        .alert("Stop this server?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })) {
            Button("Cancel", role: .cancel) { pendingStop = nil }
            Button("Stop server", role: .destructive) {
                if let process = pendingStop { model.stop(process) }
                pendingStop = nil
            }
        } message: {
            if let process = pendingStop {
                Text("\(process.runtime) · PID \(process.pid)\n\(process.directory ?? "Working directory unavailable")\nPorts: \(process.endpoints.map { String($0.port) }.joined(separator: ", "))\n\n\(PerfActions.confirmation(identity: process.identity, force: false))")
            }
        }
        .alert("Server action", isPresented: Binding(get: { model.actionMessage != nil }, set: { if !$0 { model.actionMessage = nil } })) {
            Button("OK") { model.actionMessage = nil }
        } message: { Text(model.actionMessage ?? "") }
    }

    var snapshotContent: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Projects & Ports").font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("Inspect local development servers and choose what to keep running.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Label("Refresh servers", systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing || model.stoppingPID != nil)
                }
                Text("Refresh finds TCP listeners in recognized Node.js, Python, Ruby, PHP, Java, Go, Bun, Deno, .NET and Swift runtime executables. Access is limited to what macOS permits. Servers without listening ports and compiled binaries with custom names may be omitted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let result = model.result {
                    HStack {
                        Label(result.message, systemImage: result.incomplete ? "exclamationmark.triangle" : "checkmark.circle")
                        Spacer()
                        Text(result.at.formatted(date: .omitted, time: .standard))
                    }
                    .font(.caption).foregroundStyle(result.incomplete ? Color.orange : Color.secondary)
                    if result.groups.isEmpty {
                        ContentUnavailableView("No recognized listening servers", systemImage: "network", description: Text("Start a local development server, then choose Refresh servers. Inaccessible processes may not appear."))
                    }
                    ForEach(result.groups) { project in projectCard(project) }
                } else {
                    ContentUnavailableView("Inspect your running projects", systemImage: "terminal", description: Text("Choose Refresh servers for a bounded local check. No folders are scanned."))
                }
                Text("Groups use the process's current working directory as evidence. A folder can contain several projects, and a listening port does not mean a process is safe to stop. Arguments, environment variables and project file contents are not read or saved.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Resident memory (RSS) is a snapshot. Shared framework pages can appear in more than one process, so the group sum can exceed actual memory use. Age is time since the verified process started; missing readings remain unavailable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(26)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func projectCard(_ project: RuntimeProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(project.title, systemImage: project.directory == nil ? "questionmark.folder" : "folder")
                    .font(.headline)
                Spacer()
                if let directory = project.directory {
                    Button("Reveal folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) }
                        .controlSize(.small)
                }
            }
            if let directory = project.directory {
                Text(directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This process could not be assigned a verified working directory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Resident memory: \(project.residentBytes.map(fmt) ?? "Unavailable")")
                    .font(.callout.weight(.medium)).monospacedDigit()
                Text("\(project.residentCoverage) of \(project.processes.count) processes readable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(project.processes) { process in
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(process.runtime).font(.callout.weight(.semibold))
                        Text("\(process.command) · PID \(process.pid)").font(.caption).foregroundStyle(.secondary)
                        Text("RSS \(process.residentBytes.map(fmt) ?? "Unavailable") · Age \(ageLabel(process))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(process.endpoints) { endpoint in
                            HStack(spacing: 8) {
                                Text(endpoint.address).font(.caption.monospaced()).textSelection(.enabled)
                                if let url = endpoint.localhostURL {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                        .controlSize(.small)
                                        .help("Open \(url.absoluteString) in your browser. This listener may not speak HTTP.")
                                        .accessibilityLabel("Open localhost port \(endpoint.port)")
                                }
                            }
                        }
                    }
                    if process.canStop {
                        Button(model.stoppingPID == process.pid ? "Stopping…" : "Stop…") { pendingStop = process }
                            .controlSize(.small).disabled(model.stoppingPID != nil)
                            .help("Review before asking only this process to stop")
                    } else {
                        Text("Inspect only").font(.caption).foregroundStyle(.secondary)
                            .help("The process identity or ownership could not be verified.")
                    }
                }
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func ageLabel(_ process: RuntimeProjectProcess) -> String {
        guard let at = model.result?.at, let seconds = process.age(at: at) else { return "Unavailable" }
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes / 60 % 24)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return minutes > 0 ? "\(minutes)m" : "\(Int(seconds))s"
    }
}
