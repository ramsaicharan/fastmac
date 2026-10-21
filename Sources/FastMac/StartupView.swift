import SwiftUI

// Self-contained: owns its own StartupService, needs no AppStore in the environment.
// Wire into ContentView by adding `case .startup: StartupView()` to detailBody's switch
// and a `.startup` case to ViewKind — see HANDOFF.md for the exact edit.
struct StartupView: View {
    @StateObject private var service: StartupService
    private let automaticallyScans: Bool
    @StateObject private var changes = StartupChangesModel()
    @State private var showingChanges = false
    @State private var domainFilter: StartupDomain?
    @State private var impactFilter: ImpactLevel?
    @State private var pendingToggle: StartupItem?
    @State private var pendingEnable = false
    @State private var refusalMessage: String?
    @State private var refusalItem: StartupItem?
    @State private var pendingPrivileged: Privileged.Command?
    @State private var privilegedResult: PrivResult?
    @State private var runningPrivileged = false
    @State private var runningStartup = false
    @State private var pendingBulkRoot: [StartupItem]?

    init(service: StartupService? = nil, automaticallyScans: Bool = true) {
        _service = StateObject(wrappedValue: service ?? StartupService())
        self.automaticallyScans = automaticallyScans
    }

    private struct PrivResult: Identifiable { let id = UUID(); let title: String; let body: String }
    private var isActionRunning: Bool { runningPrivileged || runningStartup }

