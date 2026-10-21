import SwiftUI
import Combine
import Darwin

enum ViewKind: String, CaseIterable, Identifiable {
    case folders, treemap, sunburst, flame, bubbles, mindmap, top, age, quick, dupes, apps, memory
    case health, aiStorage, cleanup, categories, startup, performance, maintenance, history, admin
    case activity, resources, projects, advanced, insights
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folders: "Folders";   case .treemap: "Treemap"
        case .sunburst: "Sunburst"; case .flame: "Flame"
        case .bubbles: "Bubbles";   case .mindmap: "Mind Map"
        case .top: "Top Sizes";     case .age: "Age Map"
        case .quick: "Quick Wins";  case .dupes: "Duplicates"
        case .apps: "Applications"; case .memory: "Memory"
        case .categories: "Categories";  case .startup: "Startup Items"
        case .performance: "Performance"; case .maintenance: "Maintenance"
        case .history: "History";        case .admin: "Administrator"
        case .health: "Mac Health"; case .aiStorage: "AI Storage"; case .cleanup: "Cleanup Queue"
        case .activity: "Activity History"; case .resources: "Resources"; case .projects: "Projects"
        case .advanced: "Advanced Tools"; case .insights: "Insights"
        }
    }
    var icon: String {
        switch self {
        case .folders: "list.bullet.indent"; case .treemap: "square.grid.3x3.fill"
        case .sunburst: "circle.circle";     case .flame: "flame"
        case .bubbles: "circle.hexagongrid"; case .mindmap: "point.topleft.down.curvedto.point.bottomright.up"
        case .top: "chart.bar.fill";         case .age: "calendar"
        case .quick: "bolt.fill";            case .dupes: "doc.on.doc"
        case .apps: "app.badge";             case .memory: "memorychip"
        case .categories: "square.stack.3d.up"; case .startup: "power"
        case .performance: "speedometer";       case .maintenance: "wrench.and.screwdriver"
        case .history: "clock.arrow.circlepath"; case .admin: "lock.shield"
        case .health: "heart.text.square"; case .aiStorage: "sparkles"; case .cleanup: "tray.full"
        case .activity: "waveform.path.ecg"; case .resources: "gauge.with.dots.needle.50percent"
        case .projects: "terminal"
        case .advanced: "shippingbox"; case .insights: "lightbulb"
        }
    }
    /// Views that navigate the scanned tree and share the breadcrumb bar.
    var isTree: Bool {
        [.folders, .treemap, .sunburst, .flame, .bubbles, .mindmap, .top].contains(self)
    }

    /// Whether this view is built from a completed folder scan.
    ///
    /// Most of the app is not. Memory, Performance, Startup, Maintenance, Categories and
    /// History each read live system state or do their own targeted measurement, and
    /// making them wait behind a multi-minute walk of the home folder was simply wrong —
    /// you should be able to open the app and kill a runaway process immediately.
    var needsScan: Bool {
        if isTree { return true }
        switch self {
        case .age, .dupes: return true      // built from the scan's own file inventory
        default:           return false
        }
    }
}

struct StagedItem: Identifiable, Hashable, Codable {
    let path: String
    let size: Int64
    let logical: Int64
    let allocated: Int64
    let device: UInt64?
    let inode: UInt64?
    let isDir: Bool
    let mtimeNs: Int64?
    let reason: String

    init(path: String, size: Int64, logical: Int64? = nil, allocated: Int64? = nil,
         device: UInt64? = nil, inode: UInt64? = nil, isDir: Bool = false,
         mtimeNs: Int64? = nil, reason: String) {
        self.path = path
        self.size = size
        self.logical = logical ?? size
        self.allocated = allocated ?? size
        self.device = device
        self.inode = inode
        self.isDir = isDir
        self.mtimeNs = mtimeNs
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case path, size, logical, allocated, device, inode, isDir = "is_dir",
             mtimeNs = "mtime_ns", reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        size = try c.decode(Int64.self, forKey: .size)
        logical = try c.decodeIfPresent(Int64.self, forKey: .logical) ?? size
        allocated = try c.decodeIfPresent(Int64.self, forKey: .allocated) ?? size
        device = try c.decodeIfPresent(UInt64.self, forKey: .device)
        inode = try c.decodeIfPresent(UInt64.self, forKey: .inode)
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        mtimeNs = try c.decodeIfPresent(Int64.self, forKey: .mtimeNs)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

private let stagedQueueURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".fastmac", isDirectory: true)
    .appendingPathComponent("queue.json")
private let stagedQueueLockURL = stagedQueueURL.appendingPathExtension("lock")

private func withStagedQueueLock<T>(_ body: () throws -> T) rethrows -> T {
    try? FileManager.default.createDirectory(at: stagedQueueURL.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
    let fd = Darwin.open(stagedQueueLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return try body() }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN); close(fd) }
    return try body()
}

