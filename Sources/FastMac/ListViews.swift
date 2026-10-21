import SwiftUI

// MARK: - Folders

struct FoldersView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let kids = store.current?.children ?? []
        let maxSize = kids.first?.size ?? 1
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(kids) { k in
                    FolderRow(node: k, maxSize: maxSize,
                              parentSize: store.current?.size ?? 1)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct FolderRow: View {
    let node: FSNode
    let maxSize: Int64
    let parentSize: Int64
    @EnvironmentObject var store: AppStore
    @State private var hovering = false

    var body: some View {
        let picked = store.isPicked(node.path)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { picked },
                                     set: { _ in store.togglePick(node) }))
                .labelsHidden().toggleStyle(.checkbox)
            Image(systemName: node.isDir ? "folder.fill" : "doc")
                .foregroundStyle(node.isDir ? Color.accentColor : .secondary)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(node.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(String(format: "%.1f%%", Double(node.size) / Double(max(parentSize, 1)) * 100))
                .font(.caption).foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            Text(fmt(node.size)).font(.system(.body, design: .rounded))
                .monospacedDigit().frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(alignment: .leading) {
            GeometryReader { g in
                Rectangle().fill(Color.accentColor.opacity(picked ? 0.22 : 0.12))
                    .frame(width: g.size.width * Double(node.size) / Double(max(maxSize, 1)))
            }
        }
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            store.selected = node
            if node.isDir && !node.children.isEmpty { store.open(node) }
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button(picked ? "Deselect" : "Select") { store.togglePick(node) }
            Divider()
            Button("Add to cleanup queue") {
                store.stage([node.path], sizes: [node.path: node.size], reason: "selected")
            }
            if node.isDir {
                Divider()
                Button("Re-measure this folder") { store.refresh(node) }
            }
        }
    }
}

// MARK: - Top sizes

struct TopSizesView: View {
    @EnvironmentObject var store: AppStore