    private var visible: [StartupItem] {
        service.items.filter {
            (domainFilter == nil || $0.domain == domainFilter)
                && (impactFilter == nil || Impact.rate($0).level == impactFilter)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                note
                HStack {
                        Label(changes.changes.isEmpty ? "Startup baseline" : "\(changes.changes.count) startup changes to review", systemImage: "clock.badge.exclamationmark")
                        Text(changes.status).lineLimit(1).help(changes.status).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review changes") { showingChanges = true }.disabled(changes.changes.isEmpty)
                }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                if service.items.isEmpty {
                    empty
                } else {
                    summary
                    Divider()
                    filters
                    Divider()
                    table(wide: geometry.size.width >= 850)
                        .frame(minHeight: 140, maxHeight: .infinity)
                    if !service.orphans.isEmpty {
                        Divider()
                        ScrollView {
                            orphanCallout
                        }
                        .frame(height: min(210, max(128, geometry.size.height * 0.30)))
                        .accessibilityIdentifier("startup-orphans")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if service.isScanning || isActionRunning {
                    ProgressView(isActionRunning ? "Updating startup items…" : "Scanning startup items…")
                        .controlSize(.small)
                } else {
                    Button("Rescan", systemImage: "arrow.clockwise") { service.scan() }
                }
            }
        }
        .sheet(isPresented: $showingChanges) { StartupChangesReview(model: changes) }
        .onChange(of: service.lastScanAt) { _, _ in if automaticallyScans { changes.compare(service.items) } }
        .onAppear { if automaticallyScans && service.items.isEmpty { service.scan() } }
        .alert(pendingEnable ? "Enable this login item?" : "Disable this login item?",
               isPresented: Binding(get: { pendingToggle != nil }, set: { if !$0 { pendingToggle = nil } })) {
            Button("Cancel", role: .cancel) { pendingToggle = nil }
            Button(pendingEnable ? "Enable" : "Disable", role: pendingEnable ? nil : .destructive) {
                if let item = pendingToggle { apply(item, enable: pendingEnable) }
                pendingToggle = nil
            }
        } message: {
            if let item = pendingToggle {
                Text(pendingEnable
                     ? "\(item.owner) (\(item.label)) will be re-enabled and loaded for your account with `launchctl enable` + `bootstrap`. Reversible any time from this screen."
                     : "\(item.owner) (\(item.label)) will be unloaded and disabled for your account with `launchctl bootout` + `disable`. It stays on disk and can be re-enabled here at any time.")
            }
        }
        .alert("Disable \(pendingBulkRoot?.count ?? 0) system startup entries?", isPresented: Binding(
            get: { pendingBulkRoot != nil }, set: { if !$0 { pendingBulkRoot = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingBulkRoot = nil }
            Button("Authenticate once…") {
                if let items = pendingBulkRoot { runBulkRoot(items) }
                pendingBulkRoot = nil
            }
        } message: {
            Text("""
                 Every one of these points at a program that is no longer installed.

                 macOS asks for your password once, for the whole set. FastMac never sees it.

                 Each plist is renamed with a .fastmac-disabled suffix rather than deleted, \
                 so any of them can be restored by renaming it back.
                 """)
        }
        .alert("Run as administrator?", isPresented: Binding(
            get: { pendingPrivileged != nil }, set: { if !$0 { pendingPrivileged = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingPrivileged = nil }
            Button("Authenticate…") {
                if let c = pendingPrivileged { runPrivileged(c) }
                pendingPrivileged = nil
            }
        } message: {
            if let c = pendingPrivileged {
                Text("""
                     \(c.title)

                     macOS will ask for your password in its own window. FastMac never sees it.

                     Command: \(c.shell)

                     What happens: \(c.note.what)
                     Undo: \(c.note.undo)
                     """)
            }
        }
        .alert(item: $privilegedResult) { r in
            Alert(title: Text(r.title), message: Text(r.body), dismissButton: .default(Text("OK")))
        }
        .alert("Needs administrator rights", isPresented: Binding(get: { refusalMessage != nil }, set: { if !$0 { refusalMessage = nil; refusalItem = nil } })) {
            Button("Reveal in Finder") {
                if let item = refusalItem { service.revealInFinder(item) }
                refusalMessage = nil; refusalItem = nil
            }
            Button("OK", role: .cancel) { refusalMessage = nil; refusalItem = nil }
        } message: {
            Text(refusalMessage ?? "")
        }
        .alert("Startup", isPresented: Binding(get: { service.lastAction != nil && !isActionRunning }, set: { if !$0 { service.lastAction = nil } })) {
            Button("OK") { service.lastAction = nil }
        } message: {
            Text(service.lastAction ?? "")
        }
    }

    // MARK: pieces

    private var note: some View {
        Text("Startup agents and daemons in your Library and /Library, matched with launchd’s live state. Apple’s /System/Library items are excluded.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14).padding(.top, 10)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if service.isScanning {
                ProgressView("Scanning login items…")
            } else if let err = service.lastError {
                Text(err).foregroundStyle(.orange)
            } else {
                Text("No login items found yet.").foregroundStyle(.secondary)
                Button("Scan") { service.scan() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: some View {
        let high = service.items.filter { Impact.rate($0).level == .high }.count
        let running = service.running.count
        let orphaned = service.orphans.count
        return HStack(spacing: 11) {
            StartupStatCard(label: "Total items", value: "\(service.items.count)", tint: .secondary)
            StartupStatCard(label: "High impact", value: "\(high)", tint: high > 0 ? .red : .secondary)
            StartupStatCard(label: "Currently running", value: "\(running)", tint: .blue)
            StartupStatCard(label: "Orphaned", value: "\(orphaned)", tint: orphaned > 0 ? .orange : .secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Domain", selection: $domainFilter) {
                Text("All places").tag(StartupDomain?.none)
                ForEach(StartupDomain.allCases) { d in Text(d.title).tag(StartupDomain?.some(d)) }
            }.frame(width: 200)
            Picker("Impact", selection: $impactFilter) {
                Text("All impact").tag(ImpactLevel?.none)
                Text("High").tag(ImpactLevel?.some(.high))
                Text("Medium").tag(ImpactLevel?.some(.medium))
                Text("Low").tag(ImpactLevel?.some(.low))
            }.frame(width: 150)
            Spacer()
            if let at = service.lastScanAt {
                Text("Updated \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    @ViewBuilder private func table(wide: Bool) -> some View {
        if wide {
            Table(visible) {
                impactColumn
                ownerColumn(wide: true)
                domainColumn
                statusColumn
                TableColumn("CPU") { item in
                    Text(item.cpuSeconds.map(Impact.describeCPU) ?? "—")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.width(60)
                TableColumn("Size") { item in
                    Text(item.binarySize.map(fmt) ?? "—")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.width(64)
                actionsColumn
            }
        } else {
            Table(visible) {
                impactColumn
                ownerColumn(wide: false)
                domainColumn
                statusColumn
                actionsColumn
            }
        }
    }

    private var impactColumn: some TableColumnContent<StartupItem, Never> {
        TableColumn("Impact") { (item: StartupItem) in
            let r = Impact.rate(item)
            Text(r.level.rawValue).font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color(for: r.level).opacity(0.18))
                .foregroundStyle(color(for: r.level))
                .clipShape(Capsule())
                .help(r.reason)
        }.width(56)
    }

    private func ownerColumn(wide: Bool) -> some TableColumnContent<StartupItem, Never> {
        TableColumn("Owner") { (item: StartupItem) in
            VStack(alignment: .leading, spacing: 1) {
                Text(item.owner).lineLimit(1)
                Text(item.label).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .help("\(item.label)\nCPU time: \(item.cpuSeconds.map(Impact.describeCPU) ?? "unavailable")\nBinary size: \(item.binarySize.map(fmt) ?? "unavailable")")
        }.width(min: 100, ideal: wide ? 180 : 120)
    }

    private var domainColumn: some TableColumnContent<StartupItem, Never> {
        TableColumn("Where") { (item: StartupItem) in
            Text(item.domain.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(item.domain.title)
        }.width(94)
    }

    private var statusColumn: some TableColumnContent<StartupItem, Never> {
        TableColumn("Status") { (item: StartupItem) in
            statusText(item).lineLimit(1)
        }.width(122)
    }

    private var actionsColumn: some TableColumnContent<StartupItem, Never> {
        TableColumn("") { (item: StartupItem) in
            actions(for: item)
        }.width(146)
    }

    @ViewBuilder private func statusText(_ item: StartupItem) -> some View {
        if item.unreadable {
            Text("permission denied").font(.caption).foregroundStyle(.orange)
        } else if item.isOrphanBinary {
            Text("target missing").font(.caption).foregroundStyle(.red)
        } else if item.isStub {
            Text("empty stub").font(.caption).foregroundStyle(.orange)
        } else if item.effectiveDisabled {
            Text("disabled").font(.caption).foregroundStyle(.secondary)
        } else if item.isLoaded {
            Text(item.pid.map { "running · pid \($0)" } ?? "loaded")
                .font(.caption).foregroundStyle(.green)
        } else {
            Text(item.domain == .daemon ? "unknown (needs admin)" : "not loaded")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func runPrivileged(_ cmd: Privileged.Command) {
        guard !isActionRunning else { return }
        runningPrivileged = true
        Task.detached(priority: .userInitiated) {
            let outcome = Privileged.run(cmd)
            await MainActor.run {
                runningPrivileged = false
                switch outcome {
                case .succeeded:
                    privilegedResult = PrivResult(
                        title: cmd.title,
                        body: "Done. The entry is renamed and launchd will ignore it from the next boot.\n\nUndo: \(cmd.note.undo)")
                    service.scan()
                case .cancelled:
                    privilegedResult = PrivResult(title: "Cancelled",
                        body: "You dismissed the authentication panel. Nothing changed.")
                case .failed(let m):
                    privilegedResult = PrivResult(title: "Did not run",
                        body: m.isEmpty ? "The command failed with no output." : m)
                }
            }
        }
    }

    @ViewBuilder private func actions(for item: StartupItem) -> some View {
        HStack(spacing: 6) {
            if item.domain.editableWithoutRoot {
                Button(item.effectiveDisabled ? "Enable" : "Disable") {
                    pendingEnable = item.effectiveDisabled
                    pendingToggle = item
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else if let cmd = Privileged.disableLaunchItem(path: item.plistPath, label: item.label) {
                Button("Disable…") { pendingPrivileged = cmd }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Needs administrator rights. macOS will ask — FastMac never sees your password.")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Privileged.terminalEquivalent(cmd), forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                    .buttonStyle(.borderless)
                    .help("Copy the command and run it in Terminal yourself instead")
                Button("Reveal") { service.revealInFinder(item) }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                Button("Reveal") { service.revealInFinder(item) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("FastMac will not modify this path.")
            }
        }
        .disabled(isActionRunning)
    }

    private var orphanCallout: some View {
        // Nine dead entries removed one at a time, each behind its own password prompt, is
        // not a fix — it is a chore. Offer the whole set in one authenticated pass, and say
        // exactly how many need admin before asking for it.
        let rootOwned = service.orphans.filter { !$0.domain.editableWithoutRoot }
        let userOwned = service.orphans.filter { $0.domain.editableWithoutRoot }

        return LazyVStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Orphaned entries — safe, high-value wins").font(.headline)
                RiskBadge(risk: .safe, note: .orphanLoginItem)
                Spacer()
            }
            Text("These point at a program that no longer exists, or are empty stubs an uninstaller left behind. They still get probed at every boot for nothing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !userOwned.isEmpty {
                    Button("Disable all \(userOwned.count) of yours") {
                        bulkUserDisable(userOwned)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if !rootOwned.isEmpty {
                    Button("Disable all \(rootOwned.count) system ones…") {
                        pendingBulkRoot = rootOwned
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("One authentication for the whole set — macOS asks, FastMac never sees your password.")
                    Button {
                        let lines = rootOwned.compactMap {
                            Privileged.disableLaunchItem(path: $0.plistPath, label: $0.label)
                        }.map { Privileged.terminalEquivalent($0) }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    } label: { Label("Copy commands", systemImage: "doc.on.doc").font(.caption) }
                        .buttonStyle(.borderless)
                        .help("Copy every command instead, and run them in Terminal yourself")
                }
            }

            ForEach(service.orphans) { item in
                HStack {
                    Text(item.label).font(.caption.monospaced()).lineLimit(1)
                    Text(item.domain.title).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if item.domain.editableWithoutRoot {
                        Button("Disable") { pendingEnable = false; pendingToggle = item }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else if let cmd = Privileged.disableLaunchItem(path: item.plistPath,
                                                                    label: item.label) {
                        Button("Disable…") { pendingPrivileged = cmd }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("Reveal") { service.revealInFinder(item) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .padding(14)
        .disabled(isActionRunning)
    }

    private func bulkUserDisable(_ items: [StartupItem]) {
        guard !isActionRunning else { return }
        runningStartup = true
        Task { @MainActor in
            let current = await Task.detached(priority: .userInitiated) {
                StartupService.revalidatedOrphans(items)
            }.value
            var succeeded = 0
            for item in current {
                if case .ok = await service.setEnabledAsync(item, enabled: false, publishResult: false) { succeeded += 1 }
            }
            let skipped = items.count - current.count
            let failed = current.count - succeeded
            service.lastAction = "Disabled \(succeeded) startup item\(succeeded == 1 ? "" : "s")."
                + (skipped > 0 ? " Skipped \(skipped) changed or restored entr\(skipped == 1 ? "y" : "ies")." : "")
                + (failed > 0 ? " \(failed) could not be disabled; rescan and review their status." : "")
            runningStartup = false
            service.scan()
        }
    }

    /// Runs several vetted commands under a single authentication, in one AppleScript.
    private func runBulkRoot(_ items: [StartupItem]) {
        guard !isActionRunning else { return }
        runningPrivileged = true
        Task.detached(priority: .userInitiated) {
            let current = StartupService.revalidatedOrphans(items)
            let cmds = current.compactMap {
                Privileged.disableLaunchItem(path: $0.plistPath, label: $0.label)
            }
            guard !cmds.isEmpty else {
                await MainActor.run {
                    runningPrivileged = false
                    privilegedResult = PrivResult(title: "No entries changed",
                        body: "The selected entries were restored, changed, or are no longer eligible. Rescan and review their current state.")
                    service.scan()
                }
                return
            }
            let skipped = items.count - cmds.count
            let outcome = Privileged.runAll(cmds, title: "Disable \(cmds.count) dead startup entries")
            await MainActor.run {
                runningPrivileged = false
                switch outcome {
                case .succeeded:
                    privilegedResult = PrivResult(
                        title: "Disabled \(cmds.count) dead entries",
                        body: "Each plist was renamed with a .fastmac-disabled suffix. launchd ignores them from the next boot, and any one can be put back by renaming it."
                            + (skipped > 0 ? " Skipped \(skipped) changed, restored, or ineligible entries." : ""))
                    service.scan()
                case .cancelled:
                    privilegedResult = PrivResult(title: "Cancelled",
                        body: "You dismissed the authentication panel. Nothing changed.")
                case .failed(let m):
                    privilegedResult = PrivResult(title: "Did not run",
                        body: m.isEmpty ? "The command failed with no output." : m)
                }
            }
        }
    }

    private func color(for level: ImpactLevel) -> Color {
        switch level { case .high: .red; case .medium: .orange; case .low: .secondary }
    }

    private func apply(_ item: StartupItem, enable: Bool) {
        guard !isActionRunning else { return }
        runningStartup = true
        Task { @MainActor in
            let outcome = await service.setEnabledAsync(item, enabled: enable, publishResult: false)
            runningStartup = false
            switch outcome {
            case .ok(let message), .failed(let message):
                service.lastAction = message
                service.scan()
            case .refused(let message):
                refusalItem = item
                refusalMessage = message
            }
        }
    }
}

private struct StartupStatCard: View {
    let label: String, value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary).kerning(0.5)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