private func fileIdentity(_ path: String) ->
    (device: UInt64, inode: UInt64, isDir: Bool, logical: Int64, allocated: Int64,
     mtimeNs: Int64, nlink: UInt64)? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    guard (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
    let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
        + Int64(st.st_mtimespec.tv_nsec)
    return (UInt64(st.st_dev), UInt64(st.st_ino), (st.st_mode & S_IFMT) == S_IFDIR,
            Int64(st.st_size), Int64(st.st_blocks) * 512, mtime, UInt64(st.st_nlink))
}

private func pathExists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    lhs == rhs || lhs.hasPrefix(rhs.hasSuffix("/") ? rhs : rhs + "/")
        || rhs.hasPrefix(lhs.hasSuffix("/") ? lhs : lhs + "/")
}

/// Why the Full Disk Access sheet is showing; the copy and buttons follow from it.
enum FullDiskAccessPrompt: String, Identifiable {
    case beforeScan, afterScan, granted
    var id: String { rawValue }
}

@MainActor
final class AppStore: ObservableObject {
    // scan
    @Published var result: ScanResult?
    @Published var current: FSNode?          // folder being viewed
    @Published var selected: FSNode?         // inspector target
    @Published var crumbs: [FSNode] = []
    @Published var scanRoot: String = NSHomeDirectory()

    // ui
    @Published var view: ViewKind = .health
    @Published var dashboardActive = false
    @Published var showingCommandPalette = false
    @Published var fullDiskAccessPrompt: FullDiskAccessPrompt?
    @Published var aiShowsLoadedModels = false
    @Published var commandShortcutRegistered = false
    @Published var picks: [String: Int64] = [:]   // path -> size
    @Published var staged: [StagedItem] = []
    @Published var banner: String?
    @Published var revision = 0        // bumped when the tree is mutated in place
    @Published var refreshing = false

    // analysis
    @Published var quickWins: [QuickWin] = []
    @Published var duplicates: [DupeGroup] = []
    @Published var apps: [AppFootprint] = []
    @Published var orphans: [OrphanData] = []
    @Published var analysing = false

    // memory
    @Published var mem = MemorySample()
    @Published var procs: [ProcGroup] = []
    @Published var history: [MemorySample] = []
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var diskAvailable = false

    let progress = ScanProgress()
    private var scanner: Scanner?
    private var tick: AnyCancellable?
    private var memTick: AnyCancellable?
    private var scanTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var analysisEpoch = 0
    private var appsLoadedRoot: String?
    private var memoryVisible = false
    private var memoryPollInFlight = false
    private var memoryEpoch = 0
    @Published private(set) var purgeInFlight = false
    private let maxStagedItems = 5_000

    init(loadSavedQueue: Bool = true) {
        if loadSavedQueue, FileManager.default.fileExists(atPath: stagedQueueURL.path),
           let data = try? withStagedQueueLock({ try Data(contentsOf: stagedQueueURL) }),
           let saved = try? JSONDecoder().decode([StagedItem].self, from: data) {
            staged = saved
        }
    }

    // MARK: scanning

