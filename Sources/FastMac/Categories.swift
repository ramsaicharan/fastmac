import Foundation

// MARK: - Category analyzers
//
// Deeper, more specific analyzers than the generic tree view or Analysis.quickWins():
// each one explains *what* a chunk of disk is (an iOS backup, a Chrome profile, a stale
// node_modules) rather than just reporting a folder's size. Findings are staged through
// the same `onStage` closure the host view wires to AppStore.stage(_:reason:) — nothing
// here ever deletes. Safety.canDelete is still the gate at purge time; this file does not
// bypass it and does not need to duplicate it, since staging is not deletion.

struct CategoryFinding: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let paths: [String]
    let size: Int64            // allocated bytes on disk — the headline number
    let logicalSize: Int64?    // set only when it materially exceeds `size` (sparse files)
    let tier: String           // "safe" | "review"
    let ageDays: Int?

    init(id: String, title: String, detail: String, paths: [String], size: Int64,
         logicalSize: Int64? = nil, tier: String, ageDays: Int? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.paths = paths
        self.size = size
        self.logicalSize = (logicalSize != nil && logicalSize! > size) ? logicalSize : nil
        self.tier = tier
        self.ageDays = ageDays
    }
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let explanation: String
    var findings: [CategoryFinding]
    var unreadablePaths: [String]   // exists, but blocked (almost always: no Full Disk Access)
    var elapsed: Double

    var totalSize: Int64 { findings.reduce(0) { $0 + $1.size } }
    var needsFullDiskAccess: Bool { !unreadablePaths.isEmpty }
}

// MARK: - Analyzers

enum Categories {
    static let home = NSHomeDirectory()

    // MARK: readability
    //
    // ~/Library/Mail, MobileSync backups, and (on modern macOS) even Chrome's data
    // directory are TCC-protected: `lstat` succeeds but `opendir` fails with EPERM/EACCES
    // when Full Disk Access has not been granted. Reporting that as "0 bytes, nothing
    // here" would be a silent lie, so every analyzer below routes through this first and
    // records the path as unreadable instead of pretending it is empty.

    enum ReadStatus { case ok, missing, denied }

