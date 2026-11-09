import Foundation

// MARK: - Project leftovers
//
// What fills a developer's disk is rarely one cache. It is what tools leave inside and
// beside projects, run after run: a dated audit or report folder per test pass, the frame
// captures behind every rendered video, and a full working copy per agent task. On the
// machine this was written for, these had grown to well over 100 GB within weeks, and none
// of it lives where a cache cleaner looks.
//
// The reading is bounded and cheap enough for Storage Watch's daily pass:
//   • it looks for git projects only in the usual code folders, a few levels deep, and
//     never descends into a project, a dependency folder or a hidden folder;
//   • inside a project it lists only the run folders' own entries (names and dates);
//   • it measures only what it reports, and stops at its time budget.
// It never deletes. Old runs and captures are staged through the normal cleanup review,
// and an agent's working copy is listed for review only, since it can hold unpushed work.

enum ProjectLeftovers {
    /// Folders that collect one dated subfolder per run.
    static let runFolderNames = ["audit", "output", "outputs", "reports", "captures", "evidence"]
    /// The newest runs stay: the last pass and the two before it are the ones people compare.
    static let keepRuns = 3
    static let minimumBytes: Int64 = 50 * 1_048_576
    /// Where code usually lives, relative to the home folder.
    static let codeRoots = ["/Documents", "/Developer", "/Projects", "/Code", "/code", "/src", "/repos", "/GitHub", "/Sites"]
    static let maxDepth = 4
    /// Agent tools that keep one full working copy of a repository per task.
    static let agentWorktreeRoots: [(path: String, tool: String)] = [("/.t3/worktrees", "T3 Code"), ("/.codex/worktrees", "Codex")]
    private static let skipNames: Set<String> = ["node_modules", "Library", "dist", "build", "target", "vendor", "venv", "Pods", "DerivedData"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]

    enum Kind: String, Codable { case oldRun, renderCapture, agentWorktree }

    struct Item: Codable, Equatable, Identifiable {
        var path: String
        var kind: Kind
        var project: String
        var bytes: Int64
        var ageDays: Int
        /// The project's .gitignore names this folder, so removing it changes nothing in git.
        var ignored: Bool
        var tool: String?
        var id: String { path }
    }

    struct Reading: Codable, Equatable {
        var items: [Item] = []
        /// The time budget ran out before every code folder was looked at.
        var truncated = false
        var projectsSeen = 0

        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
        var cleanupItems: [Item] { items.filter { $0.kind != .agentWorktree } }
        var worktreeItems: [Item] { items.filter { $0.kind == .agentWorktree } }
    }

    // MARK: Reading

    static func read(home: String = NSHomeDirectory(), roots: [String]? = nil, now: Date = Date(),
                     timeBudget: TimeInterval = 15, minimumBytes: Int64 = ProjectLeftovers.minimumBytes) -> Reading {
        let t0 = Date()
        var reading = Reading()
        let fm = FileManager.default
        let starts = (roots ?? codeRoots.map { home + $0 }).filter { isRealDirectory($0) }

        for start in starts {
            var queue: [(path: String, depth: Int)] = [(start, 0)]
            while !queue.isEmpty {
                if Date().timeIntervalSince(t0) > timeBudget { reading.truncated = true; break }
                let (dir, depth) = queue.removeFirst()
                if fm.fileExists(atPath: dir + "/.git") {
                    reading.projectsSeen += 1
                    reading.items += projectItems(dir, now: now, minimumBytes: minimumBytes)
                    continue                                      // never descend into a project
                }
                guard depth < maxDepth, let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") && !skipNames.contains(name) {
                    let child = dir + "/" + name
                    if isRealDirectory(child) { queue.append((child, depth + 1)) }
                }
            }
        }

