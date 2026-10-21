import Foundation
import Darwin

/// Supplemental ownership for an embedded executable outside its desktop bundle.
/// A path alone is insufficient: terminal-launched Claude Code must stay separate.
enum AppProcessOwnership {
    struct Node {
        let identity: ProcessIdentity
        let parentPID: pid_t
    }

    static func isClaudeCodingWorker(_ path: String) -> Bool {
        path.contains("/Library/Application Support/Claude/claude-code/")
            && path.hasSuffix("/claude.app/Contents/MacOS/claude")
    }

    static func overrides(_ nodes: [Node]) -> [pid_t: (name: String, bundle: String)] {
        let byPID = Dictionary(nodes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [pid_t: (name: String, bundle: String)] = [:]
        for node in nodes where isClaudeCodingWorker(node.identity.path) {
            var child = node
            var visited: Set<pid_t> = [child.identity.pid]
            for _ in 0..<32 {
                guard let parent = byPID[child.parentPID], visited.insert(parent.identity.pid).inserted,
                      parent.identity.uid == node.identity.uid,
                      AgentSessionTracker.started(parent.identity) <= AgentSessionTracker.started(child.identity) else { break }
                let owner = MemoryProbe.appOwner(path: parent.identity.path)
                if owner.name == "Claude", parent.identity.path == owner.bundle + "/Contents/MacOS/Claude" {
                    result[node.identity.pid] = owner
                    break
                }
                // Do not cross through another app to claim its independently launched work.
                if parent.identity.path.contains(".app/"), owner.name != "Claude",
                   !isClaudeCodingWorker(parent.identity.path) { break }
                child = parent
            }
        }
        return result
    }
}

enum ProcessRunState: UInt32 {
    // Darwin sys/proc.h process states, not CPU activity over an interval.
    case unknown = 0, starting = 1, runnable = 2, waiting = 3, stopped = 4, zombie = 5
    static func measured(bsdStatus: UInt32?, runningThreads: Int32, threadCount: Int32) -> ProcessRunState {
        guard let bsdStatus, let status = ProcessRunState(rawValue: bsdStatus) else { return .unknown }
        // On macOS p_stat commonly stays SRUN while every Mach thread waits.
        // Keep stopped/starting/exited states, but refine SRUN with task counters.
        guard status == .runnable else { return status }
        guard threadCount > 0, runningThreads >= 0, runningThreads <= threadCount else { return .unknown }
        return runningThreads == 0 ? .waiting : .runnable
    }
    var label: String {
        switch self {
        case .unknown: "Unavailable"
        case .starting: "Starting"
        case .runnable: "Runnable"
        case .waiting: "Waiting"
        case .stopped: "Stopped"
        case .zombie: "Exiting"
        }
    }
    var explanation: String {
        switch self {
        case .waiting: "No runnable threads at this sample. Threads usually wait for commands, messages, timers or I/O; these counters do not identify the exact event. This does not establish that the process is unnecessary or safe to stop. Its memory can remain allocated."
        case .runnable: "Running or ready to run when the scheduler gives it CPU time. Use the measured CPU rate to assess activity."
        case .stopped: "Execution is suspended. Suspending a process does not release its allocated memory."
        case .zombie: "The process has exited and its parent has not yet collected the exit status."
        case .starting: "The process is starting."
        case .unknown: "A current kernel state was not available."
        }
    }
}

extension PerfProcSample {
    var helperRole: String {
        let base = URL(fileURLWithPath: path).lastPathComponent
        if AppProcessOwnership.isClaudeCodingWorker(path) { return "Coding workers" }
        if base.contains("Renderer") { return "Renderers" }
        if base == "node" { return "Node helpers" }
        if base == "node_repl" { return "JavaScript runtimes" }
        if base == "codex" { return "Coding backend" }
        if base.contains("Service") || base.contains("Helper") { return "App services" }
        return base.isEmpty ? comm : base
    }
}