    func scan(path: String? = nil) {
        guard !progress.running, !refreshing, !purgeInFlight else {
            banner = "Wait for the current scan, refresh, or Trash operation to finish"
            return
        }
        let requested = path ?? scanRoot
        let target = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            banner = "Choose a readable folder to scan"
            return
        }
        scanGeneration &+= 1
        let generation = scanGeneration
        invalidateAnalysis()
        scanRoot = target
        progress.reset()
        progress.running = true
        progress.phase = "walking the tree"
        let start = Date()
        tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.progress.flush(start: start) }

        let s = Scanner(progress: progress)
        scanner = s
        scanTask = Task.detached(priority: .userInitiated) {
            var r = s.scan(root: target)
            if !r.cancelled { r.disk = DiskOverviewProbe.read() }
            let finished = r
            await MainActor.run { self.finishScan(finished, generation: generation) }
        }
    }

    /// Everything on the startup disk, not just the home folder. Without Full Disk
    /// Access the private folders would silently count as unreadable, so ask first —
    /// once; choosing to scan without it is remembered.
    func scanMac() {
        let skipped = UserDefaults.standard.bool(forKey: FullDiskAccess.skipScanPromptKey)
        if FullDiskAccess.shouldPromptBeforeScan(status: FullDiskAccess.check(), skipped: skipped) {
            fullDiskAccessPrompt = .beforeScan
            return
        }
        scan(path: "/")
    }

    /// The user chose to continue with the folders macOS lets FastMac read.
    func scanMacWithoutFullDiskAccess() {
        UserDefaults.standard.set(true, forKey: FullDiskAccess.skipScanPromptKey)
        fullDiskAccessPrompt = nil
        scan(path: "/")
    }

    func cancelScan() {
        guard progress.running else { return }
        scanner?.cancel()
        banner = "Cancelling scan…"
    }

    private func finishScan(_ r: ScanResult, generation: Int) {
        guard generation == scanGeneration else { return }
        scanTask = nil; scanner = nil
        tick?.cancel(); tick = nil
        progress.running = false
        if r.cancelled {
            progress.phase = ""
            banner = "Scan cancelled; the previous map was kept"
            return
        }
        result = r
        current = r.root
        selected = r.root
        crumbs = [r.root]
        picks.removeAll()
        quickWins = []; duplicates = []; apps = []; orphans = []; appsLoadedRoot = nil
        if History.record(r) == nil {
            banner = "Scan finished, but its history summary could not be saved"
        } else if r.errors > 0 {
            banner = "\(fmtCount(r.errors)) item\(r.errors == 1 ? "" : "s") could not be read"
        }
        runAnalysis(r, generation: generation)
    }

    private func runAnalysis(_ r: ScanResult, generation: Int) {
        analysisEpoch &+= 1
        let epoch = analysisEpoch
        analysing = true
        progress.phase = "totalling quick wins"
        // This reads the already-built tree and performs only a handful of direct
        // path lookups. Keeping it on the main actor avoids racing mutable FSNode
        // instances with purge/refresh and is cheaper than copying the whole tree.
        guard scanGeneration == generation, analysisEpoch == epoch else {
            analysing = false; progress.phase = ""; return
        }
        quickWins = Analysis.quickWins(root: r.root)
        analysing = false; progress.phase = ""
        analysisTask = nil
    }

    /// Application footprints are deliberately lazy: they walk /Applications and
    /// several Library trees, so opening the Apps tab is the explicit opt-in.
    /// Load the analyses that never needed a scan, the moment their tab is opened.
    ///
    /// Quick Wins and Applications measure fixed, known locations — they only ever took
    /// a scan root to *narrow* their scope. With no scan in hand, whole-home is the right
    /// default, and the user gets answers immediately instead of a "scan first" wall.
    func ensureStandaloneAnalysis(for view: ViewKind) {
        guard !analysing, !progress.running, !refreshing, !purgeInFlight else { return }
        let epoch = analysisEpoch
        let generation = scanGeneration
        switch view {
        case .quick where quickWins.isEmpty:
            analysing = true
            progress.phase = "totalling quick wins"
            analysisTask = Task.detached(priority: .utility) {
                let q = Analysis.quickWins(root: nil)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.analysisEpoch == epoch, self.scanGeneration == generation else { return }
                    self.quickWins = q; self.analysing = false; self.progress.phase = ""
                    self.analysisTask = nil
                }
            }
        case .apps where apps.isEmpty:
            analysing = true
            progress.phase = "mapping application footprints"
            analysisTask = Task.detached(priority: .utility) {
                let a = Analysis.appFootprints(root: nil)
                guard !Task.isCancelled else { return }
                let o = Analysis.orphans(knownApps: a, root: nil)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.analysisEpoch == epoch, self.scanGeneration == generation else { return }
                    self.apps = a; self.orphans = o
                    self.analysing = false; self.progress.phase = ""
                    self.analysisTask = nil
                }
            }
        default:
            break
        }
    }

    func ensureAppsLoaded() {
        guard let r = result, !analysing, appsLoadedRoot != r.root.path else { return }
        analysisEpoch &+= 1
        let epoch = analysisEpoch
        analysing = true
        progress.phase = "mapping application footprints"
        let generation = scanGeneration
        let root = r.root.path
        analysisTask = Task.detached(priority: .utility) {
            let a = Analysis.appFootprints(root: root)
            guard !Task.isCancelled else { return }
            let o = Analysis.orphans(knownApps: a, root: root)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.scanGeneration == generation, self.analysisEpoch == epoch else { return }
                self.apps = a; self.orphans = o; self.appsLoadedRoot = root
                self.analysing = false; self.progress.phase = ""
                self.analysisTask = nil
            }
        }
    }

    /// Duplicate hunting is opt-in: it hashes candidates and that costs real IO.
    func findDuplicates() {
        guard let r = result, !analysing, !progress.running else { return }
        analysisEpoch &+= 1
        let epoch = analysisEpoch
        analysing = true
        progress.phase = "matching duplicates by content"
        let generation = scanGeneration
        let bySize = r.bySize
        analysisTask = Task.detached(priority: .utility) {
            let g = Analysis.duplicates(bySize: bySize)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.scanGeneration == generation, self.analysisEpoch == epoch else { return }
                self.duplicates = g; self.analysing = false; self.progress.phase = ""
                self.analysisTask = nil
            }
        }
    }

    private func invalidateAnalysis() {
        analysisEpoch &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        analysing = false
        progress.phase = ""
    }

    /// Stop interactive sampling and measurements when the dashboard closes.
    /// The independent menu bar monitor never needs these scans or process lists.
    func suspendInteractiveWork() {
        setMemoryVisible(false)
        if !purgeInFlight {
            cancelScan()
            invalidateAnalysis()
        }
    }

    // MARK: navigation

    func open(_ node: FSNode) {
        guard node.isDir, !node.children.isEmpty else { selected = node; return }
        current = node
        selected = node
        crumbs = node.ancestors() + [node]
    }
    func goTo(_ node: FSNode) { open(node) }
    func up() {
        guard let c = current, let p = c.parent else { return }
        open(p)
    }

    // MARK: selection

    func togglePick(_ n: FSNode) {
        togglePick(path: n.path, size: n.size)
    }
    func togglePick(path: String, size: Int64) {
        let rp = Safety.canonical(path)
        if picks[rp] != nil || picks[path] != nil {
            picks.removeValue(forKey: rp); picks.removeValue(forKey: path)
            return
        }
        if picks.keys.contains(where: { rp.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
            return // an ancestor is already selected; keep the total unique
        }
        for existing in Array(picks.keys) where pathsOverlap(existing, rp) {
            picks.removeValue(forKey: existing)
        }
        picks[rp] = size
    }
    func isPicked(_ path: String) -> Bool { picks[path] != nil }
    func clearPicks() { picks.removeAll() }
    var pickedBytes: Int64 { picks.values.reduce(0, +) }

    // MARK: staging

    private func saveQueue() {
        do {
            try FileManager.default.createDirectory(at: stagedQueueURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(staged)
            try withStagedQueueLock { try data.write(to: stagedQueueURL, options: .atomic) }
        } catch {
            banner = "Could not save the cleanup queue: \(error.localizedDescription)"
        }
    }

    func stage(_ paths: [String], sizes: [String: Int64] = [:],
               logicalSizes: [String: Int64] = [:], reason: String) {
        guard !purgeInFlight else { banner = "Wait for the current Trash operation to finish"; return }
        var added = 0, refused = 0
        for p in paths {
            let rawPath = (p as NSString).expandingTildeInPath
            guard staged.count < maxStagedItems else {
                refused += 1; continue
            }
            guard let initialIdentity = fileIdentity(rawPath),
                  initialIdentity.isDir || initialIdentity.nlink == 1 else {
                refused += 1; continue
            }
            let rp = Safety.canonical(p)
            guard !staged.contains(where: { $0.path == rp }) else { continue }
            guard !staged.contains(where: { pathsOverlap($0.path, rp) }) else {
                refused += 1; continue
            }
            guard Safety.canDelete(rp).ok, let identity = fileIdentity(rp),
                  identity.isDir || identity.nlink == 1 else {
                refused += 1; continue
            }
            let scanned = node(at: rp)
            let measured: (allocated: Int64, logical: Int64)
            if let allocated = sizes[p] ?? sizes[rp],
               let logical = logicalSizes[p] ?? logicalSizes[rp] {
                measured = (max(0, allocated), max(0, logical))
            } else {
                measured = scanned.map { (allocated: $0.size, logical: $0.logical) }
                    ?? Analysis.sizesOf(rp)
            }
            let allocated = sizes[p] ?? sizes[rp] ?? measured.allocated
            let logical = logicalSizes[p] ?? logicalSizes[rp] ?? measured.logical
            staged.append(StagedItem(path: rp, size: allocated, logical: logical,
                                     allocated: allocated, device: identity.device,
                                     inode: identity.inode, isDir: identity.isDir,
                                     mtimeNs: identity.mtimeNs,
                                     reason: String(reason.prefix(240))))
            added += 1
        }
        picks.removeAll()
        saveQueue()
        banner = "\(added) staged" + (refused > 0 ? " · \(refused) refused by the safety guard" : "")
    }

    func unstage(_ path: String) {
        guard !purgeInFlight else { banner = "Wait for the current Trash operation to finish"; return }
        staged.removeAll { $0.path == path }
        saveQueue()
    }
    func clearStaged() {
        guard !purgeInFlight else { banner = "Wait for the current Trash operation to finish"; return }
        staged.removeAll(); saveQueue()
    }
    var stagedBytes: Int64 { staged.reduce(0) { $0 + $1.size } }

    /// Moves staged items to the Trash. Recoverable, and re-checked path by path.
    func purge(completion: @escaping (Int, Int64, [String]) -> Void) {
        guard !purgeInFlight, !progress.running, !refreshing else {
            banner = "Finish the current scan or refresh before moving items to the Trash"
            return
        }
        purgeInFlight = true
        invalidateAnalysis()
        let items = staged
        let capturedByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        Task.detached(priority: .userInitiated) {
            // Hold the same lock used by the CLI for the entire read/check/move
            // transaction. Otherwise a concurrent stage could be overwritten by
            // the final queue reconciliation below.
            let outcome = withStagedQueueLock { () -> ([String], [(String, String)], Int64) in
                var removed: [String] = []
                var failures: [(String, String)] = []
                var freed: Int64 = 0

                for it in items {
                    let check = Safety.canDelete(it.path)
                    guard check.ok else { failures.append((it.path, check.why)); continue }
                    guard let identity = fileIdentity(it.path) else {
                        if pathExists(it.path) {
                            failures.append((it.path, "path is now a symbolic link; restage it"))
                        } else {
                            removed.append(it.path)  // already gone; treat as done
                        }
                        continue
                    }
                    guard identity.isDir || identity.nlink == 1 else {
                        failures.append((it.path, "hard-linked files are not staged")); continue
                    }
                    guard let expectedDevice = it.device, let expectedInode = it.inode,
                          let expectedMtime = it.mtimeNs else {
                        failures.append((it.path, "missing staging identity; restage it")); continue
                    }
                    if identity.device != expectedDevice || identity.inode != expectedInode
                        || identity.isDir != it.isDir || identity.mtimeNs != expectedMtime
                        || (!identity.isDir && (identity.logical != it.logical
                            || identity.allocated != it.allocated)) {
                        failures.append((it.path, "changed since it was staged")); continue
                    }
                    if identity.isDir {
                        let current = Analysis.sizesOf(it.path)
                        guard current.logical == it.logical, current.allocated == it.allocated else {
                            failures.append((it.path, "changed since it was staged")); continue
                        }
                    }
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: it.path),
                                                          resultingItemURL: nil)
                        removed.append(it.path)
                        freed += it.allocated
                        Audit.log("trashed", bytes: it.allocated, path: it.path)
                    } catch {
                        failures.append((it.path, error.localizedDescription))
                    }
                }
                return (removed, failures, freed)
            }
            let (removed, failures, freed) = outcome

            let removedCopy = removed
            let failuresCopy = failures
            let freedCopy = freed
            await MainActor.run {
                // The map must stop claiming space that is now in the Trash.
                for p in removedCopy { self.pruneFromTree(p) }
                self.pruneDerived(removedCopy)
                self.syncResultMetadata()

                let stillFailing = Set(failuresCopy.map(\.0))
                let removedSet = Set(removedCopy)
                // Reconcile only the items captured by this purge. A user can stage
                // another path while Finder is moving the old queue entries.
                self.staged.removeAll { current in
                    guard let old = capturedByPath[current.path],
                          current.device == old.device, current.inode == old.inode,
                          current.mtimeNs == old.mtimeNs else { return false }
                    return removedSet.contains(current.path)
                        || !stillFailing.contains(current.path)
                }
                self.saveQueue()
                self.picks.removeAll()
                self.revision &+= 1
                self.purgeInFlight = false

                completion(removedCopy.count, freedCopy,
                           failuresCopy.map { "\(($0.0 as NSString).lastPathComponent) — \($0.1)" })
            }
        }
    }

    // MARK: memory

    func setMemoryVisible(_ visible: Bool) {
        memoryVisible = visible
        memoryEpoch &+= 1
        let epoch = memoryEpoch
        memTick?.cancel(); memTick = nil
        memoryPollInFlight = false
        guard visible else { return }
        pollMemory(epoch: epoch)
        memTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.pollMemory(epoch: epoch) }
    }

    private func pollMemory(epoch: Int) {
        guard memoryVisible, epoch == memoryEpoch, !memoryPollInFlight else { return }
        memoryPollInFlight = true
        Task.detached(priority: .utility) {
            let m = MemoryProbe.sample()
            let p = MemoryProbe.processes(limit: 14)
            let d = MemoryProbe.diskFree()
            await MainActor.run {
                guard self.memoryVisible, self.memoryEpoch == epoch else {
                    return
                }
                self.mem = m
                self.procs = p
                self.history.append(m)
                if self.history.count > 150 { self.history.removeFirst() }
                self.diskFree = d.free; self.diskTotal = d.total
                self.diskAvailable = d.total > 0 && d.free >= 0 && d.free <= d.total
                self.memoryPollInFlight = false
            }
        }
    }
}

