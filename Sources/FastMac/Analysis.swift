import Foundation
import CryptoKit

// MARK: - Safety
//
// The single gate every deletion passes through. Deliberately paranoid: the UI is not
// trusted to have filtered anything, and neither is a future caller.

enum Safety {
    static let home = NSHomeDirectory()

    static let protected: Set<String> = [
        home,
        home + "/Documents", home + "/Downloads", home + "/Desktop",
        home + "/Library", home + "/Pictures", home + "/Movies",
        home + "/Music", home + "/.ssh", home + "/Applications", home + "/.Trash",
        home + "/.fastmac",
        home + "/.diskmap",          // state from DiskMap, FastMac's former name
    ]

    static let systemPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/private/var/db",
        "/Library/Apple", "/cores", "/dev", "/Volumes/Preboot",
    ]

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func canDelete(_ path: String) -> (ok: Bool, why: String) {
        if path.split(separator: "/").contains("..") {
            return (false, "parent-directory traversal is not allowed")
        }
        let rp = canonical(path)
        guard !rp.isEmpty, rp != "/" else { return (false, "filesystem root") }
        if protected.contains(rp) { return (false, "protected folder") }
        if let owner = ConversationStorage.owner(of: rp, includingAncestors: true) {
            return (false, "\(owner) conversation history is protected from generic cleanup. Review and delete individual chats in \(owner) after backing up what you need.")
        }
        if rp.hasPrefix(home + "/.fastmac/") || rp.hasPrefix(home + "/.diskmap/") {
            return (false, "FastMac state is protected")
        }
        if rp.hasPrefix(home + "/.Trash/") { return (false, "Trash contents are not staged") }
        if isMountedVolumeRoot(rp) {
            return (false, "mounted volume root is not staged")
        }
        if rp.components(separatedBy: "/").filter({ !$0.isEmpty }).count < 2 {
            return (false, "too close to the root")
        }
        for p in systemPrefixes where rp == p || rp.hasPrefix(p + "/") {
            return (false, "system path")
        }
        let inHome = rp == home || rp.hasPrefix(home + "/")
        let inApps = rp.hasPrefix("/Applications/")
        let inVols = rp.hasPrefix("/Volumes/")
        guard inHome || inApps || inVols else {
            return (false, "outside home, /Applications and /Volumes")
        }
        return (true, "")
    }

    private static func isMountedVolumeRoot(_ path: String) -> Bool {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                               options: [])?.contains {
            canonical($0.path) == path
        } ?? false
    }
}

// MARK: - Audit trail

