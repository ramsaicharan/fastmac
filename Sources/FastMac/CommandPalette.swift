import SwiftUI
import Carbon

struct PaletteEntry: Identifiable {
    enum Action { case navigate(ViewKind), quit(QuickActionApp), server(RuntimeProjectProcess), settings, models }
    let id: String
    let title: String
    let detail: String
    let icon: String
    let action: Action
}

enum PaletteSearch {
    static func filter(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.filter { entry in terms.allSatisfy { (entry.title + " " + entry.detail).localizedCaseInsensitiveContains($0) } }
            .sorted { a, b in
                let ap = !query.isEmpty && a.title.lowercased().hasPrefix(query.lowercased())
                let bp = !query.isEmpty && b.title.lowercased().hasPrefix(query.lowercased())
                return ap != bp ? ap : a.id < b.id
            }
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var activity: ActivityMonitor
    @StateObject private var apps = QuickActionsModel()
    @StateObject private var projects = ProjectsModel()
    @State private var query = ""
    @State private var selection: String?
    @State private var pending: PaletteEntry?
    @State private var busy = false
    @State private var message: String?
    @FocusState private var searchFocused: Bool

    private var entries: [PaletteEntry] {
        var list = ViewKind.allCases.map { PaletteEntry(id: "0-" + $0.rawValue, title: "Open " + $0.title,
            detail: $0 == .insights ? "diagnose slow Mac attention evidence changes" : "Navigate to \($0.title)", icon: $0.icon, action: .navigate($0)) }
        list.append(.init(id: "0-settings", title: "Open Settings", detail: "Permissions, monitoring and preferences", icon: "gearshape", action: .settings))
        list.append(.init(id: "0-models", title: "Inspect loaded AI models", detail: "Ollama, LM Studio · runtime memory and unload review", icon: "sparkles", action: .models))
        list += apps.apps.map { .init(id: "1-" + $0.id, title: "Quit " + $0.name, detail: "Review a normal quit request · PID \($0.identity.pid)", icon: "app", action: .quit($0)) }
        list += (projects.result?.groups.flatMap(\.processes) ?? []).map { process in
            .init(id: "2-\(process.pid)", title: "Stop \(process.runtime) server",
                  detail: "Ports \(process.endpoints.map { String($0.port) }.joined(separator: ", ")) · \(process.directory ?? "Unknown project") · PID \(process.pid)", icon: "terminal", action: .server(process))
        }
        return list
    }
    private var results: [PaletteEntry] { PaletteSearch.filter(entries, query: query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search pages, apps, actions or ports", text: $query).textFieldStyle(.plain)
                    .font(.title3).focused($searchFocused).onSubmit { executeSelected() }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Divider()
            if results.isEmpty { ContentUnavailableView.search(text: query).frame(height: 240) }
            else {
                List(selection: $selection) {
                    ForEach(results) { entry in
                        Button { choose(entry) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title)
                                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            } icon: { Image(systemName: entry.icon).frame(width: 22) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).tag(entry.id).disabled(busy)
                    }
                }.listStyle(.plain).frame(height: 340)
            }
            HStack {
                Button(projects.isRefreshing ? "Reading ports…" : "Include running servers") { projects.refresh() }
                    .disabled(projects.isRefreshing || busy)
                Spacer()
                Text("↑↓ Choose · Return Review · Esc Close").font(.caption).foregroundStyle(.secondary)
            }
            Text(store.commandShortcutRegistered ? "Open from other apps with ⌥⌘K" : "Use ⌘K in FastMac. The global shortcut is unavailable or already in use.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let message = projects.result?.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(22).frame(width: 620)
        .interactiveDismissDisabled(busy)
        .onAppear { apps.refresh(snapshot: activity.latest); searchFocused = true; selection = results.first?.id }
        .onChange(of: query) { _, _ in selection = results.first?.id }
        .onMoveCommand { direction in
            let values = results
            guard !values.isEmpty else { return }
            let index = values.firstIndex(where: { $0.id == selection }) ?? 0
            if direction == .down { selection = values[min(index + 1, values.count - 1)].id }
            if direction == .up { selection = values[max(0, index - 1)].id }
        }
        .alert(pending?.title ?? "Review action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Confirm", role: .destructive) { if let item = pending { perform(item) }; pending = nil }
        } message: { Text(confirmation) }
    }
    private var confirmation: String {
        guard let pending else { return "" }
        switch pending.action {
        case .quit(let app): return "\(app.name) · PID \(app.identity.pid)\n" + PerfActions.confirmation(identity: app.identity, force: false)
        case .server(let process): return pending.detail + "\n" + PerfActions.confirmation(identity: process.identity, force: false)
        default: return ""
        }
    }
    private func executeSelected() { if let item = results.first(where: { $0.id == selection }) ?? results.first { choose(item) } }
    private func choose(_ entry: PaletteEntry) {
        guard !busy else { return }
        switch entry.action {
        case .navigate(let view): store.view = view; dismiss()
        case .models: store.aiShowsLoadedModels = true; store.view = .aiStorage; dismiss()
        case .settings: dismiss(); DispatchQueue.main.async { MenuActions.shared.openSettings() }
        case .quit, .server: pending = entry
        }
    }
    private func perform(_ entry: PaletteEntry) {
        busy = true
        Task { @MainActor in
            switch entry.action {
            case .quit(let app): message = await apps.terminate(app, force: false).message
            case .server(let process): message = await PerfActions.terminate(identity: process.identity, name: process.command, force: false).message
            default: break
            }
            busy = false
        }
    }
}

/// Carbon's registered hotkey does not require Accessibility or global key logging.
@MainActor
final class CommandShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<CommandShortcut>.fromOpaque(context).takeUnretainedValue().action() }
            return noErr
        }, 1, &type, pointer, &handler)
        if status == noErr {
            let id = EventHotKeyID(signature: 0x444D4150, id: 1)
            RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        }
    }
    var registered: Bool { hotKey != nil }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