        for root in agentWorktreeRoots {
            let base = home + root.path
            guard isRealDirectory(base), let repos = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for repo in repos.sorted() where !repo.hasPrefix(".") {
                guard let copies = try? fm.contentsOfDirectory(atPath: base + "/" + repo) else { continue }
                for copy in copies.sorted() where !copy.hasPrefix(".") {
                    if Date().timeIntervalSince(t0) > timeBudget { reading.truncated = true; break }
                    let path = base + "/" + repo + "/" + copy
                    guard isRealDirectory(path), fm.fileExists(atPath: path + "/.git") else { continue }
                    let bytes = Analysis.sizeOf(path)
                    guard bytes >= minimumBytes else { continue }
                    reading.items.append(Item(path: path, kind: .agentWorktree, project: repo, bytes: bytes,
                                              ageDays: ageDays(path, now: now), ignored: false, tool: root.tool))
                }
            }
        }
        reading.items.sort { $0.bytes > $1.bytes }
        return reading
    }

    /// Run folders beyond the newest `keepRuns`, and captures whose video is finished.
    static func projectItems(_ project: String, now: Date, minimumBytes: Int64 = ProjectLeftovers.minimumBytes) -> [Item] {
        let fm = FileManager.default
        let name = (project as NSString).lastPathComponent
        let ignoreRules = gitignoreRules(project)
        var items: [Item] = []
        for folder in runFolderNames {
            let base = project + "/" + folder
            guard isRealDirectory(base), let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
            let ignored = isIgnored(folder, rules: ignoreRules)
            let runs = entries.filter { !$0.hasPrefix(".") }.map { base + "/" + $0 }.filter(isRealDirectory)
                .sorted { modified($0) > modified($1) }
            // A film folder with a finished video is a deliverable, not a run: only its capture goes.
            for run in runs where hasFinishedVideo(run) {
                let capture = run + "/capture"
                guard isRealDirectory(capture) else { continue }
                let bytes = Analysis.sizeOf(capture)
                guard bytes >= minimumBytes else { continue }
                items.append(Item(path: capture, kind: .renderCapture, project: name, bytes: bytes,
                                  ageDays: ageDays(capture, now: now), ignored: ignored))
            }
            for run in runs.filter({ !hasFinishedVideo($0) }).dropFirst(keepRuns) {
                let bytes = Analysis.sizeOf(run)
                guard bytes >= minimumBytes else { continue }
                items.append(Item(path: run, kind: .oldRun, project: name, bytes: bytes,
                                  ageDays: ageDays(run, now: now), ignored: ignored))
            }
        }
        return items
    }

    // MARK: Helpers

    static func hasFinishedVideo(_ folder: String) -> Bool {
        let renders = folder + "/renders"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: renders) else { return false }
        return files.contains { file in
            guard videoExtensions.contains((file as NSString).pathExtension.lowercased()) else { return false }
            let size = (try? FileManager.default.attributesOfItem(atPath: renders + "/" + file))?[.size] as? Int64 ?? 0
            return size >= 1_048_576
        }
    }

    /// Top-level folder rules from the project's own .gitignore: `name`, `name/`, `/name`, `/name/`.
    static func gitignoreRules(_ project: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: project + "/.gitignore", encoding: .utf8) else { return [] }
        var rules = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            var rule = line
            if rule.hasPrefix("/") { rule.removeFirst() }
            if rule.hasSuffix("/") { rule.removeLast() }
            if !rule.contains("/") && !rule.contains("*") { rules.insert(rule) }
        }
        return rules
    }

    static func isIgnored(_ folder: String, rules: Set<String>) -> Bool { rules.contains(folder) }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
    }

    static func ageDays(_ path: String, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(modified(path)) / 86_400))
    }

    // MARK: Presentation

    static func detail(_ item: Item) -> String {
        switch item.kind {
        case .oldRun:
            return "An older run in \(((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)/ — the newest \(keepRuns) are kept. "
                + (item.ignored ? "Git ignores this folder, so nothing in the project changes."
                                : "This folder may be tracked in git: commit its removal afterwards.")
        case .renderCapture:
            return "Frames captured to make a video that is already rendered (renders/ holds the finished file). Needed again only to re-cut the video from the same takes."
        case .agentWorktree:
            return "A full working copy \(item.tool ?? "an agent tool") made for one task, untouched for \(item.ageDays)d. Push its branch first: anything not pushed exists only here. Then remove it with `git worktree remove` in the main project."
        }
    }

    static func categoryGroup(_ reading: Reading, elapsed: Double) -> CategoryGroup {
        let findings = reading.items.map { item in
            CategoryFinding(
                id: item.path,
                title: item.kind == .agentWorktree ? "\(item.tool ?? "Agent") copy — \(item.project)/\((item.path as NSString).lastPathComponent)"
                                                   : "\(item.project) — \((item.path as NSString).lastPathComponent)",
                detail: detail(item), paths: [item.path], size: item.bytes,
                tier: item.kind != .agentWorktree && item.ignored ? "safe" : "review",
                ageDays: item.ageDays)
        }
        return CategoryGroup(
            id: "project-leftovers", name: "Project Leftovers", icon: "shippingbox",
            explanation: "Old test and audit runs (the newest \(keepRuns) per folder stay), frame captures behind finished videos, and full working copies left by agent tools.\(reading.truncated ? " The time limit was reached, so some code folders were not looked at." : "")",
            findings: findings, unreadablePaths: [], elapsed: elapsed)
    }
}