    static func readStatus(_ path: String) -> ReadStatus {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            guard let d = opendir(path) else {
                return (errno == EACCES || errno == EPERM) ? .denied : .missing
            }
            closedir(d)
        }
        return .ok
    }

    // MARK: 1. iOS device backups

    static func iosBackups() -> CategoryGroup {
        let t0 = Date()
        let base = home + "/Library/Application Support/MobileSync/Backup"
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        let fm = FileManager.default

        switch readStatus(base) {
        case .missing:
            break
        case .denied:
            unreadable.append(base)
        case .ok:
            if let entries = try? fm.contentsOfDirectory(atPath: base) {
                for e in entries.sorted() where !e.hasPrefix(".") {
                    let dir = base + "/" + e
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
                    else { continue }
                    var deviceName = e
                    var productType = ""
                    var lastBackup: Date?
                    if let data = fm.contents(atPath: dir + "/Info.plist"),
                       let plist = try? PropertyListSerialization.propertyList(
                           from: data, options: [], format: nil) as? [String: Any] {
                        deviceName = (plist["Device Name"] as? String) ?? deviceName
                        productType = (plist["Product Type"] as? String) ?? ""
                        lastBackup = plist["Last Backup Date"] as? Date
                    }
                    let size = Analysis.sizeOf(dir)
                    guard size >= 1 << 20 else { continue }
                    let ageDays = lastBackup.map {
                        max(0, Int(Date().timeIntervalSince($0) / 86400))
                    }
                    let ageText = ageDays.map { "\($0)d ago" } ?? "backup date unknown"
                    findings.append(CategoryFinding(
                        id: dir,
                        title: productType.isEmpty ? deviceName : "\(deviceName) — \(productType)",
                        detail: "iOS device backup, last backed up \(ageText). If this device was sold, upgraded, or lost, the backup usually outlives it.",
                        paths: [dir], size: size, tier: "review", ageDays: ageDays))
                }
            } else {
                unreadable.append(base)
            }
        }
        return CategoryGroup(
            id: "ios-backups", name: "iOS Device Backups", icon: "iphone",
            explanation: "Full local backups under MobileSync. A phone you no longer own can leave 10–50 GB behind indefinitely.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    // MARK: 2. Mail

    static func mail() -> CategoryGroup {
        let t0 = Date()
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        let fm = FileManager.default

        let roots: [(path: String, label: String)] = [
            (home + "/Library/Mail", "Mail"),
            (home + "/Library/Containers/com.apple.mail/Data/Library/Mail",
             "Mail (sandboxed container copy)"),
        ]
        for (base, label) in roots {
            switch readStatus(base) {
            case .missing: continue
            case .denied: unreadable.append(base)
            case .ok:
                if let entries = try? fm.contentsOfDirectory(atPath: base) {
                    if entries.filter({ !$0.hasPrefix(".") }).isEmpty { continue }
                    for e in entries.sorted() where !e.hasPrefix(".") {
                        let full = base + "/" + e
                        let size = Analysis.sizeOf(full)
                        guard size >= 5 << 20 else { continue }
                        findings.append(CategoryFinding(
                            id: full, title: "\(label) — \(e)",
                            detail: "Local Mail store (messages, envelope index, downloaded attachments). Deleting loses offline copies not re-fetchable without a full re-sync from the server.",
                            paths: [full], size: size, tier: "review"))
                    }
                } else {
                    unreadable.append(base)
                }
            }
        }
        return CategoryGroup(
            id: "mail", name: "Mail", icon: "envelope",
            explanation: "Downloaded attachments and the envelope index Mail.app keeps locally, per account.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    // MARK: 3. Browser profiles

    private struct ChromiumVendor { let browser: String; let rel: String }
    private static let chromiumVendors: [ChromiumVendor] = [
        .init(browser: "Chrome", rel: "Google/Chrome"),
        .init(browser: "Brave", rel: "BraveSoftware/Brave-Browser"),
        .init(browser: "Edge", rel: "Microsoft Edge"),
        .init(browser: "Arc", rel: "Arc/User Data"),
        .init(browser: "Vivaldi", rel: "Vivaldi"),
        .init(browser: "Chromium", rel: "Chromium"),
    ]
    static let chromiumCacheNames: Set<String> =
        ["Cache", "Code Cache", "GPUCache", "Media Cache", "DawnCache", "GrShaderCache"]
    static let firefoxCacheNames: Set<String> =
        ["cache2", "startupCache", "shader-cache", "OfflineCache"]

    static func browserProfiles() -> CategoryGroup {
        let t0 = Date()
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        let fm = FileManager.default

        for vendor in chromiumVendors {
            let base = home + "/Library/Application Support/" + vendor.rel
            switch readStatus(base) {
            case .missing: continue
            case .denied: unreadable.append(base); continue
            case .ok: break
            }
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else {
                unreadable.append(base); continue
            }
            for e in entries.sorted() {
                let profileDir = base + "/" + e
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: profileDir, isDirectory: &isDir), isDir.boolValue,
                      fm.fileExists(atPath: profileDir + "/Preferences")
                else { continue }
                let profileName = chromiumProfileName(profileDir) ?? e
                findings.append(contentsOf: splitProfile(
                    profileDir: profileDir, browser: vendor.browser, profileName: profileName,
                    cacheNames: chromiumCacheNames,
                    externalCache: home + "/Library/Caches/" + vendor.rel + "/" + e))
            }
        }

        let ffBase = home + "/Library/Application Support/Firefox/Profiles"
        switch readStatus(ffBase) {
        case .missing: break
        case .denied: unreadable.append(ffBase)
        case .ok:
            if let entries = try? fm.contentsOfDirectory(atPath: ffBase) {
                for e in entries.sorted() {
                    let profileDir = ffBase + "/" + e
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: profileDir, isDirectory: &isDir), isDir.boolValue
                    else { continue }
                    findings.append(contentsOf: splitProfile(
                        profileDir: profileDir, browser: "Firefox", profileName: e,
                        cacheNames: firefoxCacheNames,
                        externalCache: home + "/Library/Caches/Firefox/Profiles/" + e))
                }
            } else {
                unreadable.append(ffBase)
            }
        }

        let safariBase = home + "/Library/Safari"
        switch readStatus(safariBase) {
        case .missing: break
        case .denied: unreadable.append(safariBase)
        case .ok:
            let size = Analysis.sizeOf(safariBase)
            if size >= 1 << 20 {
                findings.append(CategoryFinding(
                    id: safariBase, title: "Safari — profile data",
                    detail: "History, bookmarks, saved logins, tab/session state, extensions.",
                    paths: [safariBase], size: size, tier: "review"))
            }
        }
        let safariCache = home + "/Library/Caches/com.apple.Safari"
        if case .ok = readStatus(safariCache) {
            let size = Analysis.sizeOf(safariCache)
            if size >= 1 << 20 {
                findings.append(CategoryFinding(
                    id: safariCache, title: "Safari — cache",
                    detail: "Rebuilt automatically as pages are revisited.",
                    paths: [safariCache], size: size, tier: "safe"))
            }
        }

        return CategoryGroup(
            id: "browsers", name: "Browser Profiles", icon: "globe",
            explanation: "Chrome/Brave/Edge/Arc profile by profile, plus Safari and Firefox. Cache regenerates on its own; profile data is real history, logins and cookies.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    static func chromiumProfileName(_ profileDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: profileDir + "/Preferences"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["profile"] as? [String: Any],
              let name = profile["name"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    /// Splits one browser profile directory into a "cache" finding (safe) and a
    /// "profile data" finding (review) — never a single blended number that hides which
    /// half is regenerable.
    static func splitProfile(profileDir: String, browser: String, profileName: String,
                             cacheNames: Set<String>, externalCache: String) -> [CategoryFinding] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profileDir)
        else { return [] }
        var cachePaths: [String] = []
        var dataPaths: [String] = []
        for e in entries {
            let full = profileDir + "/" + e
            if cacheNames.contains(e) { cachePaths.append(full) } else { dataPaths.append(full) }
        }
        if FileManager.default.fileExists(atPath: externalCache) { cachePaths.append(externalCache) }

        var out: [CategoryFinding] = []
        let cacheSize = cachePaths.reduce(Int64(0)) { $0 + Analysis.sizeOf($1) }
        if cacheSize >= 1 << 20 {
            out.append(CategoryFinding(
                id: profileDir + "#cache", title: "\(browser) · \(profileName) — cache",
                detail: "Rebuilt automatically as pages are revisited.",
                paths: cachePaths, size: cacheSize, tier: "safe"))
        }
        let dataSize = dataPaths.reduce(Int64(0)) { $0 + Analysis.sizeOf($1) }
        if dataSize >= 1 << 20 {
            out.append(CategoryFinding(
                id: profileDir + "#data", title: "\(browser) · \(profileName) — profile data",
                detail: "History, cookies, saved logins, bookmarks, extensions, IndexedDB. Deleting signs you out and clears history for this profile only.",
                paths: dataPaths, size: dataSize, tier: "review"))
        }
        return out
    }

    // MARK: 4. Developer caches by ecosystem

    struct DevCacheDef { let ecosystem: String; let name: String; let relPaths: [String]
                          let tier: String; let cost: String }

    static let devCacheDefs: [DevCacheDef] = [
        .init(ecosystem: "Xcode", name: "DerivedData",
              relPaths: ["/Library/Developer/Xcode/DerivedData"], tier: "safe",
              cost: "rebuild — regenerated on the next build"),
        .init(ecosystem: "Xcode", name: "Archives",
              relPaths: ["/Library/Developer/Xcode/Archives"], tier: "review",
              cost: "these are your only local copy of past release builds and dSYMs"),
        .init(ecosystem: "Xcode", name: "iOS DeviceSupport",
              relPaths: ["/Library/Developer/Xcode/iOS DeviceSupport"], tier: "safe",
              cost: "re-downloaded automatically the next time that iOS version connects"),
        .init(ecosystem: "Xcode", name: "Simulator devices",
              relPaths: ["/Library/Developer/CoreSimulator/Devices"], tier: "review",
              cost: "deletes installed simulators and their app data (runtimes stay)"),
        .init(ecosystem: "Xcode", name: "Simulator caches",
              relPaths: ["/Library/Developer/CoreSimulator/Caches"], tier: "safe",
              cost: "rebuild — regenerated the next time a simulator boots"),
        .init(ecosystem: "Docker", name: "Docker Desktop data",
              relPaths: ["/Library/Containers/com.docker.docker/Data"], tier: "review",
              cost: "images/build cache re-download or rebuild, but named volumes hold real data and are lost"),
        .init(ecosystem: "npm", name: "npm cache",
              relPaths: ["/.npm/_cacache", "/.npm/_npx"], tier: "safe",
              cost: "re-download on the next install"),
        .init(ecosystem: "pnpm", name: "pnpm store",
              relPaths: ["/Library/pnpm/store", "/.pnpm-store", "/Library/Caches/pnpm"],
              tier: "safe", cost: "re-download — pnpm rebuilds its content-addressable store"),
        .init(ecosystem: "Yarn", name: "Yarn cache",
              relPaths: ["/Library/Caches/Yarn", "/.yarn/cache"], tier: "safe",
              cost: "re-download on the next install"),
        .init(ecosystem: "pip", name: "pip cache",
              relPaths: ["/Library/Caches/pip", "/.cache/pip"], tier: "safe",
              cost: "re-download on the next install"),
        .init(ecosystem: "Poetry", name: "Poetry cache",
              relPaths: ["/Library/Caches/pypoetry"], tier: "safe",
              cost: "re-download on the next install"),
        .init(ecosystem: "conda", name: "package cache",
              relPaths: ["/opt/anaconda3/pkgs", "/opt/miniconda3/pkgs",
                         "/miniconda3/pkgs", "/.conda/pkgs"], tier: "safe",
              cost: "re-download on the next install"),
        .init(ecosystem: "Gradle", name: "build caches",
              relPaths: ["/.gradle/caches"], tier: "safe",
              cost: "re-download/rebuild on the next build"),
        .init(ecosystem: "Gradle", name: "wrapper distributions",
              relPaths: ["/.gradle/wrapper/dists"], tier: "safe",
              cost: "re-download on the next build"),
        .init(ecosystem: "Maven", name: "local repository",
              relPaths: ["/.m2/repository"], tier: "safe",
              cost: "re-download on the next build"),
        .init(ecosystem: "Go", name: "module & build cache",
              relPaths: ["/go/pkg/mod", "/Library/Caches/go-build"], tier: "safe",
              cost: "re-download/rebuild on the next `go build`"),
        .init(ecosystem: "Cargo", name: "registry & git cache",
              relPaths: ["/.cargo/registry", "/.cargo/git"], tier: "safe",
              cost: "re-download on the next `cargo build`"),
        .init(ecosystem: "CocoaPods", name: "pod cache",
              relPaths: ["/Library/Caches/CocoaPods"], tier: "safe",
              cost: "re-download on the next `pod install`"),
        .init(ecosystem: "Homebrew", name: "download cache",
              relPaths: ["/Library/Caches/Homebrew"], tier: "safe",
              cost: "re-download on the next `brew install`"),
        .init(ecosystem: "Flutter/Dart", name: "pub package cache",
              relPaths: ["/.pub-cache"], tier: "safe",
              cost: "re-download on the next `pub get` / `flutter pub get`"),
    ]

    static func devCaches() -> CategoryGroup {
        let t0 = Date()
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        var covered: [String] = []

        for def in devCacheDefs {
            var paths: [String] = []
            for rel in def.relPaths {
                let p = home + rel
                switch readStatus(p) {
                case .ok: paths.append(p)
                case .denied: unreadable.append(p)
                case .missing: continue
                }
            }
            guard !paths.isEmpty else { continue }
            let size = paths.reduce(Int64(0)) { $0 + Analysis.sizeOf($1, excluding: covered) }
            guard size >= 5 << 20 else { continue }
            covered.append(contentsOf: paths)
            findings.append(CategoryFinding(
                id: def.ecosystem + "/" + def.name, title: "\(def.ecosystem) — \(def.name)",
                detail: "Deleting costs: \(def.cost).", paths: paths, size: size, tier: def.tier))
        }
        return CategoryGroup(
            id: "dev-caches", name: "Developer Caches", icon: "hammer",
            explanation: "Per-ecosystem package/build caches. Every \"safe\" entry regenerates from a manifest; \"review\" entries can hold data with no source to rebuild from.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    // MARK: 5. Stale project build output

    static let buildOutputNames: Set<String> =
        ["node_modules", ".venv", "venv", "build", "target", ".next", "dist", "__pycache__"]
    /// Regenerable without a rebuild step of its own — pure caches/dependency dirs.
    static let regenerableBuildNames: Set<String> = ["node_modules", ".venv", "venv", "__pycache__"]
    private static let staleWalkSkipNames: Set<String> =
        ["Library", ".Trash", "Pictures", "Movies", "Music", "Public", "Applications", ".git"]

    static func kindDetail(_ name: String) -> String {
        switch name {
        case "node_modules": return "npm/yarn/pnpm dependencies — reinstall with the project's package manager."
        case ".venv", "venv": return "Python virtual environment — recreate with `python -m venv` and reinstall requirements."
        case "__pycache__": return "Compiled Python bytecode — regenerated automatically on next run."
        case "build": return "Generic build output — rebuild from source."
        case "target": return "Cargo/Maven/Gradle build output — rebuild from source."
        case ".next": return "Next.js build cache/output — regenerated by `next build`."
        case "dist": return "Bundled/distribution output — rebuild with the project's build command."
        default: return "Build output."
        }
    }

    /// Prunes the walk: once a directory named e.g. `node_modules` is matched, its
    /// contents are measured with a single stat walk (Analysis.sizeOf) and the traversal
    /// never descends into it looking for further matches — a workspace's nested
    /// `node_modules/**/node_modules` would otherwise multiply the work many times over.
    static func staleBuildOutput(root: String? = nil, staleDays: Int = 30,
                                 timeBudget: TimeInterval = 12, maxDirsVisited: Int = 150_000)
        -> CategoryGroup {
        let t0 = Date()
        let start = URL(fileURLWithPath: root ?? home).standardizedFileURL.path
        var findings: [CategoryFinding] = []
        var visited = 0
        var stack: [String] = [start]

        while let dir = stack.popLast() {
            if visited >= maxDirsVisited { break }
            if visited % 256 == 0, Date().timeIntervalSince(t0) > timeBudget { break }
            visited += 1
            guard let d = opendir(dir) else { continue }
            defer { closedir(d) }
            while let entPtr = readdir(d) {
                let ent = entPtr.pointee
                var buf = ent.d_name
                let name = withUnsafePointer(to: &buf) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                var isDir = ent.d_type == UInt8(DT_DIR)
                if ent.d_type == UInt8(DT_UNKNOWN) {
                    var st = stat()
                    if lstat(dir + "/" + name, &st) == 0 { isDir = (st.st_mode & S_IFMT) == S_IFDIR }
                }
                guard isDir else { continue }
                if name.hasPrefix(".") && name != ".venv" && name != ".next" { continue }
                let full = dir == "/" ? "/" + name : dir + "/" + name

                if buildOutputNames.contains(name) {
                    var st = stat()
                    guard lstat(full, &st) == 0 else { continue }
                    let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                    let ageDays = max(0, Int((Date().timeIntervalSince1970 - mtime) / 86400))
                    guard ageDays >= staleDays else { continue }        // still active — leave it
                    let size = Analysis.sizeOf(full)
                    guard size >= 1 << 20 else { continue }
                    let project = (dir as NSString).lastPathComponent
                    findings.append(CategoryFinding(
                        id: full, title: "\(name) — \(project)",
                        detail: "\(kindDetail(name)) Untouched for \(ageDays)d.",
                        paths: [full], size: size,
                        tier: regenerableBuildNames.contains(name) ? "safe" : "review",
                        ageDays: ageDays))
                    continue    // pruned: never descend into a matched directory
                }
                if staleWalkSkipNames.contains(name) { continue }
                stack.append(full)
            }
        }
        return CategoryGroup(
            id: "stale-build", name: "Stale Build Output", icon: "wrench.and.screwdriver",
            explanation: "node_modules, venvs, build/dist/target/.next folders not touched in \(staleDays)+ days, named by the project that owns them.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: [], elapsed: Date().timeIntervalSince(t0))
    }

    // MARK: 6. Old installers

    static func oldInstallers() -> CategoryGroup {
        let t0 = Date()
        let downloads = home + "/Downloads"
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        let fm = FileManager.default

        switch readStatus(downloads) {
        case .missing: break
        case .denied: unreadable.append(downloads)
        case .ok:
            let installed = installedAppNames()
            if let entries = try? fm.contentsOfDirectory(atPath: downloads) {
                for e in entries {
                    let ext = (e as NSString).pathExtension.lowercased()
                    guard ["dmg", "pkg", "zip"].contains(ext) else { continue }
                    let full = downloads + "/" + e
                    var st = stat()
                    guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                    let size = Int64(st.st_blocks) * 512
                    guard size >= 5 << 20 else { continue }
                    let mtime = TimeInterval(st.st_mtimespec.tv_sec)
                    let ageDays = max(0, Int((Date().timeIntervalSince1970 - mtime) / 86400))
                    let stem = installerStem(e)
                    let matched = installed.first { appNameMatches($0, stem) }
                    let tier = matched != nil ? "safe" : "review"
                    let detail = matched != nil
                        ? "A matching app, \"\(matched!)\", is already in /Applications — this installer is likely redundant."
                        : "No matching app found in /Applications. Keep it if you might need to reinstall."
                    findings.append(CategoryFinding(
                        id: full, title: e, detail: detail, paths: [full], size: size,
                        tier: tier, ageDays: ageDays))
                }
            } else {
                unreadable.append(downloads)
            }
        }
        return CategoryGroup(
            id: "old-installers", name: "Old Installers", icon: "shippingbox",
            explanation: ".dmg/.pkg/.zip installers in Downloads, checked against what's already in /Applications.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    /// Strips a trailing version-ish suffix so "Google Chrome-131.0.6778.109.dmg" lines
    /// up with the installed app "Google Chrome". Deliberately conservative — a miss just
    /// means the installer is filed under "review" instead of "safe".
    static func installerStem(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension
        s = s.replacingOccurrences(of: #"[-_ ]v?\d+(\.\d+)+.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func installedAppNames() -> [String] {
        let fm = FileManager.default
        var names: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            if let entries = try? fm.contentsOfDirectory(atPath: root) {
                names.append(contentsOf: entries.filter { $0.hasSuffix(".app") }
                    .map { ($0 as NSString).deletingPathExtension })
            }
        }
        return names
    }

    static func appNameMatches(_ appName: String, _ stem: String) -> Bool {
        let a = appName.lowercased().replacingOccurrences(of: " ", with: "")
        let b = stem.lowercased().replacingOccurrences(of: " ", with: "")
        guard a.count > 2, b.count > 2 else { return false }
        return a.contains(b) || b.contains(a)
    }

    // MARK: 7. Sparse-file honesty

    static func sparseDescription(logical: Int64, allocated: Int64) -> String {
        if logical > allocated * 2 {
            return "Sparse — reports \(fmt(logical)) logical but only \(fmt(allocated)) is actually written to disk. The gap is not reclaimable by deleting other files."
        }
        return "Disk image, mostly full — \(fmt(logical)) logical, \(fmt(allocated)) allocated."
    }

    private static let sparseVMDirs: [String] = [
        home + "/Library/Containers/com.docker.docker/Data/vms",
        home + "/Library/Group Containers/group.com.docker/Data/vms",
        home + "/Parallels",
        home + "/Documents/Virtual Machines.localized",
        home + "/Library/Containers/com.utmapp.UTM/Data/Documents",
    ]
    private static let sparseExtensions: Set<String> =
        ["raw", "qcow2", "vdi", "vmdk", "hdd", "pvm"]

    static func sparseFiles() -> CategoryGroup {
        let t0 = Date()
        var findings: [CategoryFinding] = []
        var unreadable: [String] = []
        var files: [String] = []

        for dir in sparseVMDirs {
            switch readStatus(dir) {
            case .denied: unreadable.append(dir)
            case .missing: continue
            case .ok: findExtensions(in: dir, exts: sparseExtensions, into: &files, depth: 5)
            }
        }
        files = Array(Set(files))

        for path in files.sorted() {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let allocated = Int64(st.st_blocks) * 512
            let logical = Int64(st.st_size)
            guard allocated >= 50 << 20 || logical >= 50 << 20 else { continue }
            findings.append(CategoryFinding(
                id: path, title: (path as NSString).lastPathComponent,
                detail: sparseDescription(logical: logical, allocated: allocated),
                paths: [path], size: allocated, logicalSize: logical, tier: "review"))
        }
        return CategoryGroup(
            id: "sparse-files", name: "VM & Disk Images", icon: "externaldrive.badge.questionmark",
            explanation: "Docker/Parallels/UTM disk images. These headline allocated bytes, not the inflated logical size sparse files report.",
            findings: findings.sorted { $0.size > $1.size },
            unreadablePaths: unreadable, elapsed: Date().timeIntervalSince(t0))
    }

    static func findExtensions(in dir: String, exts: Set<String>, into out: inout [String],
                               depth: Int) {
        guard depth > 0, let d = opendir(dir) else { return }
        defer { closedir(d) }
        while let entPtr = readdir(d) {
            let ent = entPtr.pointee
            var buf = ent.d_name
            let name = withUnsafePointer(to: &buf) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            let full = dir + "/" + name
            if ent.d_type == UInt8(DT_DIR) {
                findExtensions(in: full, exts: exts, into: &out, depth: depth - 1)
            } else if ent.d_type == UInt8(DT_REG) || ent.d_type == UInt8(DT_UNKNOWN) {
                if exts.contains((name as NSString).pathExtension.lowercased()) { out.append(full) }
            }
        }
    }

    // MARK: sweep

    static func sweep(root: String? = nil) -> [CategoryGroup] {
        [
            iosBackups(),
            mail(),
            browserProfiles(),
            devCaches(),
            staleBuildOutput(root: root),
            oldInstallers(),
            sparseFiles(),
        ]
    }
}
