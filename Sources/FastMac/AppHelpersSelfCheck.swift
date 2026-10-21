import Foundation
import Darwin

enum AppHelpersSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(label)") }
        let home = NSHomeDirectory()
        for relative in [".codex", ".codex/sessions", ".codex/sessions/2026/log.jsonl", ".codex/archived_sessions/old.jsonl", ".codex/history.jsonl", ".claude", ".claude/projects/project/session.jsonl"] {
            let path = home + "/" + relative
            check("history guard protects \(relative)", !Safety.canDelete(path).ok)
            check("history risk discloses data loss for \(relative)", RiskNote.trash(path: path).risk == .risky)
        }
        check("similarly named folder is not mistaken for history", ConversationStorage.owner(of: home + "/.codex/sessions-backup") == nil)
        check("cache siblings remain eligible for review", Safety.canDelete(home + "/.codex/cache/fixture").ok)
        check("ordinary data is no longer labelled regenerable", RiskNote.trash.risk == .caution)
        check("binary size formatting uses explicit binary units", fmt(1 << 30) == "1.0 GiB" && fmt(1 << 20) == "1.0 MiB")

        let desktopPath = "/Applications/Claude.app/Contents/MacOS/Claude"
        let wrapperPath = "/Applications/Claude.app/Contents/Helpers/disclaimer"
        let workerPath = home + "/Library/Application Support/Claude/claude-code/1.0/abc/claude.app/Contents/MacOS/claude"
        func node(_ pid: pid_t, _ parent: pid_t, _ path: String, start: UInt64, uid: uid_t = getuid()) -> AppProcessOwnership.Node {
            .init(identity: ProcessIdentity(pid: pid, uid: uid, startedSeconds: start, startedMicroseconds: 0, path: path), parentPID: parent)
        }
        let main = node(101, 1, desktopPath, start: 10)
        let wrapper = node(102, 101, wrapperPath, start: 11)
        let worker = node(103, 102, workerPath, start: 12)
        check("embedded Claude coding worker joins its verified desktop ancestor", AppProcessOwnership.overrides([main, wrapper, worker])[103]?.bundle == "/Applications/Claude.app")
        check("missing parent does not imply desktop ownership", AppProcessOwnership.overrides([main, worker]).isEmpty)
        check("terminal-launched embedded worker stays separate", AppProcessOwnership.overrides([main, node(103, 999, workerPath, start: 12)]).isEmpty)
        check("different user breaks ownership chain", AppProcessOwnership.overrides([node(101, 1, desktopPath, start: 10, uid: getuid() &+ 1), wrapper, worker]).isEmpty)
        check("reused parent PID newer than child breaks ownership chain", AppProcessOwnership.overrides([main, node(102, 101, wrapperPath, start: 99), worker]).isEmpty)
        check("cycles terminate without grouping", AppProcessOwnership.overrides([node(102, 103, wrapperPath, start: 12), worker]).isEmpty)
        check("unrelated bundle boundaries stop attribution", AppProcessOwnership.overrides([main, node(102, 101, "/Applications/Terminal.app/Contents/MacOS/Terminal", start: 11), worker]).isEmpty)
        func sample(_ node: AppProcessOwnership.Node, cpu: Double, state: ProcessRunState) -> PerfProcSample {
            let owner = MemoryProbe.appOwner(path: node.identity.path)
            return PerfProcSample(pid: node.identity.pid, ppid: node.parentPID, comm: owner.name, appName: owner.name,
                path: node.identity.path, uid: node.identity.uid, owned: true, rss: 100,
                cpuPercent: cpu, cpuCores: cpu / 100, lifetimeCPUSeconds: 1, diskRead: 0, diskWrite: 0,
                appKey: owner.bundle, identity: node.identity, cpuAvailable: true, footprint: 200, runState: state)
        }
        let resolved = PerfProbe.associateEmbeddedWorkers([sample(main, cpu: 1, state: .runnable), sample(wrapper, cpu: 0, state: .waiting), sample(worker, cpu: 0, state: .waiting)])
        let grouped = PerfProbe.group(resolved)
        check("desktop plus workers produces one accurate app total", grouped.count == 1 && grouped.first?.count == 3 && grouped.first?.rss == 300 && grouped.first?.footprint == 600)
        check("coding worker remains identifiable inside combined app", resolved.last?.helperRole == "Coding workers")
        let copy = node(201, 1, "/Volumes/Other/Claude.app/Contents/MacOS/Claude", start: 10)
        check("same-name installations stay separate", PerfProbe.group(PerfProbe.associateEmbeddedWorkers(resolved + [sample(copy, cpu: 0, state: .waiting)])).count == 2)
        let role = AppHelperRole(name: "test", members: resolved)
        check("waiting count uses kernel state independently of CPU", role.waiting == 2 && role.cpu == 1)
        var unavailable = resolved[0]; unavailable.cpuAvailable = false; unavailable.footprint = nil
        let partial = AppHelperRole(name: "partial", members: [unavailable, resolved[1]])
        check("incomplete helper metrics remain unavailable", partial.cpu == nil && partial.footprint == nil)
        check("unknown state remains distinct from waiting", ProcessRunState(rawValue: 99) == nil && ProcessRunState.unknown.label == "Unavailable")
        check("Darwin SRUN with sleeping Mach threads is shown as waiting", ProcessRunState.measured(bsdStatus: 2, runningThreads: 0, threadCount: 7) == .waiting)
        check("a runnable thread keeps the process runnable", ProcessRunState.measured(bsdStatus: 2, runningThreads: 1, threadCount: 7) == .runnable)
        check("stopped state is preserved with no running threads", ProcessRunState.measured(bsdStatus: 4, runningThreads: 0, threadCount: 7) == .stopped)
        check("missing or inconsistent counters never imply waiting", ProcessRunState.measured(bsdStatus: nil, runningThreads: 0, threadCount: 7) == .unknown && ProcessRunState.measured(bsdStatus: 2, runningThreads: 0, threadCount: 0) == .unknown && ProcessRunState.measured(bsdStatus: 2, runningThreads: 9, threadCount: 7) == .unknown)
        check("suspended process is not described as freeing RAM", ProcessRunState.stopped.explanation.contains("does not release"))
        var many = grouped[0]
        many = PerfAppGroup(name: many.name, pids: Array(101...110), cpuPercent: 0, rss: 100,
            diskRead: 0, diskWrite: 0, lifetimeCPUSeconds: 0, appKey: many.id)
        let advice = PerfProbe.advisories(groups: [many], system: .init())
        check("large process counts are not called actively running helpers", !advice.contains { $0.contains("is running") } && advice.contains { $0.contains("waiting helpers") })
        return lines
    }
}