// MARK: - Keeping the map honest after a deletion
//
// The scanned tree holds directories only; files are folded into their parent's counters.
// So removing a path means either dropping a node, or just decrementing its parent — and
// in both cases every ancestor's totals have to be corrected, or the treemap keeps drawing
// space that no longer exists.

extension AppStore {

    /// Keep the top-level metadata synchronized with the mutable tree after a
    /// purge or subtree refresh; the toolbar and saved report read these fields.
    func syncResultMetadata() {
        guard var r = result else { return }
        r.bytes = r.root.size
        r.files = r.root.files
        r.dirs = r.root.dirs
        result = r
    }

    /// Walk from the root to the directory node for `path`, if one exists.
    func node(at path: String) -> FSNode? {
        guard let root = result?.root else { return nil }
        if path == root.path { return root }
        guard path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { return nil }

        let rest = String(path.dropFirst(root.path.hasSuffix("/") ? root.path.count
                                                                  : root.path.count + 1))
        var cur = root
        for part in rest.split(separator: "/") {
            guard let next = cur.children.first(where: { $0.name == String(part) }) else { return nil }
            cur = next
        }
        return cur
    }

    /// Subtract a removed item's weight from every ancestor of `parent`, inclusive.
    private func deduct(from parent: FSNode, size: Int64, logical: Int64,
                        files: Int, dirs: Int) {
        var n: FSNode? = parent
        while let cur = n {
            cur.size = max(0, cur.size - size)
            cur.logical = max(0, cur.logical - logical)
            cur.files = max(0, cur.files - files)
            cur.dirs = max(0, cur.dirs - dirs)
            n = cur.parent
        }
    }

