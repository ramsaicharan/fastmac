import Foundation

/// Verifies the category analyzers' logic without depending on this machine actually
/// having Chrome, Mail data, or an iOS backup readable — most of that is gated behind
/// Full Disk Access in this dev environment (confirmed on the real machine: `opendir`
/// on ~/Library/Mail and MobileSync/Backup returns EPERM). So the checks split in two:
/// pure logic (regex stemming, name matching, sparse-file arithmetic, prune correctness)
/// tested against synthetic fixtures, and a light end-to-end run of the real sweep that
/// only asserts structural invariants and a time budget — it must not crash or hang, and
/// it must never propose a Safety-protected path, whatever this machine happens to have.
enum CategorySelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ got: @autoclosure () -> Any, _ want: Any) {
            let g = "\(got())"
            let ok = g == "\(want)"
            lines.append("\(ok ? "PASS" : "FAIL")  \(label): got \(g), want \(want)")
        }
        func checkTrue(_ label: String, _ cond: @autoclosure () -> Bool) {
            lines.append("\(cond() ? "PASS" : "FAIL")  \(label)")
        }

        // MARK: readStatus

        check("readStatus missing path", Categories.readStatus("/no/such/path/\(UUID())"), Categories.ReadStatus.missing)
        check("readStatus readable home", Categories.readStatus(NSHomeDirectory()), Categories.ReadStatus.ok)

        let fm = FileManager.default
        let lockedDir = NSTemporaryDirectory() + "fastmac-cat-locked-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: lockedDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir)
        check("readStatus permission-denied dir", Categories.readStatus(lockedDir), Categories.ReadStatus.denied)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir)
        try? fm.removeItem(atPath: lockedDir)

        // MARK: installer stemming / app matching

        check("installerStem strips version", Categories.installerStem("Google Chrome-131.0.6778.109.dmg"),
              "Google Chrome")
        check("installerStem strips trailing (n)", Categories.installerStem("Installer (2).pkg"), "Installer")
        checkTrue("appNameMatches exact", Categories.appNameMatches("Visual Studio Code", "Visual Studio Code"))
        checkTrue("appNameMatches substring", Categories.appNameMatches("Google Chrome", "Chrome"))
        checkTrue("appNameMatches rejects short noise", !Categories.appNameMatches("Xcode", "X"))

        // MARK: sparse-file description headlines allocated, not logical

        let sparseDetail = Categories.sparseDescription(logical: 10 << 30, allocated: 1 << 30)
        checkTrue("sparse description flags a sparse file", sparseDetail.contains("Sparse"))
        let fullDetail = Categories.sparseDescription(logical: 10 << 30, allocated: 9 << 30)
        checkTrue("sparse description accepts a mostly-full image",
                  fullDetail.contains("mostly full") && !fullDetail.contains("gap is not reclaimable"))

        // MARK: CategoryFinding drops logicalSize when it isn't materially larger

        let f1 = CategoryFinding(id: "a", title: "t", detail: "d", paths: ["/a"],
                                  size: 100, logicalSize: 100, tier: "review")
        check("CategoryFinding suppresses equal logicalSize", f1.logicalSize == nil, true)
        let f2 = CategoryFinding(id: "b", title: "t", detail: "d", paths: ["/b"],
                                  size: 100, logicalSize: 1000, tier: "review")
        check("CategoryFinding keeps larger logicalSize", f2.logicalSize ?? -1, Int64(1000))

        // MARK: stale build-output walk — synthetic project tree, checks pruning + age filter

        let root = NSTemporaryDirectory() + "fastmac-cat-stale-\(UUID().uuidString)"
        let staleProject = root + "/projectA/node_modules"
        let nestedInsideStale = staleProject + "/some-pkg/node_modules"   // must NOT be walked into
        let freshProject = root + "/projectB/node_modules"
        let reviewOutput = root + "/projectC/dist"
        for d in [staleProject, nestedInsideStale, freshProject, reviewOutput] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        // Pad each with >1 MB so the size threshold doesn't filter them out.
        for d in [staleProject, nestedInsideStale, freshProject, reviewOutput] {
            fm.createFile(atPath: d + "/pad.bin", contents: Data(count: 2 << 20))
        }
        let oldDate = Date().addingTimeInterval(-60 * 86400)
        for d in [staleProject, reviewOutput] {
            try? fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: d)
        }
        // freshProject and the nested node_modules keep "now" as their mtime.

        let group = Categories.staleBuildOutput(root: root, staleDays: 30)
        let paths = Set(group.findings.map { $0.id })
        checkTrue("stale walk finds the stale node_modules", paths.contains(staleProject))
        checkTrue("stale walk excludes the fresh node_modules", !paths.contains(freshProject))
        checkTrue("stale walk finds stale dist as review-tier",
                  group.findings.first { $0.id == reviewOutput }?.tier == "review")
        checkTrue("stale walk finds node_modules as safe-tier",
                  group.findings.first { $0.id == staleProject }?.tier == "safe")
        checkTrue("stale walk prunes — never descends into a matched node_modules",
                  !paths.contains(nestedInsideStale))
        checkTrue("stale walk stays fast on a tiny synthetic tree", group.elapsed < 5.0)
        try? fm.removeItem(atPath: root)

        // MARK: findExtensions depth-limited walk

        let vmRoot = NSTemporaryDirectory() + "fastmac-cat-vm-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: vmRoot + "/a/b", withIntermediateDirectories: true)
        fm.createFile(atPath: vmRoot + "/disk.raw", contents: Data(count: 16))
        fm.createFile(atPath: vmRoot + "/a/b/nested.qcow2", contents: Data(count: 16))
        fm.createFile(atPath: vmRoot + "/notes.txt", contents: Data(count: 16))
        var found: [String] = []
        Categories.findExtensions(in: vmRoot, exts: ["raw", "qcow2"], into: &found, depth: 5)
        checkTrue("findExtensions matches top-level .raw", found.contains(vmRoot + "/disk.raw"))
        checkTrue("findExtensions matches nested .qcow2", found.contains(vmRoot + "/a/b/nested.qcow2"))
        checkTrue("findExtensions ignores non-matching extensions",
                  !found.contains(vmRoot + "/notes.txt"))
        try? fm.removeItem(atPath: vmRoot)

        // MARK: dev-cache coverage — every ecosystem the brief calls out is represented

        let ecosystems = Set(Categories.devCacheDefs.map { $0.ecosystem })
        for want in ["Xcode", "Docker", "npm", "pnpm", "Yarn", "pip", "Poetry", "conda",
                     "Gradle", "Maven", "Go", "Cargo", "CocoaPods", "Homebrew", "Flutter/Dart"] {
            checkTrue("dev-cache ecosystem covered: \(want)", ecosystems.contains(want))
        }

        // MARK: end-to-end sweep — must not crash, must not hang, must not stage anything protected

        let t0 = Date()
        let sweep = Categories.sweep()
        let elapsed = Date().timeIntervalSince(t0)
        check("sweep returns all 7 categories", sweep.count, 7)
        checkTrue("sweep category ids are unique", Set(sweep.map { $0.id }).count == sweep.count)
        checkTrue("sweep completes well under a minute on this machine", elapsed < 60)

        var offendingPaths: [String] = []
        for g in sweep {
            for f in g.findings {
                for p in f.paths where Safety.protected.contains(Safety.canonical(p)) {
                    offendingPaths.append(p)
                }
            }
        }
        checkTrue("sweep never proposes a Safety-protected path", offendingPaths.isEmpty)

        lines.append("PASS  timing: sweep total \(String(format: "%.2f", elapsed))s — "
                     + sweep.map { "\($0.name)=\(String(format: "%.2f", $0.elapsed))s" }.joined(separator: ", "))

        return lines
    }
}
