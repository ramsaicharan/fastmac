import SwiftUI
import Darwin

struct AgentObservedProcess: Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let directory: String?
    var name: String { URL(fileURLWithPath: identity.path).lastPathComponent }
}

struct AgentObservation: Sendable {
    let at: Date
    let processes: [AgentObservedProcess]
    let listedPIDs: Set<pid_t>
    let completeEnumeration: Bool
    let limited: Bool
    let milliseconds: Double
}

struct ObservedAgentSession: Identifiable {
    let root: AgentObservedProcess
    let firstSeen: Date
    var endedAt: Date?
    var rootReadable = true
    var children: [ProcessIdentity: AgentObservedProcess] = [:]
    var readableChildren: Set<ProcessIdentity> = []
    var id: String { "\(root.identity.pid):\(root.identity.startedSeconds):\(root.identity.startedMicroseconds)" }
    var leftovers: [AgentObservedProcess] {
        guard endedAt != nil else { return [] }
        return children.filter { readableChildren.contains($0.key) }.map(\.value).sorted { $0.identity.pid < $1.identity.pid }
    }
}

struct AgentSessionTracker {
    private(set) var sessions: [ObservedAgentSession] = []
    static func agentName(_ path: String) -> String? {
        switch URL(fileURLWithPath: path).lastPathComponent {
        case "claude": "Claude Code"
        case "codex": "Codex CLI"
        case "opencode": "OpenCode"
        case "cursor-agent": "Cursor agent"
        default: nil
        }
    }
    mutating func ingest(_ observation: AgentObservation) {
        let nodes = Dictionary(observation.processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for root in observation.processes where Self.agentName(root.identity.path) != nil {
            if !sessions.contains(where: { $0.root.identity == root.identity }) {
                // Drop oldest ended/empty session first. Never grow without a bound.
                if sessions.count >= 64 {
                    if let index = sessions.firstIndex(where: { $0.endedAt != nil && $0.children.isEmpty }) { sessions.remove(at: index) }
                    else { continue }
                }
                sessions.append(.init(root: root, firstSeen: observation.at))
            }
        }
        for i in sessions.indices {
            let root = sessions[i].root.identity
            if let current = nodes[root.pid] {
                sessions[i].rootReadable = current.identity == root
                if current.identity != root { sessions[i].endedAt = sessions[i].endedAt ?? observation.at }
            } else {
                sessions[i].rootReadable = false
                if observation.completeEnumeration && !observation.listedPIDs.contains(root.pid) {
                    sessions[i].endedAt = sessions[i].endedAt ?? observation.at
                }
            }
            sessions[i].readableChildren.removeAll()
            for identity in Array(sessions[i].children.keys) {
                if let current = nodes[identity.pid] {
                    if current.identity == identity { sessions[i].readableChildren.insert(identity) }
                    else { sessions[i].children.removeValue(forKey: identity) }
                } else if observation.completeEnumeration && !observation.listedPIDs.contains(identity.pid) {
                    sessions[i].children.removeValue(forKey: identity)
                }
            }
        }
        // Associate with the nearest recognized ancestor, only while every link is
        // present in this observation and parent start time precedes child start time.
        for node in observation.processes where Self.agentName(node.identity.path) == nil {
            var child = node
            var visited: Set<pid_t> = [child.identity.pid]
            for _ in 0..<32 {
                guard let parent = nodes[child.parentPID], visited.insert(parent.identity.pid).inserted,
                      Self.started(parent.identity) <= Self.started(child.identity) else { break }
                if Self.agentName(parent.identity.path) != nil {
                    if let i = sessions.firstIndex(where: { $0.root.identity == parent.identity }),
                       sessions[i].endedAt == nil, sessions[i].children.count < 512 {
                        sessions[i].children[node.identity] = node
                        sessions[i].readableChildren.insert(node.identity)
                    }
                    break
                }
                child = parent
            }
        }
    }
    static func started(_ identity: ProcessIdentity) -> Double {
        Double(identity.startedSeconds) + Double(identity.startedMicroseconds) / 1_000_000
    }
}

enum AgentObservationProbe {
    static func capture() -> AgentObservation {
        let began = ProcessInfo.processInfo.systemUptime
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        let count = min(16_384, max(256, Int(needed) / MemoryLayout<pid_t>.stride + 128))
        var pids = [pid_t](repeating: 0, count: count)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(count * MemoryLayout<pid_t>.stride))
        let validCount = max(0, min(count, Int(bytes) / MemoryLayout<pid_t>.stride))
        let listed = Set(pids.prefix(validCount).filter { $0 > 0 })
        var values: [AgentObservedProcess] = [], limited = false
        for pid in listed.sorted() where pid != getpid() {
            if ProcessInfo.processInfo.systemUptime - began > 0.35 || values.count >= 4096 { limited = true; break }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(),
                  let identity = ProcessIdentity.capture(pid: pid), identity.uid == getuid(),
                  identity.startedSeconds == info.pbi_start_tvsec, identity.startedMicroseconds == info.pbi_start_tvusec else { continue }
            let directory = AgentSessionTracker.agentName(identity.path) == nil ? nil : ProjectProbe.workingDirectory(pid: pid)
            guard ProcessIdentity.capture(pid: pid) == identity else { continue }
            values.append(.init(identity: identity, parentPID: pid_t(bitPattern: info.pbi_ppid), directory: directory))
        }
        return .init(at: Date(), processes: values, listedPIDs: listed,
            completeEnumeration: needed > 0 && bytes > 0 && validCount < count,
            limited: limited || validCount == count, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
}

@MainActor
final class AgentSessionsService: ObservableObject {
    @Published private(set) var tracker = AgentSessionTracker()
    @Published private(set) var watching = false
    @Published private(set) var status = "Observation is off. No session history is stored on disk."
    @Published var actionMessage: String?
    @Published private(set) var stopping = false
    private var timer: Timer?
    private var inFlight = false
    private var epoch = 0
    func start() {
        guard !watching else { return }
        watching = true; epoch += 1; refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 1
    }
    func stop() { watching = false; epoch += 1; timer?.invalidate(); timer = nil; status = "Observation paused. Shown sessions are historical; resume before stopping a leftover." }
    func clear() { guard !stopping else { return }; stop(); tracker = .init(); status = "Session observations cleared." }
    private func refresh() {
        guard watching, !inFlight else { return }
        inFlight = true
        let generation = epoch
        Task { [weak self] in
            let observation = await Task.detached(priority: .utility) { AgentObservationProbe.capture() }.value
            guard let self else { return }
            self.inFlight = false
            guard self.watching, self.epoch == generation else { return }
            self.tracker.ingest(observation)
            self.status = "\(observation.processes.count) readable user processes · \(String(format: "%.1f", observation.milliseconds)) ms · \(observation.limited ? "partial observation" : "observed every 5 seconds") · \(observation.at.formatted(date: .omitted, time: .standard))"
        }
    }
    func stopLeftover(_ process: AgentObservedProcess, sessionID: String) {
        guard watching, !stopping,
              let session = tracker.sessions.first(where: { $0.id == sessionID }), session.endedAt != nil,
              session.leftovers.contains(where: { $0.identity == process.identity }) else {
            actionMessage = "Resume observation and review a current leftover before stopping it."; return
        }
        stopping = true
        Task {
            // Existing action implementation checks owner, PID, start time and path
            // again before SIGTERM. No automatic escalation or process-tree killing.
            let result = await PerfActions.terminate(identity: process.identity, name: process.name, force: false)
            actionMessage = result.message; stopping = false; refresh()
        }
    }
    deinit { timer?.invalidate() }
}

struct AgentSessionsView: View {
    @ObservedObject var service: AgentSessionsService
    @State private var pending: AgentObservedProcess?
    @State private var sessionID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Coding-agent sessions").font(.title2.bold())
                Spacer()
                Button(service.watching ? "Pause observation" : "Observe sessions") {
                    if service.watching { service.stop() } else { service.start() }
                }.disabled(service.stopping)
                Button("Clear") { service.clear() }.disabled(service.stopping)
            }
            Text("Opt in while the dashboard is open. Tracks native Claude Code, Codex CLI, OpenCode and cursor-agent executables and observed descendants. Script wrappers, already-orphaned servers and work between samples may be missed. Prompts, arguments, transcripts and environment variables are not read.").font(.callout).foregroundStyle(.secondary)
            Text(service.status).font(.caption).foregroundStyle(.secondary)
            ForEach(service.tracker.sessions.reversed()) { session in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(AgentSessionTracker.agentName(session.root.identity.path) ?? session.root.name) · PID \(session.root.identity.pid)").font(.headline)
                    Text(session.root.directory ?? "Working directory unavailable").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Observed since \(session.firstSeen.formatted(date: .omitted, time: .standard)) · \(session.endedAt == nil ? (session.rootReadable ? "agent process present" : "agent state unavailable") : "agent process ended")").font(.caption)
                    Text("\(session.children.count) retained descendants · \(session.leftovers.count) currently observed leftovers").font(.callout)
                    ForEach(session.leftovers, id: \.identity) { process in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(process.name) · PID \(process.identity.pid)")
                                Text(process.identity.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(process.identity.path)
                            }
                            Spacer()
                            Button("Stop…") { pending = process; sessionID = session.id }
                                .disabled(!service.watching || service.stopping)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            if service.tracker.sessions.isEmpty { Text("No agent process has been observed yet.").foregroundStyle(.secondary) }
            if let message = service.actionMessage { Text(message).font(.callout) }
            Text("Leftover means an observed descendant survived the agent process. It may still be doing useful work. Stopping is always an individual, reviewed request; no force-kill follows automatically.").font(.caption).foregroundStyle(.secondary)
        }
        .alert("Stop this observed leftover?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Send stop request", role: .destructive) {
                if let process = pending { service.stopLeftover(process, sessionID: sessionID) }; pending = nil
            }
        } message: {
            if let process = pending { Text("\(process.name) · PID \(process.identity.pid)\n\(process.identity.path)\n\n" + PerfActions.confirmation(identity: process.identity, force: false)) }
        }
    }
}