    /// Drop one path from the in-memory map. Returns the bytes the map no longer claims.
    @discardableResult
    func pruneFromTree(_ path: String) -> Int64 {
        if let n = node(at: path), let parent = n.parent {
            // A directory we mapped: remove the node and its whole subtree.
            deduct(from: parent, size: n.size, logical: n.logical,
                   files: n.files, dirs: n.dirs + 1)
            parent.children.removeAll { $0 === n }

            // If we were standing inside it, step out.
            if let cur = current, cur === n || cur.ancestors().contains(where: { $0 === n }) {
                open(parent)
            }
            if let sel = selected, sel === n || sel.ancestors().contains(where: { $0 === n }) {
                selected = parent
            }
            return n.size
        }

        // Not a mapped directory — a file, or something below our depth. Correct its parent.
        let parentPath = (path as NSString).deletingLastPathComponent
        guard let parent = node(at: parentPath) else { return 0 }
        let known = knownSizes(of: path)
        deduct(from: parent, size: known.allocated, logical: known.logical, files: 1, dirs: 0)
        return known.allocated
    }

    /// Best available size for a path we no longer have on disk.
    private func knownSizes(of path: String) -> (allocated: Int64, logical: Int64) {
        if let s = staged.first(where: { $0.path == path }) {
            return (s.allocated, s.logical)
        }
        if let f = result?.bigFiles.first(where: { $0.path == path }) {
            return (f.size, f.size)
        }
        return (0, 0)
    }

