import SwiftUI
import Combine

@MainActor
final class AdvancedResourcesModel: ObservableObject {
    @Published private(set) var docker: DockerOverviewSnapshot?
    @Published private(set) var sleep: SleepAssertionsSnapshot?
    @Published private(set) var browsers: BrowserResourcesSnapshot?
    @Published private(set) var refreshingDocker = false
    @Published private(set) var refreshingSleep = false
    @Published private(set) var refreshingBrowsers = false

    init(docker: DockerOverviewSnapshot? = nil, sleep: SleepAssertionsSnapshot? = nil,
         browsers: BrowserResourcesSnapshot? = nil) {
        self.docker = docker; self.sleep = sleep; self.browsers = browsers
    }

    func refreshDocker() {
        guard !refreshingDocker else { return }
        refreshingDocker = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { DockerResourceProbe.refresh() }.value
            guard let self else { return }
            self.docker = found; self.refreshingDocker = false
        }
    }

    func refreshSleep() {
        guard !refreshingSleep else { return }
        refreshingSleep = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { SleepAssertionProbe.refresh() }.value
            guard let self else { return }
            self.sleep = found; self.refreshingSleep = false
        }
    }

    func refreshBrowsers() {
        guard !refreshingBrowsers else { return }
        refreshingBrowsers = true
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { BrowserResourceProbe.refresh() }.value
            guard let self else { return }
            self.browsers = found; self.refreshingBrowsers = false
        }
    }
}

@MainActor
struct AdvancedResourcesView: View {
    @StateObject private var model: AdvancedResourcesModel

    init(model: AdvancedResourcesModel? = nil) {
        _model = StateObject(wrappedValue: model ?? AdvancedResourcesModel())
    }

    var body: some View { ScrollView { snapshotContent } }

    var snapshotContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Advanced Tools").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("On-demand insights into containers, power assertions and browser helpers.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            dockerPanel
            sleepPanel
            browserPanel
            Text("These tools inspect local state when you choose Refresh. Results stay in this view and are not added to activity history.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var dockerPanel: some View {
        panel(title: "Docker containers", icon: "shippingbox") {
            HStack {
                Text("Container state and a single Docker resource reading.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                refreshButton("Refresh Docker", busy: model.refreshingDocker, action: model.refreshDocker)
            }
            if let result = model.docker {
                status(result.message, at: result.at, partial: result.incomplete)
                if let context = result.contextName { Text("Saved context: \(context)").font(.caption.weight(.medium)) }
                if !result.containers.isEmpty {
                    ForEach(result.containers) { container in
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(container.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(container.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("\(container.image) · \(container.id.prefix(12))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            HStack(spacing: 22) {
                                reading("CPU", value: container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
                                reading("Memory / limit", value: container.memoryUsage ?? "Unavailable")
                                reading("Network I/O", value: container.networkIO ?? "Unavailable")
                                reading("Block I/O", value: container.blockIO ?? "Unavailable")
                            }
                            if !container.ports.isEmpty {
                                Text("Ports: \(container.ports)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                Text("Choose Refresh Docker to inspect the saved Docker context and its local Unix socket.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Docker CPU can exceed 100%. Memory follows Docker's VM accounting; I/O values are cumulative. Shell-only context overrides are not inherited. This overview is read-only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sleepPanel: some View {
        panel(title: "Sleep & display assertions", icon: "moon.zzz") {
            HStack {
                Text("See the macOS signals that influence sleep and display behavior.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                refreshButton("Refresh assertions", busy: model.refreshingSleep, action: model.refreshSleep)
            }
            if let result = model.sleep {
                status(result.message, at: result.at, partial: result.incomplete)
                if result.available {
                    if result.assertions.isEmpty {
                        Text("No process-owned assertions appeared in this snapshot.").font(.callout)
                    }
                    ForEach(result.assertions) { assertion in
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(assertion.processName) · PID \(assertion.pid)").font(.callout.weight(.medium))
                                Text(SleepAssertionProbe.meaning(assertion.kind)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(assertion.kind).font(.caption.monospaced())
                                Text("Held \(assertion.duration)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let active = result.summary.filter { $0.value > 0 }.map(\.key).sorted()
                    Text(active.isEmpty ? "System summary: no active assertion categories." : "Active system categories: \(active.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Choose Refresh assertions for a read-only macOS power summary.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Assertions often reflect ordinary playback, downloads or user activity. Descriptive assertion names are omitted because they can contain document titles. No power setting or process is changed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var browserPanel: some View {
        panel(title: "Browser process categories", icon: "globe") {
            HStack {
                Text("Group known browser executables by the helper role their names expose.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                refreshButton("Refresh browsers", busy: model.refreshingBrowsers, action: model.refreshBrowsers)
            }
            if let result = model.browsers {
                status(result.message, at: result.at, partial: result.incomplete)
                if result.groups.isEmpty { Text("No recognized browser processes appeared in this snapshot.").font(.callout) }
                ForEach(result.groups) { group in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.browser).font(.callout.weight(.medium))
                            Text(group.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(group.pids.count) processes").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(group.residentBytes.map(fmt) ?? "Unavailable").font(.callout.weight(.medium)).monospacedDigit()
                            Text("RSS · \(group.readableCount) readable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Choose Refresh browsers to inspect accessible processes owned by you.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Categories identify executable roles, not named tabs, sites or extensions. Shared WebKit services cannot be assigned to Safari from their path alone. RSS sums can count shared pages twice.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func panel<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func refreshButton(_ label: String, busy: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            if busy { ProgressView().controlSize(.small) }
            Button(label, action: action).disabled(busy).controlSize(.small)
        }
    }

    private func status(_ message: String, at: Date, partial: Bool) -> some View {
        HStack(alignment: .top) {
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(at.formatted(date: .omitted, time: .standard)).monospacedDigit()
        }
        .font(.caption).foregroundStyle(partial ? Color.orange : Color.secondary)
    }

    private func reading(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
        }
    }
}