enum Audit {
    static let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".fastmac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cleanup.log")
    }()

    static func log(_ action: String, bytes: Int64, path: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(action)  \(bytes)  \(path)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.int64Value > 256 * 1024,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(128 * 1024).write(to: url, options: .atomic)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Analysis types

struct QuickWin: Identifiable, Hashable {
    let label: String
    let tier: String           // "safe" | "review"
    let size: Int64
    let paths: [String]
    var id: String { label }
}

struct DupeGroup: Identifiable, Hashable {
    let size: Int64
    let paths: [String]
    let allocatedSize: Int64

    init(size: Int64, paths: [String], allocatedSize: Int64? = nil) {
        self.size = size
        self.paths = paths
        self.allocatedSize = allocatedSize ?? size
    }

    var id: String { (paths.first ?? "") + "\(size)" }
    var wasted: Int64 { max(0, allocatedSize * Int64(paths.count - 1)) }
}

struct AppFootprint: Identifiable, Hashable {
    let name: String
    let path: String
    let bundleID: String?
    let bundleSize: Int64
    let leftovers: [String]
    let leftoverSize: Int64
    let isElectron: Bool
    let lastUsed: Date?
    var id: String { path }
    var total: Int64 { bundleSize + leftoverSize }
    var daysSinceUse: Int? {
        guard let d = lastUsed else { return nil }
        return max(0, Int(Date().timeIntervalSince(d) / 86400))
    }
}

struct OrphanData: Identifiable, Hashable {
    let path: String
    let size: Int64
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Analysis

enum Analysis {
    static let home = NSHomeDirectory()

    static func sizesOf(_ path: String, excluding excluded: [String] = [])
        -> (allocated: Int64, logical: Int64) {
        let start = URL(fileURLWithPath: path).standardizedFileURL.path
        let excluded = excluded.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        func isInside(_ candidate: String, _ root: String) -> Bool {
            candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        if excluded.contains(where: { isInside(start, $0) }) { return (0, 0) }

        var st = stat()
        guard lstat(start, &st) == 0 else { return (0, 0) }
        if st.st_mode & S_IFMT != S_IFDIR {
            return (Int64(st.st_blocks) * 512, Int64(st.st_size))
        }

        var allocated: Int64 = 0
        var logical: Int64 = 0
        var stack = [start]
        while let current = stack.popLast() {
            if Task.isCancelled { break }
            if excluded.contains(where: { isInside(current, $0) }) { continue }
            guard let dir = opendir(current) else { continue }
            let dfd = dirfd(dir)
            while let e = readdir(dir) {
                if Task.isCancelled { break }
                var buf = e.pointee.d_name
                let name = withUnsafePointer(to: &buf) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                var child = stat()
                guard fstatat(dfd, name, &child, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let childPath = current == "/" ? "/" + name : current + "/" + name
                let mode = child.st_mode & S_IFMT
                if mode == S_IFLNK || excluded.contains(where: { isInside(childPath, $0) }) { continue }
                if mode == S_IFDIR { stack.append(childPath) }
                else {
                    allocated += Int64(child.st_blocks) * 512
                    logical += Int64(child.st_size)
                }
            }
            closedir(dir)
        }
        return (allocated, logical)
    }

    static func sizeOf(_ path: String, excluding excluded: [String] = []) -> Int64 {
        sizesOf(path, excluding: excluded).allocated
    }

    // MARK: quick wins

    private static let winDefs: [(String, String, [String])] = [
        ("Downloads",         "review", ["/Downloads"]),
        ("User caches",       "safe",   ["/Library/Caches"]),
        ("Logs",              "safe",   ["/Library/Logs"]),
        ("Xcode DerivedData", "safe",   ["/Library/Developer/Xcode/DerivedData"]),
        ("Xcode archives",    "review", ["/Library/Developer/Xcode/Archives"]),
        ("iOS simulators",    "review", ["/Library/Developer/CoreSimulator/Devices"]),
        ("npm cache",         "safe",   ["/.npm/_cacache", "/.npm/_npx"]),
        ("pnpm / Yarn",       "safe",   ["/Library/Caches/pnpm", "/Library/Caches/Yarn"]),
        ("pip cache",         "safe",   ["/Library/Caches/pip"]),
        ("Gradle caches",     "safe",   ["/.gradle/caches"]),
        ("CocoaPods cache",   "safe",   ["/Library/Caches/CocoaPods"]),
        ("Homebrew cache",    "safe",   ["/Library/Caches/Homebrew"]),
        ("Go module cache",   "safe",   ["/go/pkg/mod"]),
        ("Docker data",       "review", ["/Library/Containers/com.docker.docker"]),
    ]

    static func quickWins(root: String? = nil) -> [QuickWin] {
        let scope = URL(fileURLWithPath: root ?? home).standardizedFileURL.path
        func inScope(_ path: String) -> Bool {
            path == scope || path.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
        }
        var out: [QuickWin] = []
        var covered: [String] = []
        let defs = winDefs.sorted {
            ($0.2.map { $0.count }.max() ?? 0) > ($1.2.map { $0.count }.max() ?? 0)
        }
        for (label, tier, rels) in defs {
            if Task.isCancelled { break }
            let paths = rels.map { home + $0 }
                .filter { FileManager.default.fileExists(atPath: $0) && inScope($0) }
            guard !paths.isEmpty else { continue }
            let total = paths.reduce(Int64(0)) { $0 + sizeOf($1, excluding: covered) }
            if total >= 10 << 20 {
                out.append(QuickWin(label: label, tier: tier, size: total, paths: paths))
                covered.append(contentsOf: paths)
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Uses the already-scanned directory tree. This keeps the normal native scan
    /// from walking the same cache folders a second time just to calculate totals.
    static func quickWins(root: FSNode) -> [QuickWin] {
        func nodeAt(_ path: String) -> FSNode? {
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard path == root.path || path.hasPrefix(prefix) else { return nil }
            if path == root.path { return root }
            let rest = String(path.dropFirst(prefix.count))
            var current = root
            for part in rest.split(separator: "/") {
                guard let next = current.children.first(where: { $0.name == String(part) })
                else { return nil }
                current = next
            }
            return current
        }

        func inside(_ path: String, _ parent: String) -> Bool {
            path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
        }
        let defs = winDefs.sorted {
            ($0.2.map { $0.count }.max() ?? 0) > ($1.2.map { $0.count }.max() ?? 0)
        }
        var covered: [String] = []
        var out: [QuickWin] = []
        for (label, tier, rels) in defs {
            let paths = rels.map { home + $0 }
                .compactMap { nodeAt($0) }
                .filter { node in
                    !covered.contains(where: { coveredPath in
                        inside(node.path, coveredPath) || inside(coveredPath, node.path)
                    })
                }
            guard !paths.isEmpty else { continue }
            let total = paths.reduce(Int64(0)) { $0 + $1.size }
            guard total >= 10 << 20 else { continue }
            out.append(QuickWin(label: label, tier: tier, size: total,
                                paths: paths.map { $0.path }))
            covered.append(contentsOf: paths.map { $0.path })
        }
        return out.sorted { $0.size > $1.size }
    }

    // MARK: duplicates
    //
    // Same size, then same 64 KB head, then same full digest. Name is never enough.

    static func duplicates(bySize: [Int64: [String]]) -> [DupeGroup] {
        let candidates = bySize.filter { $0.value.count > 1 }
        guard !candidates.isEmpty else { return [] }

        let lock = NSLock()
        var groups: [DupeGroup] = []
        let entries = Array(candidates)

        DispatchQueue.concurrentPerform(iterations: entries.count) { i in
            let (size, rawPaths) = entries[i]
            var paths: [String] = []
            var seenInodes = Set<String>()
            for path in rawPaths {
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                      st.st_nlink == 1 else { continue }
                let key = "\(st.st_dev):\(st.st_ino)"
                if seenInodes.insert(key).inserted { paths.append(path) }
            }
            guard paths.count > 1 else { return }
            var heads: [String: [String]] = [:]
            for p in paths {
                guard let h = digest(p, limit: 65536) else { continue }
                heads[h, default: []].append(p)
            }
            var local: [DupeGroup] = []
            for (_, sameHead) in heads where sameHead.count > 1 {
                if size <= 65536 {
                    let first = sameHead.first ?? ""
                    local.append(DupeGroup(size: size, paths: sameHead.sorted(),
                                           allocatedSize: allocatedBytes(first)))
                } else {
                    var full: [String: [String]] = [:]
                    for p in sameHead {
                        guard let h = digest(p, limit: nil) else { continue }
                        full[h, default: []].append(p)
                    }
                    for (_, same) in full where same.count > 1 {
                        let first = same.first ?? ""
                        local.append(DupeGroup(size: size, paths: same.sorted(),
                                               allocatedSize: allocatedBytes(first)))
                    }
                }
            }
            if !local.isEmpty { lock.lock(); groups.append(contentsOf: local); lock.unlock() }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func digest(_ path: String, limit: Int?) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        if let limit {
            guard let d = try? fh.read(upToCount: limit) else { return nil }
            hasher.update(data: d)
        } else {
            while let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty {
                if Task.isCancelled { return nil }
                hasher.update(data: d)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func allocatedBytes(_ path: String) -> Int64 {
        var st = stat()
        return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : 0
    }

    // MARK: applications

    private static let leftoverDirs = [
        "Library/Application Support", "Library/Caches", "Library/Preferences",
        "Library/Logs", "Library/Containers", "Library/Group Containers",
        "Library/HTTPStorages", "Library/Saved Application State",
        "Library/WebKit", "Library/Application Scripts",
    ]

    static func appFootprints(root: String? = nil) -> [AppFootprint] {
        let scope = URL(fileURLWithPath: root ?? home).standardizedFileURL.path
        guard scope == home || scope == "/Applications" || scope == home + "/Applications" else {
            return []
        }
        var out: [AppFootprint] = []
        let fm = FileManager.default
        let roots: [String] = scope == "/Applications" ? ["/Applications"]
            : scope == home + "/Applications" ? [home + "/Applications"]
            : ["/Applications", home + "/Applications"]
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let appPath = root + "/" + entry
                let name = (entry as NSString).deletingPathExtension
                let bid = Bundle(path: appPath)?.bundleIdentifier.flatMap(validBundleID)
                let bundleSize = sizeOf(appPath)

                var leftovers: [String] = []
                if let bid {
                    for rel in leftoverDirs {
                        let base = home + "/" + rel
                        for (component, strict) in [(bid, true), (name, false)] {
                            guard let candidate = safeChild(base: base, component: component,
                                                            strictBundleID: strict) else { continue }
                            if fm.fileExists(atPath: candidate) { leftovers.append(candidate) }
                        }
                        if let plist = safeChild(base: base, component: "\(bid).plist",
                                                 strictBundleID: true), fm.fileExists(atPath: plist) {
                            leftovers.append(plist)
                        }
                    }
                }
                leftovers = Array(Set(leftovers)).sorted()
                let leftoverSize = leftovers.reduce(Int64(0)) { $0 + sizeOf($1) }
                let electron = fm.fileExists(
                    atPath: appPath + "/Contents/Frameworks/Electron Framework.framework")

                out.append(AppFootprint(
                    name: name, path: appPath, bundleID: bid, bundleSize: bundleSize,
                    leftovers: leftovers, leftoverSize: leftoverSize,
                    isElectron: electron, lastUsed: lastUsed(appPath)))
            }
        }
        return out.sorted { $0.total > $1.total }
    }

    private static func validBundleID(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 255,
              id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil
        else { return nil }
        return id
    }

    private static func safeChild(base: String, component: String,
                                  strictBundleID: Bool) -> String? {
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\\"),
              !component.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        if strictBundleID && validBundleID(component) == nil { return nil }
        let candidate = base + "/" + component
        let canonical = Safety.canonical(candidate)
        let parent = Safety.canonical(base)
        guard canonical != parent, canonical.hasPrefix(parent + "/") else { return nil }
        return candidate
    }

    private static func lastUsed(_ path: String) -> Date? {
        let item = MDItemCreate(nil, path as CFString)
        guard let item else { return nil }
        let v = MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString)
        return v as? Date
    }

    /// Library folders over 100 MB whose owning application is no longer installed.
    static func orphans(knownApps: [AppFootprint], root: String? = nil) -> [OrphanData] {
        let scope = URL(fileURLWithPath: root ?? home).standardizedFileURL.path
        guard scope == home else { return [] }
        var known = Set<String>()
        for a in knownApps {
            known.insert(a.name.lowercased())
            if let b = a.bundleID { known.insert(b.lowercased()) }
        }
        var out: [OrphanData] = []
        let fm = FileManager.default
        for rel in ["Library/Application Support", "Library/Containers",
                    "Library/Group Containers"] {
            let base = home + "/" + rel
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for e in entries {
                let low = e.lowercased()
                if low.hasPrefix("com.apple") || low.hasPrefix("group.com.apple")
                    || low.hasPrefix("apple") || low.hasPrefix("org.mozilla") { continue }
                if known.contains(low) { continue }
                let stem = low.components(separatedBy: ".").last ?? low
                if known.contains(stem) { continue }
                if known.contains(where: { $0.count > 4 && (low.contains($0) || $0.contains(low)) }) { continue }
                let full = base + "/" + e
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                let sz = sizeOf(full)
                if sz >= 100 << 20 { out.append(OrphanData(path: full, size: sz)) }
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}