    /// After files are gone, drop them from every derived list too — otherwise Age Map,
    /// Duplicates and Quick Wins keep offering things that no longer exist.
    func pruneDerived(_ removed: [String]) {
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        func isGone(_ p: String) -> Bool {
            if gone.contains(p) { return true }
            return removed.contains { p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }

        if var r = result {
            r.bigFiles.removeAll { isGone($0.path) }
            for key in Array(r.bySize.keys) {
                r.bySize[key]?.removeAll { isGone($0) }
                if (r.bySize[key]?.count ?? 0) < 2 { r.bySize.removeValue(forKey: key) }
            }
            result = r
        }

        duplicates = duplicates.compactMap { g in
            let kept = g.paths.filter { !isGone($0) }
            return kept.count > 1 ? DupeGroup(size: g.size, paths: kept,
                                               allocatedSize: g.allocatedSize) : nil
        }
        orphans.removeAll { isGone($0.path) }
        apps.removeAll { isGone($0.path) }

        // Quick Wins are folder totals, so re-measure only the ones we touched.
        quickWins = quickWins.compactMap { w in
            guard w.paths.contains(where: { isGone($0) || !FileManager.default.fileExists(atPath: $0) })
            else { return w }
            let live = w.paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !live.isEmpty else { return nil }
            let size = live.reduce(Int64(0)) { $0 + Analysis.sizeOf($1) }
            return size >= 10 << 20
                ? QuickWin(label: w.label, tier: w.tier, size: size, paths: live) : nil
        }
    }

    /// Re-measure a single subtree in place, for when something changed outside the app.
    func refresh(_ node: FSNode) {
        guard node.isDir, !progress.running, !refreshing else { return }
        refreshing = true
        let path = node.path
        scanGeneration &+= 1
        let generation = scanGeneration
        invalidateAnalysis()
        Task.detached(priority: .userInitiated) {
            let sub = Scanner(progress: ScanProgress()).scan(root: path)
            await MainActor.run {
                guard generation == self.scanGeneration else { self.refreshing = false; return }
                guard let currentRoot = self.result?.root else { self.refreshing = false; return }
                if node === currentRoot {
                    self.result = sub
                    self.current = sub.root
                    self.selected = sub.root
                    self.crumbs = [sub.root]
                    self.quickWins = []
                    self.apps = []; self.orphans = []; self.appsLoadedRoot = nil
                    self.refreshing = false
                    self.revision &+= 1
                    if !sub.cancelled { History.record(sub) }
                    self.runAnalysis(sub, generation: generation)
                    return
                }
                guard let parent = node.parent else { self.refreshing = false; return }
                self.deduct(from: parent, size: node.size, logical: node.logical,
                            files: node.files, dirs: node.dirs + 1)
                sub.root.parent = parent
                if let i = parent.children.firstIndex(where: { $0 === node }) {
                    parent.children[i] = sub.root
                } else {
                    parent.children.append(sub.root)
                }
                var n: FSNode? = parent
                while let cur = n {
                    cur.size += sub.root.size; cur.logical += sub.root.logical
                    cur.files += sub.root.files; cur.dirs += sub.root.dirs + 1
                    n = cur.parent
                }
                parent.children.sort { $0.size > $1.size }
                if self.current === node { self.current = sub.root; self.crumbs = sub.root.ancestors() + [sub.root] }
                if self.selected === node { self.selected = sub.root }
                if var r = self.result {
                    r.bigFiles = r.bigFiles.filter { !$0.path.hasPrefix(path + "/") }
                    r.bySize = r.bySize.mapValues { $0.filter { !$0.hasPrefix(path + "/") } }
                    r.bigFiles.append(contentsOf: sub.bigFiles)
                    for (size, paths) in sub.bySize { r.bySize[size, default: []].append(contentsOf: paths) }
                    r.bigFiles.sort { $0.size > $1.size }
                    r.bytes = r.root.size; r.files = r.root.files; r.dirs = r.root.dirs
                    r.scannedAt = Date()
                    self.result = r
                }
                self.quickWins = []; self.apps = []; self.orphans = []; self.appsLoadedRoot = nil
                self.refreshing = false
                self.revision &+= 1
                self.runAnalysis(self.result ?? sub, generation: generation)
            }
        }
    }
}
