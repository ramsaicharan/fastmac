import Foundation

/// Project leftovers decide what to put in front of someone as removable inside their
/// own projects. These checks pin the rules on a throwaway fixture: the newest runs stay,
/// a film's finished video is never a candidate, the walk never enters a project, and an
/// agent's working copy is only ever offered for review.
enum ProjectLeftoversSelfCheck {
    static func run() -> [String] {
        var out: [String] = []
        func check(_ ok: Bool, _ label: String) { out.append("\(ok ? "PASS" : "FAIL") project leftovers: \(label)") }
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "fastmac-leftovers-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: home) }
        let now = Date()

        func dir(_ path: String, ageDays: Double = 0) {
            try? fm.createDirectory(atPath: home + path, withIntermediateDirectories: true)
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: home + path)
        }
        func file(_ path: String, bytes: Int = 4_096) {
            fm.createFile(atPath: home + path, contents: Data(repeating: 7, count: bytes))
        }

        // A game with five audit runs (ignored by git), output runs and one finished film.
        let game = "/code/Studio/Game"
        dir(game + "/.git")
        fm.createFile(atPath: home + game + "/.gitignore", contents: Data("node_modules/\n/audit/\n".utf8))
        for (i, age) in [10.0, 8, 6, 4, 2].enumerated() {
            dir(game + "/audit/run\(i + 1)"); file(game + "/audit/run\(i + 1)/shot.png")
            dir(game + "/audit/run\(i + 1)", ageDays: age)
        }
        for (i, age) in [9.0, 7, 5, 3].enumerated() {
            dir(game + "/output/pass\(i + 1)"); file(game + "/output/pass\(i + 1)/log.json")
            dir(game + "/output/pass\(i + 1)", ageDays: age)
        }
        dir(game + "/output/film/renders"); file(game + "/output/film/renders/final.mp4", bytes: 1_200_000)
        dir(game + "/output/film/capture"); file(game + "/output/film/capture/frame-0001.jpg")
        dir(game + "/output/film", ageDays: 30)                    // oldest of all, still a deliverable
        // A project nested inside the game, and one deeper than the walk goes.
        dir(game + "/tools/inner/.git"); dir(game + "/tools/inner/audit/a"); dir(game + "/tools/inner/audit/b")
        dir(game + "/tools/inner/audit/c"); dir(game + "/tools/inner/audit/d"); file(game + "/tools/inner/audit/a/x.png")
        let deep = "/code/a/b/c/d/Deep"
        dir(deep + "/.git"); for r in ["r1", "r2", "r3", "r4"] { dir(deep + "/reports/" + r); file(deep + "/reports/\(r)/x.html") }
        // An agent's working copy.
        dir("/.t3/worktrees/Game/t3-1234"); file("/.t3/worktrees/Game/t3-1234/.git"); file("/.t3/worktrees/Game/t3-1234/main.ts")

        let reading = ProjectLeftovers.read(home: home, roots: [home + "/code"], now: now, minimumBytes: 1)
        let paths = Set(reading.items.map { String($0.path.dropFirst(home.count)) })
        check(paths.contains(game + "/audit/run1") && paths.contains(game + "/audit/run2"), "the two oldest audit runs are candidates")
        check(!paths.contains(game + "/audit/run3") && !paths.contains(game + "/audit/run5"), "the newest three audit runs stay")
        check(paths.contains(game + "/output/pass1") && !paths.contains(game + "/output/pass2"), "output runs keep the newest three too")
        check(!paths.contains(game + "/output/film"), "a film with a finished video is never an old run, however old")
        check(paths.contains(game + "/output/film/capture"), "a finished film's capture is a candidate")
        check(!paths.contains { $0.hasPrefix(game + "/tools/inner") }, "the walk never enters a project")
        check(!paths.contains { $0.hasPrefix(deep) }, "the walk stops at its depth limit")
        check(reading.items.first { $0.path.hasSuffix("/audit/run1") }?.ignored == true, "a folder the project ignores is marked so")
        check(reading.items.first { $0.path.hasSuffix("/output/pass1") }?.ignored == false, "a folder git may track is not")
        let copy = reading.items.first { $0.kind == .agentWorktree }
        check(copy?.project == "Game" && copy?.tool == "T3 Code", "an agent's working copy is found and named")
        check(reading.projectsSeen == 1, "one project seen (nested and too-deep ones skipped)")

        let group = ProjectLeftovers.categoryGroup(reading, elapsed: 0)
        check(group.findings.first { $0.id.hasSuffix("/audit/run1") }?.tier == "safe", "an ignored old run is offered as safe")
        check(group.findings.first { $0.id.hasSuffix("/output/pass1") }?.tier == "review", "a possibly tracked run needs review")
        check(group.findings.first { $0.id.hasSuffix("/t3-1234") }?.tier == "review", "a working copy always needs review")

        let empty = ProjectLeftovers.read(home: home, roots: [home + "/code"], now: now)
        check(empty.cleanupItems.isEmpty, "the default 50 MB floor hides small leftovers")

        // Policy.
        let gb: Int64 = 1_073_741_824
        func item(_ kind: ProjectLeftovers.Kind, _ bytes: Int64, project: String = "Game") -> ProjectLeftovers.Item {
            .init(path: "/x/\(UUID().uuidString)", kind: kind, project: project, bytes: bytes, ageDays: 9, ignored: true,
                  tool: kind == .agentWorktree ? "T3 Code" : nil)
        }
        check(StorageWatchPolicy.leftovers(.init(items: [item(.oldRun, gb / 2)])).isEmpty, "under 1 GB raises nothing")
        let big = StorageWatchPolicy.leftovers(.init(items: [item(.oldRun, 4 * gb), item(.renderCapture, 2 * gb, project: "Film"),
                                                             item(.agentWorktree, 3 * gb)]))
        let runs = big.first { $0.id == "leftovers-runs" }
        check(runs?.urgency == .attention && runs?.bytes == 6 * gb, "6 GB of runs and captures needs attention")
        check(runs?.action == .open(.categories), "runs open Categories for review, never a one-click delete")
        check(big.first { $0.id == "leftovers-worktrees" }?.urgency == .comfortable, "3 GB of working copies is shown quietly")
        check(big.allSatisfy { !StorageWatchPolicy.notifiable($0, previouslyNotified: nil) }, "leftovers never send a notification")

        // A state file written before leftovers existed still loads.
        let old = #"{"version":1,"trend":{"points":[]},"caches":{},"apps":{},"notified":{}}"#
        let url = URL(fileURLWithPath: home + "/state.json")
        try? Data(old.utf8).write(to: url)
        let loaded = StorageWatchState.load(from: url)
        check(loaded.leftovers == nil && loaded.version == 1, "an older state file loads without leftovers")
        return out
    }
}