    private var rows: [FSNode] {
        guard let cur = store.current else { return [] }
        var all: [FSNode] = []
        cur.walkTop(limit: 4000, into: &all)
        return Array(all.sorted { $0.size > $1.size }.prefix(300))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The 300 largest mapped folders anywhere under \(store.current?.name ?? ""). Files are included in each folder total.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            Table(rows) {
                TableColumn("") { n in
                    Toggle("", isOn: Binding(get: { store.isPicked(n.path) },
                                             set: { _ in store.togglePick(n) }))
                        .labelsHidden().toggleStyle(.checkbox)
                }.width(24)
                TableColumn("Name") { n in Text(n.name).lineLimit(1) }
                TableColumn("Path") { n in
                    Text(n.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                TableColumn("Files") { n in
                    Text(n.isDir ? fmtCount(n.files) : "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }.width(64)
                TableColumn("Size") { n in
                    Text(fmt(n.size)).monospacedDigit()
                }.width(84)
            }
        }
    }
}

extension FSNode {
    /// Flatten descendants, capped so a huge tree cannot stall the table.
    func walkTop(limit: Int, into out: inout [FSNode]) {
        var pending = Array(children.reversed())
        while let c = pending.popLast() {
            out.append(c)
            if out.count >= limit { return }
            if c.isDir { pending.append(contentsOf: c.children.reversed()) }
        }
    }
}

// MARK: - Age map

struct AgeMapView: View {
    @EnvironmentObject var store: AppStore

    private var buckets: [(AgeBucket, Int64, Int)] {
        var b: [AgeBucket: (Int64, Int)] = [:]
        for f in store.result?.bigFiles ?? [] {
            let k = AgeBucket.of(ageDays: f.ageDays)
            var e = b[k] ?? (0, 0); e.0 += f.size; e.1 += 1; b[k] = e
        }
        return AgeBucket.allCases.map { ($0, b[$0]?.0 ?? 0, b[$0]?.1 ?? 0) }
    }
    private var untouched: [BigFile] {
        (store.result?.bigFiles ?? [])
            .filter { $0.ageDays > 365 && $0.size >= 100 << 20 }
    }

    private func tint(_ b: AgeBucket) -> Color {
        switch b {
        case .week: .green; case .month: Color(red: 0.34, green: 0.77, blue: 0.39)
        case .quarter: Color(red: 0.61, green: 0.77, blue: 0.24)
        case .halfYear: .yellow; case .year: .orange
        case .twoYears: Color(red: 0.94, green: 0.53, blue: 0.24); case .ancient: .red
        }
    }

    var body: some View {
        let total = max(buckets.reduce(Int64(0)) { $0 + $1.1 }, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Every file 50 MB or larger, placed on a timeline by when it was last modified.")
                    .font(.caption).foregroundStyle(.secondary)

                GeometryReader { g in
                    HStack(spacing: 0) {
                        ForEach(buckets, id: \.0) { b, bytes, count in
                            if bytes > 0 {
                                Rectangle().fill(tint(b))
                                    .frame(width: g.size.width * Double(bytes) / Double(total))
                                    .help("\(b.label): \(fmt(bytes)) across \(count) files")
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 28)

                FlowRow(buckets: buckets, tint: tint)

                if untouched.isEmpty {
                    Text("Nothing large has gone untouched for a year.")
                        .foregroundStyle(.secondary).padding(.top, 20)
                } else {
                    HStack {
                        Text("Big & Untouched — 100 MB+, not modified in over a year")
                            .font(.headline)
                        Spacer()
                        Button("Stage all \(untouched.count) — \(fmt(untouched.reduce(0) { $0 + $1.size }))") {
                            store.stage(untouched.map(\.path),
                                        sizes: Dictionary(uniqueKeysWithValues:
                                            untouched.map { ($0.path, $0.size) }),
                                        reason: "big & untouched")
                        }
                    }
                    .padding(.top, 10)

                    ForEach(untouched.prefix(200)) { f in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { store.isPicked(f.path) },
                                set: { _ in store.togglePick(path: f.path, size: f.size) }))
                                .labelsHidden().toggleStyle(.checkbox)
                            Text(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(String(format: "%.1fy", Double(f.ageDays) / 365))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(f.ageDays > 730 ? .red : .orange)
                            Text(fmt(f.size)).monospacedDigit().frame(width: 78, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct FlowRow: View {
    let buckets: [(AgeBucket, Int64, Int)]
    let tint: (AgeBucket) -> Color
    var body: some View {
        HStack(spacing: 16) {
            ForEach(buckets, id: \.0) { b, bytes, count in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(tint(b)).frame(width: 9, height: 9)
                    Text("\(b.label) — \(fmt(bytes)) (\(count))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Quick wins

struct QuickWinsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Totalled the moment the scan landed. **safe** regenerates on its own; **review** holds real data.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            if store.analysing {
                ProgressView().padding(30)
            } else if store.quickWins.isEmpty {
                Text("No large quick-win folders were found in this scan.")
                    .foregroundStyle(.secondary).padding(30)
            }
            Table(store.quickWins) {
                TableColumn("Category") { w in Text(w.label) }
                TableColumn("Risk") { w in
                    RiskBadge(risk: w.tier == "safe" ? .safe : .caution,
                              note: w.tier == "safe" ? .regenerableCache : .trash)
                }.width(92)
                TableColumn("Size") { w in Text(fmt(w.size)).monospacedDigit() }.width(90)
                TableColumn("") { w in
                    Button("Stage") {
                        store.stage(w.paths, reason: "quick win: \(w.label)")
                    }.buttonStyle(.bordered).controlSize(.small)
                }.width(70)
            }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.duplicates.isEmpty {
                VStack(spacing: 14) {
                    Text("Matched byte for byte: same size, same 64 KB head, same full digest.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.analysing {
                        ProgressView("Hashing candidates…")
                    } else {
                        Button("Find duplicates") { store.findDuplicates() }
                            .buttonStyle(.borderedProminent)
                        Text("\(fmtCount(store.result?.bySize.count ?? 0)) size-groups to check")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let waste = store.duplicates.reduce(Int64(0)) { $0 + $1.wasted }
                HStack {
                    Text("\(fmt(waste)) reclaimable across \(store.duplicates.count) groups")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stage every extra copy") {
                        let extras = store.duplicates.flatMap { Array($0.paths.dropFirst()) }
                        var sizes: [String: Int64] = [:]
                        for g in store.duplicates { for p in g.paths.dropFirst() { sizes[p] = g.allocatedSize } }
                        store.stage(extras, sizes: sizes, reason: "duplicate")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.duplicates.prefix(250)) { g in
                            DupeGroupRow(group: g)
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
        }
    }
}

private struct DupeGroupRow: View {
    let group: DupeGroup
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(group.paths.count) copies × \(fmt(group.size))")
                    .font(.caption.weight(.medium))
                Spacer()
                        Text("\(fmt(group.wasted)) reclaimable").font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(group.paths.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 8) {
                    Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    if i == 0 {
                        Text("keep").font(.caption2).foregroundStyle(.green)
                    } else {
                        Button("Stage") { store.stage([p], sizes: [p: group.allocatedSize], reason: "duplicate") }
                            .buttonStyle(.borderless).font(.caption2)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Applications

struct AppsView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirming: AppFootprint?
    var automaticallyLoads = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Measured footprint: the app bundle plus matching data in known Library locations. Some app data may be shared or stored elsewhere.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
            if store.analysing {
                ProgressView("Mapping application footprints…").padding(30)
            } else if store.apps.isEmpty {
                Text("No application footprints were found in the analyzed locations.")
                    .foregroundStyle(.secondary).padding(30)
            } else {
                Table(store.apps) {
                    TableColumn("Application") { a in
                        HStack(spacing: 6) {
                            Text(a.name).lineLimit(1)
                            if a.isElectron {
                                Text("electron").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.18))
                                    .foregroundStyle(.purple).clipShape(Capsule())
                                    .help("Bundles its own copy of Chromium")
                            }
                        }
                    }
                    TableColumn("Bundle") { a in
                        Text(fmt(a.bundleSize)).monospacedDigit().foregroundStyle(.secondary)
                    }.width(78)
                    TableColumn("Related data") { a in
                        Text(a.leftoverSize > 0 ? fmt(a.leftoverSize) : "—")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.width(78)
                    TableColumn("Total") { a in Text(fmt(a.total)).monospacedDigit() }.width(80)
                    TableColumn("Last used") { a in
                        if let d = a.daysSinceUse {
                            Text("\(d)d ago").font(.caption).monospacedDigit()
                                .foregroundStyle(d > 120 ? .orange : .secondary)
                        } else {
                            Text("unknown").font(.caption).foregroundStyle(.secondary)
                                .help("Spotlight has no last-used date for this app.")
                        }
                    }.width(78)
                    TableColumn("") { a in
                        Button("Uninstall") { confirming = a }
                            .buttonStyle(.bordered).controlSize(.small)
                    }.width(86)
                }
            }
            if !store.orphans.isEmpty {
                Divider()
                Text("Possible leftover app data")
                    .font(.headline).padding(.horizontal, 14).padding(.top, 10)
                Text("No matching app was found in the analyzed locations. Review this data before staging it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.orphans) { o in
                            HStack {
                                Text(o.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(fmt(o.size)).monospacedDigit()
                                Button("Stage") {
                                    store.stage([o.path], sizes: [o.path: o.size], reason: "possible leftover app data")
                                }.buttonStyle(.bordered).controlSize(.small)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 4)
                        }
                    }
                }.frame(maxHeight: 190)
            }
        }
        .onAppear { if automaticallyLoads { store.ensureAppsLoaded() } }
        .onChange(of: store.analysing) { _, running in
            if automaticallyLoads && !running { store.ensureAppsLoaded() }
        }
        .alert("Uninstall \(confirming?.name ?? "")?", isPresented: .constant(confirming != nil)) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Stage app and related data") {
                if let a = confirming {
                    store.stage([a.path] + a.leftovers, sizes: [a.path: a.bundleSize],
                                reason: "uninstall \(a.name)")
                }
                confirming = nil
            }
        } message: {
            if let a = confirming {
                Text("Stages the bundle plus \(a.leftovers.count) Library items — \(fmt(a.total)) total.\n\nNothing is removed until you empty the cleanup queue.")
            }
        }
    }
}
