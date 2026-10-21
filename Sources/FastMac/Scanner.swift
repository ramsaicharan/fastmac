import Foundation

/// Live counters the UI polls while a scan is in flight.
final class ScanProgress: ObservableObject, @unchecked Sendable {
    @Published var files = 0
    @Published var bytes: Int64 = 0
    @Published var current = ""
    @Published var running = false
    @Published var elapsed: Double = 0
    @Published var phase = ""

    private let lock = NSLock()
    private var rawFiles = 0
    private var rawBytes: Int64 = 0
    private var rawCurrent = ""

    func bump(files f: Int, bytes b: Int64, path: String?) {
        lock.lock(); rawFiles += f; rawBytes += b
        if let p = path { rawCurrent = p }; lock.unlock()
    }
    /// Pulled on a timer from the main actor. Publishing per file would melt the UI.
    func flush(start: Date) {
        lock.lock(); let f = rawFiles, b = rawBytes, c = rawCurrent; lock.unlock()
        files = f; bytes = b; current = c; elapsed = Date().timeIntervalSince(start)
    }
    func reset() {
        lock.lock(); rawFiles = 0; rawBytes = 0; rawCurrent = ""; lock.unlock()
        files = 0; bytes = 0; current = ""; elapsed = 0; phase = ""
    }
}

/// Per-thread scratch, merged into the shared totals in batches. Merging per directory
/// put every worker on the same lock and cost more than the scan itself.
private struct Batch {
    private let maxBig = 512
    private let maxDup = 2_048
    var big: [BigFile] = []
    var dup: [(Int64, String)] = []
    var files = 0
    var bytes: Int64 = 0
    var dirs = 0
    var errors = 0
    var current: String?
    var isHeavy: Bool { files >= 4000 || big.count >= 256 || dup.count >= maxDup }
    mutating func addBig(_ item: BigFile) {
        big.append(item)
        if big.count > maxBig {
            big.sort { $0.size > $1.size }
            big.removeLast(big.count - maxBig)
        }
    }
    mutating func addDup(_ item: (Int64, String)) {
        guard dup.count < maxDup else { return }
        dup.append(item)
    }
    mutating func clear() { big.removeAll(keepingCapacity: true)
                            dup.removeAll(keepingCapacity: true)
                            files = 0; bytes = 0; dirs = 0; errors = 0; current = nil }
}

/// Parallel directory walk over raw POSIX calls.
///
/// Two decisions matter for speed:
///  • every directory discovered goes back on a shared work stack, so all cores stay busy
///    even when one subtree (say ~/Library) dwarfs the rest;
///  • traversal never aggregates. Sizes roll up in a single post-order pass afterwards,
///    which keeps workers lock-free apart from the stack itself.
final class Scanner: @unchecked Sendable {
    private let progress: ScanProgress

    private let cond = NSCondition()
    private var stack: [FSNode] = []
    private var idle = 0
    private var workerCount = 1
    private var done = false
    private var cancelled = false

    /// Directories never entered: other volumes and macOS's mirror of the data volume.
    private var excluded: Set<String> = []

    private let agg = NSLock()
    private var bigFiles: [BigFile] = []
    private var bySize: [Int64: [String]] = [:]
    private var errors = 0
    private var duplicatePathCount = 0

    private let bigThreshold: Int64 = 50 * 1024 * 1024
    private let dupThreshold: Int64 = 1024 * 1024
    private let maxBigFiles = 4_000
    private let maxDuplicatePaths = 120_000
    private let maxPathsPerSize = 128

    init(progress: ScanProgress) { self.progress = progress }

    /// A whole-disk scan starts at "/", where the data volume appears twice: through
    /// the firmlinks (/Users, /Applications, …) and at /System/Volumes/Data. Every
    /// other mount point is a separate volume — external drives, the VM and Preboot
    /// volumes, mounted disk images whose backing files are already counted — so the
    /// walk stays on the startup disk and counts each byte once.
    /// Applies to any root, so refreshing /System after a whole-disk scan stays
    /// consistent; a scan of a folder with no mounts inside it is unaffected.
    static func exclusions(forRoot root: String) -> Set<String> {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var candidates: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/home", "/net"]
        candidates.formUnion(mountPoints())
        return candidates.filter { $0 != root && $0.hasPrefix(prefix) }
    }

