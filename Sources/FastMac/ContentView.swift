import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var health: HealthMonitor
    @ObservedObject var aiStorage: AIStorageService
    @ObservedObject var activity: ActivityMonitor
    var allowsOnboarding = true
    // Diagnostics inject a service and suppress automatic reads/preferences;
    // normal dashboard construction keeps the existing behavior.
    var startsAutomaticWork = true
    var startupService: StartupService?
    @StateObject private var agentSessions = AgentSessionsService()
    @State private var showingOnboarding = false
    @State private var purgeResult: String?
    @State private var confirmPurge = false
    @State private var showInspector = false
    @AppStorage("FastMac.Sidebar.StorageViewsExpanded") private var storageViewsExpanded = false
    @AppStorage("FastMac.Sidebar.ToolsExpanded") private var toolsExpanded = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if store.view.needsScan || [.quick, .apps].contains(store.view) {
                    toolbar; Divider()
                    if let r = store.result, let disk = r.disk {
                        DiskOverviewBar(result: r, disk: disk, onScanMac: { store.scanMac() },
                                        onRequestAccess: { store.fullDiskAccessPrompt = .afterScan })
                        Divider()
                    }
                }
                if store.view.isTree { crumbBar; Divider() }
                ZStack {
                    if !store.view.needsScan || store.result != nil {
                        detailBody.id(store.revision)
                    } else {
                        welcome
                    }
                    if store.progress.running { scanOverlay }
                }
                if !store.picks.isEmpty { Divider(); selectionBar }
            }
            // A scroll/table destination may otherwise donate its ideal content
            // height to NavigationSplitView and move the sidebar offscreen.
            .frame(minHeight: 0, maxHeight: .infinity)
            .background(DS.Palette.canvas)
            .navigationTitle("FastMac — \(store.view.title)")
        }
        .inspector(isPresented: $showInspector) {
            InspectorPane(onPurge: { confirmPurge = true })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .frame(minWidth: 900, minHeight: 640)
        .onChange(of: store.view) { _, v in
            showInspector = v.isTree
            if startsAutomaticWork {
                revealSidebarSelection(v)
                store.ensureStandaloneAnalysis(for: v)
            }
        }
        .onDisappear { agentSessions.stop() }
        .onAppear {
            if startsAutomaticWork {
                revealSidebarSelection(store.view)
                store.ensureStandaloneAnalysis(for: store.view)
            }
            showingOnboarding = allowsOnboarding && OnboardingView.shouldShow
        }
        .sheet(item: $store.fullDiskAccessPrompt) { reason in
            FullDiskAccessSheet(reason: reason,
                onScan: { store.fullDiskAccessPrompt = nil; store.scan(path: "/") },
                onScanWithout: { store.scanMacWithoutFullDiskAccess() },
                onClose: { store.fullDiskAccessPrompt = nil })
        }
        .sheet(isPresented: $store.showingCommandPalette) { CommandPaletteView(activity: activity).environmentObject(store) }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(onDismiss: { showingOnboarding = false })
        }
        .alert("Move \(store.staged.count) items to the Trash?",
               isPresented: $confirmPurge) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash") { doPurge() }
        } message: {
            Text("""
                 \(fmt(store.stagedBytes)) will be moved to the Trash.

                 What happens: \(RiskNote.trash.what)
                 Undo: \(RiskNote.trash.undo)

                 Every path is re-checked against the safety guard immediately before it is touched. Disk space is released only after you empty the Trash in Finder.
                 """)
        }
        .alert("Cleanup complete", isPresented: .constant(purgeResult != nil)) {
            Button("OK") { purgeResult = nil }
        } message: { Text(purgeResult ?? "") }
    }

    // MARK: pieces

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.blue)
                    .frame(width: 37, height: 37)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("FastMac").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Your Mac, in view").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 17).padding(.top, 20).padding(.bottom, 16)
            Button { store.showingCommandPalette = true } label: { Label("Search & commands", systemImage: "magnifyingglass") }
                .buttonStyle(.borderless).padding(.horizontal, 18).padding(.bottom, 10)

            List(selection: Binding<ViewKind?>(get: { store.view }, set: { if let view = $0 { store.view = view } })) {
                Section("Everyday") {
                    ForEach([ViewKind.health, .insights, .activity, .memory, .performance, .resources, .projects]) { view in
                        sidebarRow(view)
                    }
                }
                Section("Storage") {
                    ForEach([ViewKind.cleanup, .aiStorage, .quick, .folders, .apps]) { view in
                        sidebarRow(view)
                    }
                    DisclosureGroup(isExpanded: $storageViewsExpanded) {
                        ForEach(secondaryStorageViews) { view in sidebarRow(view) }
                    } label: {
                        Label("More storage views", systemImage: "square.grid.2x2")
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $toolsExpanded) {
                        ForEach(secondaryTools) { view in sidebarRow(view) }
                    } label: {
                        Label("More tools", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(.blue)
        }
        .navigationSplitViewColumnWidth(min: 205, ideal: 218, max: 248)
    }

    private var secondaryStorageViews: [ViewKind] {
        [.categories, .top, .treemap, .sunburst, .flame, .bubbles, .mindmap, .age, .dupes, .history]
    }

    private var secondaryTools: [ViewKind] { [.startup, .advanced, .maintenance, .admin] }

    private func sidebarRow(_ view: ViewKind) -> some View {
        HStack(spacing: 8) {
            Label(view.title, systemImage: view.icon)
                .symbolRenderingMode(.hierarchical)
            Spacer(minLength: 0)
            if view == .cleanup && !store.staged.isEmpty {
                Text(store.staged.count.formatted())
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .accessibilityLabel("\(store.staged.count) queued items")
            }
        }
        .padding(.vertical, 2)
        .tag(view)
    }

    /// Menu and in-page links can navigate directly to a collapsed child. Reveal
    /// its selection so the sidebar always shows where the user landed.
    private func revealSidebarSelection(_ view: ViewKind) {
        if secondaryStorageViews.contains(view) { storageViewsExpanded = true }
        if secondaryTools.contains(view) { toolsExpanded = true }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.xs) {
            Button { store.scanMac() } label: { Label("Scan Mac", systemImage: "internaldrive") }
                .buttonStyle(DSButtonStyle(kind: .primary, compact: true))
                .help("Measure everything on the startup disk")
                .disabled(store.progress.running || store.refreshing)
            Button { store.scan(path: NSHomeDirectory()) } label: { Label("Home", systemImage: "house") }
                .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                .help("Measure only your home folder")
                .disabled(store.progress.running || store.refreshing)
            Button { chooseFolder() } label: { Label("Folder…", systemImage: "folder") }
                .buttonStyle(DSButtonStyle(kind: .secondary, compact: true))
                .help("Choose any folder or external drive to measure")
                .disabled(store.progress.running || store.refreshing)

            if let r = store.result {
                Divider().frame(height: 16).padding(.horizontal, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scopeTitle(r)).font(.dsCaptionEmphasis).lineLimit(1)
                        .help(r.root.path)
                    Text("\(fmt(r.bytes)) · \(fmtCount(r.files)) files · \(String(format: "%.0fs", r.elapsed))")
                        .font(.dsCaption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Button {
                    if let c = store.current { store.refresh(c) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DSIconButtonStyle(size: 26))
                    .disabled(store.refreshing || store.progress.running)
                    .help("Re-measure this folder — use it when something changed outside FastMac")
                    .accessibilityLabel("Refresh")
            }
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.small)
                Text("re-measuring").font(.caption).foregroundStyle(.secondary)
            }
            if store.analysing {
                ProgressView().controlSize(.small)
                Text(store.progress.phase).font(.caption).foregroundStyle(.secondary)
            }
            RiskLegend()
            if !store.staged.isEmpty {
                Text("\(store.staged.count) staged").font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(Capsule())
            }
            if let banner = store.banner {
                Text(banner).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(banner)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.prompt = "Scan"
        if p.runModal() == .OK, let u = p.url { store.scan(path: u.path) }
    }

    /// "Macintosh HD", "Home folder" or a short path — never a bare "~".
    private func scopeTitle(_ r: ScanResult) -> String {
        if r.isWholeDisk { return r.root.name }
        if r.root.path == NSHomeDirectory() { return "Home folder" }
        return r.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var crumbBar: some View {
        HStack(spacing: 5) {
            Button { store.up() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(store.current?.parent == nil)
            ForEach(Array(store.crumbs.enumerated()), id: \.offset) { i, node in
                if i > 0 { Text("›").foregroundStyle(.tertiary) }
                Button(node.name) { store.goTo(node) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(i == store.crumbs.count - 1 ? Color.primary : Color.accentColor)
                    .fontWeight(i == store.crumbs.count - 1 ? .semibold : .regular)
            }
            if let c = store.current {
                Text(fmt(c.size)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var detailBody: some View {
        switch store.view {
        case .health: HealthView(health: health)
        case .insights: InsightsView(health: health, activity: activity, automaticallyLoads: startsAutomaticWork)
        case .aiStorage: AIStorageView(store: store, service: aiStorage)
        case .cleanup: CleanupView(onPurge: { confirmPurge = true })
        case .folders:  FoldersView()
        case .treemap:  TreemapView()
        case .sunburst: SunburstView()
        case .flame:    FlameView()
        case .bubbles:  BubbleView()
        case .mindmap:  MindMapView()
        case .top:      TopSizesView()
        case .age:      AgeMapView()
        case .quick:    QuickWinsView()
        case .dupes:    DuplicatesView()
        case .apps:     AppsView(automaticallyLoads: startsAutomaticWork)
        case .memory:   MemoryView(health: health)
        case .categories:
            CategoriesView(onStage: { paths, reason in store.stage(paths, reason: reason) })
        case .startup:     StartupView(service: startupService, automaticallyScans: startsAutomaticWork)
        case .performance: PerfView()
        case .maintenance: MaintenanceView(automaticallyLoads: startsAutomaticWork)
        case .history:     HistoryView(onScanAgain: { path in
            store.view = .folders
            store.scan(path: path)
        })
        case .activity:    ActivityView(activity: activity)
        case .resources:   ResourceDetailsView()
        case .projects:    ProjectsView(agentSessions: agentSessions)
        case .advanced:    AdvancedResourcesView()
        case .admin:       PrivilegedActionsView()
        }
    }

    private var welcome: some View {
        VStack(spacing: DS.Space.md) {
            IconPlate(symbol: "internaldrive", size: 64)
            VStack(spacing: DS.Space.xxs + 2) {
                Text("See where your space went").font(.dsTitle)
                Text("Scan your whole Mac to account for every gigabyte — your files, apps, system data and what macOS keeps for itself.")
                    .font(.dsBody).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: DS.Space.xs) {
                Button { store.scanMac() } label: { Label("Scan Entire Mac", systemImage: "internaldrive") }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                Button { store.scan(path: NSHomeDirectory()) } label: { Label("Home Folder Only", systemImage: "house") }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
            .padding(.top, DS.Space.xxs)
            Text("Scans only read sizes. Nothing is removed unless you review it and confirm.")
                .font(.dsCaption).foregroundStyle(.tertiary)
        }
        .padding(DS.Space.xl)
    }

    private var scanOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("\(fmtCount(store.progress.files)) files · \(fmt(store.progress.bytes))")
                .font(.callout).monospacedDigit()
            Text(String(format: "%.1fs", store.progress.elapsed))
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel") { store.cancelScan() }.controlSize(.small)
        }
        .padding(26)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 18)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(store.picks.count) selected · \(fmt(store.pickedBytes))")
                .font(.callout.weight(.medium)).monospacedDigit()
            Spacer()
            Button("Add to cleanup queue") {
                store.stage(Array(store.picks.keys), sizes: store.picks, reason: "selected")
                store.view = .cleanup
            }.buttonStyle(.borderedProminent)
            Button("Clear") { store.clearPicks() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
    }

    private func doPurge() {
        store.purge { moved, freed, failed in
            var msg = "\(fmt(freed)) moved to the Trash across \(moved) items."
            if !failed.isEmpty {
                msg += "\n\n\(failed.count) could not be removed:\n" + failed.prefix(6).joined(separator: "\n")
            }
            purgeResult = msg
        }
    }
}

// MARK: - Inspector

struct InspectorPane: View {
    @EnvironmentObject var store: AppStore
    var onPurge: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let n = store.selected {
                    Text("Inspector").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).kerning(0.6)
                    Text(n.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    row("Size on disk", fmt(n.size))
                    if n.logical > 0 { row("Logical size", fmt(n.logical)) }
                    if n.logical > n.size {
                        row("Sparse + compressed", fmt(n.logical - n.size), tint: .green,
                            help: "Logical size minus blocks actually allocated. Sparse files — disk images, VM volumes — dominate this on a dev machine; APFS compression is the rest. Not reclaimable space.")
                    }
                    if n.isDir {
                        row("Files", fmtCount(n.files))
                        row("Folders", fmtCount(n.dirs))
                    }
                    if n.mtime > 0 {
                        row("Modified", Date(timeIntervalSince1970: n.mtime)
                            .formatted(date: .abbreviated, time: .omitted))
                    }
                    if n.parent != nil {
                        row("Share of parent", String(format: "%.1f%%", n.shareOfParent * 100))
                    }

                    if !n.children.isEmpty {
                        Text("Largest inside").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary).kerning(0.6).padding(.top, 4)
                        ForEach(n.children.prefix(10)) { c in
                            HStack {
                                Text(c.name).lineLimit(1).truncationMode(.middle).font(.caption)
                                Spacer()
                                Text(fmt(c.size)).font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
                        Button(store.isPicked(n.path) ? "Deselect" : "Select") { store.togglePick(n) }
                    }.padding(.top, 4)
                    Button("Add to cleanup queue") {
                        store.stage([n.path], sizes: [n.path: n.size], reason: "inspector")
                    }.frame(maxWidth: .infinity)
                        .disabled(!Safety.canDelete(n.path).ok)
                        .help(Safety.canDelete(n.path).why)
                    if !Safety.canDelete(n.path).ok {
                        Label(Safety.canDelete(n.path).why.prefix(1).uppercased() + Safety.canDelete(n.path).why.dropFirst() + " — view only",
                              systemImage: "lock")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    RiskDetail(note: .trash(path: n.path)).padding(.top, 2)
                    if ConversationStorage.owner(of: Safety.canonical(n.path), includingAncestors: true) != nil {
                        Button("Review AI history storage") { store.view = .aiStorage }
                    }
                }

                Divider().padding(.vertical, 4)

                HStack {
                    Text("Cleanup queue").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).kerning(0.6)
                    Spacer()
                    if !store.staged.isEmpty {
                        Text(fmt(store.stagedBytes)).font(.caption.weight(.semibold))
                    }
                }
                if store.staged.isEmpty {
                    Text("Empty. Select items in any view, then add them here. Nothing is ever removed without you.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ForEach(store.staged) { it in
                        HStack {
                            Text(it.name).font(.caption2.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .help(it.path)
                            Spacer()
                            Text(fmt(it.size)).font(.caption2).foregroundStyle(.secondary)
                            Button { store.unstage(it.path) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }.buttonStyle(.borderless).foregroundStyle(.tertiary)
                        }
                    }
                    Button("Move \(store.staged.count) items to Trash", action: onPurge)
                        .buttonStyle(.borderedProminent).tint(.red)
                        .frame(maxWidth: .infinity).padding(.top, 4)
                    Button("Clear queue") { store.clearStaged() }.frame(maxWidth: .infinity)
                    Text("Recoverable until you empty the Trash in Finder. Moving items here does not yet free disk space.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        }
    }

    private func row(_ k: String, _ v: String, tint: Color? = nil, help: String? = nil) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption).monospacedDigit().foregroundStyle(tint ?? .primary)
        }
        .padding(.vertical, 2)
        .overlay(Divider(), alignment: .bottom)
        .help(help ?? "")
    }
}
