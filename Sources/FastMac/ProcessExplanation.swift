import SwiftUI

struct ProcessExplanation {
    let role: String
    let ownership: String
    let consequence: String

    static func explain(path: String, name: String) -> ProcessExplanation {
        let base = URL(fileURLWithPath: path).lastPathComponent
        let systemRoles = [
            "WindowServer": "Composes windows and displays. Activity often rises with external displays, animation or screen sharing.",
            "kernel_task": "macOS kernel work, including drivers and resource management. Its CPU use does not identify a particular app.",
            "mds": "Maintains the Spotlight search index. Indexing may follow updates or file changes.",
            "mds_stores": "Maintains Spotlight index data.",
            "mdworker_shared": "Extracts metadata for Spotlight search.",
            "launchd": "Starts and supervises system and user services.",
            "backupd": "Runs Time Machine backup work."
        ]
        if (path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path == "/sbin/launchd"), let role = systemRoles[base] {
            return .init(role: role, ownership: "System executable at \(path)",
                         consequence: "Leave this system service running. Investigate the workload or use the relevant macOS settings instead.")
        }
        if path.contains(".app/") {
            let owner = MemoryProbe.appOwner(path: path).name
            let helper = path.contains("/Helpers/") || path.contains("/Frameworks/") || base.contains("Helper")
            let role: String
            if AppProcessOwnership.isClaudeCodingWorker(path) {
                role = "Claude's embedded coding executable. FastMac includes it in Claude's total only when a readable parent chain reaches the desktop app. A terminal-launched instance stays separate."
            } else if base == "node" || base == "node_repl" {
                role = "A JavaScript tool runtime bundled with \(owner). It can retain variables, connections and loaded libraries between requests. A process count does not tell you how many AI tasks are active."
            } else if base.contains("Renderer") {
                role = "Renders interface or embedded web content for \(owner). One renderer does not necessarily equal one conversation; an exact panel cannot be identified from its executable."
            } else {
                role = helper ? "A helper inside \(owner)'s application bundle. Helpers can handle rendering, media or background tasks; the exact job is not known from this path." : "An executable inside \(owner)'s application bundle."
            }
            return .init(role: role,
                         ownership: "Associated by executable location: \(path)",
                         consequence: "Prefer quitting the owning app normally. Stopping a helper may interrupt work or cause the app to relaunch it. Unsaved work can be lost.")
        }
        if let runtime = ProjectProbe.runtimeName(base) {
            return .init(role: "\(runtime) runtime. It may be serving a project, running a build or doing other work; its executable alone does not establish which.", ownership: path.isEmpty ? "Executable path unavailable" : "Executable: \(path)",
                         consequence: "Review the project and ports before stopping it. SIGTERM may end a build or server without saving state.")
        }
        return .init(role: "FastMac does not have a verified explanation for this process.",
                     ownership: path.isEmpty ? "Executable path unavailable" : "Executable: \(path)",
                     consequence: "An unfamiliar name is not evidence of a problem. Review its owner and purpose before quitting it.")
    }
}

struct ProcessExplanationView: View {
    let process: PerfProcSample
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let explanation = ProcessExplanation.explain(path: process.path, name: process.comm)
        VStack(alignment: .leading, spacing: 16) {
            Text("What is \(process.comm.isEmpty ? process.appName : process.comm)?").font(.title2.bold())
            Text(explanation.role)
            Text("Grouped under \(process.appName) · \(process.helperRole)").font(.callout.weight(.medium))
            Text("Kernel state: \(process.runState.label)").font(.headline)
            Text(process.runState.explanation).font(.callout).foregroundStyle(.secondary)
            Text(process.cpuAvailable ? String(format: "Recent CPU: %.2f%% of one core", process.cpuPercent) : "Recent CPU: awaiting a valid pair of readings")
                .font(.caption).monospacedDigit()
            Text(explanation.ownership).font(.caption.monospaced()).textSelection(.enabled)
            Text("PID \(process.pid) · parent PID \(process.ppid) · user \(process.uid)").font(.caption).foregroundStyle(.secondary)
            Text(explanation.consequence).foregroundStyle(.secondary)
            Text("This explains the executable's usual role, not why it is busy right now. CPU and memory readings are observations, not a diagnosis.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 530)
    }
}