    static func mountPoints() -> [String] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return [] }
        return (0..<Int(count)).map { index in
            var name = entries[index].f_mntonname
            let capacity = MemoryLayout.size(ofValue: name)
            return withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        }
    }

    /// "Macintosh HD" rather than "/" for the startup disk.
    static func displayName(forRoot root: String) -> String {
        if root == "/" {
            let name = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
            return name ?? "Macintosh HD"
        }
        let leaf = (root as NSString).lastPathComponent
        return leaf.isEmpty ? root : leaf
    }

    func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }
    private var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    // MARK: entry

    func scan(root rootPath: String) -> ScanResult {
        let start = Date()
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let node = FSNode(name: Scanner.displayName(forRoot: root), path: root, isDir: true)
        excluded = Scanner.exclusions(forRoot: root)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(root: node, bytes: 0, files: 0, dirs: 0, errors: 1,
                              elapsed: Date().timeIntervalSince(start), bigFiles: [], bySize: [:])
        }

        cond.lock()
        stack = [node]
        idle = 0
        done = false
        cancelled = false
        cond.unlock()
        agg.lock()
        bigFiles.removeAll(keepingCapacity: true)
        bySize.removeAll(keepingCapacity: true)
        errors = 0
        duplicatePathCount = 0
        agg.unlock()
        bySize.reserveCapacity(1 << 16)

        // One thread per core. This is syscall-bound, not blocking-IO-bound: oversubscribing
        // just adds contention on a warm page cache.
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        workerCount = workers
        DispatchQueue.concurrentPerform(iterations: workers) { _ in self.workerLoop() }

        // Sizes and counts roll up here, off the hot path.
        rollUp(node)
        node.sortBySize()

        agg.lock()
        let result = ScanResult(
            root: node, bytes: node.size, files: node.files, dirs: node.dirs,
            errors: errors, elapsed: Date().timeIntervalSince(start),
            bigFiles: Array(bigFiles.sorted { $0.size > $1.size }.prefix(maxBigFiles)),
            bySize: bySize.filter { $0.value.count > 1 },
            cancelled: cancelled)
        agg.unlock()
        return result
    }

    // MARK: work stack
    //
    // Each worker keeps a private stack and only touches the shared one when it runs dry
    // or when it has spare work to donate. Pushing every directory globally meant 270k
    // lock round-trips and a broadcast storm across 20 waiters.

    private func workerLoop() {
        var batch = Batch()
        var local: [FSNode] = []

        while true {
            var node: FSNode
            if let n = local.popLast() {
                node = n
            } else if let n = takeGlobal() {
                node = n
            } else {
                break
            }

            scanOneLevel(node, into: &batch)
            for c in node.children where c.isDir { local.append(c) }

            // Donate when others may be starving and we are holding plenty.
            if local.count > 16 && globalIsEmpty {
                let half = local.count / 2
                donate(Array(local.prefix(half)))
                local.removeFirst(half)
            }
            if batch.isHeavy { merge(&batch) }
            if isCancelled { break }
        }

        retire()
        merge(&batch)
    }

    private var globalIsEmpty: Bool {
        cond.lock(); defer { cond.unlock() }; return stack.isEmpty
    }

    /// Blocks until work appears, or until every worker is idle and the stack is empty.
    private func takeGlobal() -> FSNode? {
        cond.lock()
        defer { cond.unlock() }
        // We were counted active while holding local work; stepping back to the global
        // stack means we are idle until something is handed to us.
        idle += 1
        if idle == workerCount && stack.isEmpty { done = true; cond.broadcast() }
        while true {
            if cancelled || done { return nil }
            if let n = stack.popLast() { idle -= 1; return n }
            cond.wait()
        }
    }

    private func donate(_ kids: [FSNode]) {
        guard !kids.isEmpty else { return }
        cond.lock()
        stack.append(contentsOf: kids)
        // One waiter per donated item; a broadcast would wake every worker to fight over it.
        for _ in 0..<min(kids.count, workerCount) { cond.signal() }
        cond.unlock()
    }

    private func retire() {
        cond.lock()
        if !done { idle += 1; if idle >= workerCount && stack.isEmpty { done = true } }
        cond.broadcast()
        cond.unlock()
    }

    private func merge(_ b: inout Batch) {
        guard b.files > 0 || !b.big.isEmpty || b.errors > 0 else { return }
        agg.lock()
        bigFiles.append(contentsOf: b.big)
        if bigFiles.count > maxBigFiles {
            bigFiles.sort { $0.size > $1.size }
            bigFiles.removeLast(bigFiles.count - maxBigFiles)
        }
        for (sz, p) in b.dup {
            guard duplicatePathCount < maxDuplicatePaths else { break }
            guard bySize[sz, default: []].count < maxPathsPerSize else { continue }
            bySize[sz, default: []].append(p)
            duplicatePathCount += 1
        }
        errors += b.errors
        agg.unlock()
        progress.bump(files: b.files, bytes: b.bytes, path: b.current)
        b.clear()
    }

    // MARK: one directory

    private func scanOneLevel(_ node: FSNode, into batch: inout Batch) {
        batch.current = node.path
        guard let dir = opendir(node.path) else { batch.errors += 1; return }
        defer { closedir(dir) }
        let dfd = dirfd(dir)

        var kids: [FSNode] = []
        var ownBytes: Int64 = 0
        var ownLogical: Int64 = 0
        var ownFiles = 0
        var newest: TimeInterval = 0

        while let entPtr = readdir(dir) {
            let ent = entPtr.pointee
            var nameBuf = ent.d_name
            let name = withUnsafePointer(to: &nameBuf) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            // d_type usually answers this without a stat; only files need one.
            let full = node.path == "/" ? "/" + name : node.path + "/" + name

            if ent.d_type == UInt8(DT_DIR) {
                if !excluded.isEmpty && excluded.contains(full) { continue }
                let c = FSNode(name: name, path: full, isDir: true)
                c.parent = node
                kids.append(c)
                continue
            }
            if ent.d_type == UInt8(DT_LNK) { continue }        // never follow symlinks

            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                batch.errors += 1; continue
            }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }
            if mode == S_IFDIR {                                // d_type was DT_UNKNOWN
                if !excluded.isEmpty && excluded.contains(full) { continue }
                let c = FSNode(name: name, path: full, isDir: true)
                c.parent = node
                kids.append(c)
                continue
            }

            let onDisk = Int64(st.st_blocks) * 512
            let logical = Int64(st.st_size)
            let mt = TimeInterval(st.st_mtimespec.tv_sec)
            ownBytes += onDisk; ownLogical += logical; ownFiles += 1
            if mt > newest { newest = mt }
            if onDisk >= bigThreshold {
                batch.addBig(BigFile(path: full, size: onDisk, mtime: mt))
            }
            if logical >= dupThreshold { batch.addDup((logical, full)) }
            // A single flat directory can contain millions of qualifying files.
            // Flush bounded samples while readdir is still in progress instead of
            // waiting for the whole directory to finish.
            if batch.isHeavy { merge(&batch) }
        }

        node.children = kids
        node.size = ownBytes          // own files only; children fold in during roll-up
        node.logical = ownLogical
        node.files = ownFiles
        node.mtime = newest
        batch.files += ownFiles
        batch.bytes += ownBytes
    }

    // MARK: roll-up
    //
    // Iterative post-order. A recursive version blows the stack on deep node_modules trees.

    private func rollUp(_ root: FSNode) {
        var stack: [(FSNode, Bool)] = [(root, false)]
        while let (node, visited) = stack.popLast() {
            if visited {
                for c in node.children {
                    node.size += c.size
                    node.logical += c.logical
                    node.files += c.files
                    node.dirs += c.dirs + 1
                    if c.mtime > node.mtime { node.mtime = c.mtime }
                }
            } else {
                stack.append((node, true))
                for c in node.children where c.isDir { stack.append((c, false)) }
            }
        }
    }
}
