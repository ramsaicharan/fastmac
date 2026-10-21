import SwiftUI
import AppKit

struct AppHelperSnapshot: Identifiable {
    let group: PerfAppGroup
    let members: [PerfProcSample]
    let at: Date
    var id: String { group.id }
    var roles: [AppHelperRole] {
        Dictionary(grouping: members, by: \.helperRole).map { name, members in
            AppHelperRole(name: name, members: members)
        }.sorted { $0.rss == $1.rss ? $0.name < $1.name : $0.rss > $1.rss }
    }
}

struct AppHelperRole: Identifiable {
    let name: String
    let members: [PerfProcSample]
    var id: String { name }
    var waiting: Int { members.filter { $0.runState == .waiting }.count }
    var rss: Int64 { members.reduce(0) { $0 + $1.rss } }
    var footprint: Int64? {
        members.allSatisfy { $0.footprint != nil } ? members.reduce(0) { $0 + ($1.footprint ?? 0) } : nil
    }
    var cpu: Double? {
        members.allSatisfy(\.cpuAvailable) ? members.reduce(0) { $0 + $1.cpuPercent } : nil
    }
}

struct AppHelpersView: View {
    let snapshot: AppHelperSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var confirmQuit = false
    @State private var quitting = false
    @State private var actionMessage: String?

    private var mainIdentity: ProcessIdentity? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == snapshot.group.id
        }) else { return nil }
        return snapshot.members.first { $0.pid == app.processIdentifier && $0.owned && $0.pid != getpid() }?.identity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(snapshot.group.name) and its helpers").font(.title2.bold())
                    Text("Snapshot \(snapshot.at.formatted(date: .omitted, time: .standard)) · \(snapshot.members.count) readable processes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Waiting means alive and waiting for an event. It does not mean active AI work, unused memory, or permission to stop a helper.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Role"); Text("Count"); Text("Waiting"); Text("CPU¹"); Text("Footprint")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider().gridCellColumns(5)
                ForEach(snapshot.roles) { role in
                    GridRow {
                        Text(role.name).lineLimit(1)
                        Text("\(role.members.count)")
                        Text("\(role.waiting)")
                        Text(role.cpu.map { String(format: "%.2f%%", $0) } ?? "—")
                        Text(role.footprint.map(fmt) ?? "—")
                    }.font(.callout).monospacedDigit()
                }
            }
            Text("¹ 100% CPU = one core. Waiting is a momentary state; CPU measures the recent interval. Footprint includes compressed allocations. Missing measurements stay unavailable. Reopen this detail to refresh.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Release helpers through the owning app").font(.headline)
            Text("Close or archive finished chats in the app to let it release session resources. Archiving keeps disk history. If the app still retains excessive memory after work is saved, quit it normally and reopen it. Exact helper shutdown timing is controlled by the app.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Suspending helpers keeps their memory allocated. Killing an individual helper can discard tool state, interrupt a request or cause it to restart. FastMac does not automatically stop waiting processes.")
                .font(.caption).foregroundStyle(.secondary)
            if let actionMessage { Text(actionMessage).font(.callout).textSelection(.enabled) }
            HStack {
                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == snapshot.group.id }) {
                    Button("Open \(snapshot.group.name)") { app.activate(options: [.activateAllWindows]) }
                }
                Spacer()
                if quitting { ProgressView().controlSize(.small) }
                Button("Quit app…") { confirmQuit = true }.disabled(mainIdentity == nil || quitting)
            }
        }.padding(24).frame(width: 650)
            .alert("Quit \(snapshot.group.name)?", isPresented: $confirmQuit) {
                Button("Cancel", role: .cancel) {}
                Button("Request Quit", role: .destructive) {
                    guard let identity = mainIdentity else { actionMessage = "The app changed or exited. Refresh before trying again."; return }
                    quitting = true
                    Task {
                        let result = await PerfActions.terminate(identity: identity, name: snapshot.group.name, force: false)
                        actionMessage = result.message; quitting = false
                    }
                }
            } message: {
                Text("This closes the whole app, including active chats and tools. Save ongoing work first. FastMac requests a normal quit and does not force it to exit.")
            }
    }
}
