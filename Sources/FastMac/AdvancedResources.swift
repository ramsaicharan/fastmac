import Foundation
import Darwin

struct DockerContainerReading: Sendable, Identifiable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String
    var cpuPercent: Double?
    var memoryUsage: String?
    var networkIO: String?
    var blockIO: String?
}

struct DockerOverviewSnapshot: Sendable {
    var at = Date()
    var contextName: String?
    var containers: [DockerContainerReading] = []
    var incomplete = false
    var message = "Docker has not been refreshed."
}

/// Docker discovery never inherits shell overrides or credentials. First inspect
/// the saved context without contacting a daemon, then pin every daemon request
/// to its validated Unix socket. TCP/SSH endpoints are refused before any request.
enum DockerResourceProbe {
    struct Context: Sendable, Equatable {
        let name: String
        let endpoint: String
    }

    enum ReadOperation { case containers, stats }
    static let contextFormat = "{{json .Name}}\t{{json .Endpoints.docker.Host}}"
    static let containerFormat = "{{json .ID}}\t{{json .Names}}\t{{json .Image}}\t{{json .State}}\t{{json .Status}}\t{{json .Ports}}"
    static let statsFormat = "{{json .ID}}\t{{json .CPUPerc}}\t{{json .MemUsage}}\t{{json .NetIO}}\t{{json .BlockIO}}"

    static func refresh() -> DockerOverviewSnapshot {
        var result = DockerOverviewSnapshot()
        guard let executable = executablePath() else {
            result.message = "Docker CLI was not found. Install or open your existing Docker runtime to use this panel."
            return result
        }
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".docker").path
        let contextCommand = ProjectProbe.runBounded(executable: executable,
            arguments: ["--config", config, "context", "inspect", "--format", contextFormat], timeout: 2, byteLimit: 8_192)
        guard contextCommand.exitCode == 0, !contextCommand.timedOut, !contextCommand.truncated,
              let context = parseContext(contextCommand.data) else {
            result.message = "Saved Docker context unavailable. Remote contexts and non-Unix endpoints are not supported."
            return result
        }
        result.contextName = context.name
        guard let listArguments = arguments(endpoint: context.endpoint, operation: .containers) else {
            result.message = "This Docker context does not use a local Unix socket."
            return result
        }
        let listed = ProjectProbe.runBounded(executable: executable, arguments: ["--config", config] + listArguments, timeout: 3, byteLimit: 262_144)
        guard listed.error == nil, listed.exitCode == 0 || listed.timedOut || listed.truncated else {
            result.message = "The saved local Docker daemon is unavailable. Start your runtime, then refresh."
            return result
        }
        let all = parseContainers(listed.data)
        result.containers = Array(all.prefix(128))
        result.incomplete = listed.timedOut || listed.truncated || all.count > 128 || (!listed.data.isEmpty && all.isEmpty)
        let running = result.containers.filter { $0.state == "running" }.map(\.id)
        let selected = Array(running.prefix(32))
        if running.count > 32 { result.incomplete = true }
        if !selected.isEmpty, let statsArguments = arguments(endpoint: context.endpoint, operation: .stats, containerIDs: selected) {
            let measured = ProjectProbe.runBounded(executable: executable, arguments: ["--config", config] + statsArguments, timeout: 4, byteLimit: 262_144)
            if measured.error == nil, measured.exitCode == 0, !measured.timedOut, !measured.truncated {
                let stats = parseStats(measured.data)
                for index in result.containers.indices {
                    guard let reading = stats[result.containers[index].id] else { continue }
                    result.containers[index].cpuPercent = reading.cpuPercent
                    result.containers[index].memoryUsage = reading.memoryUsage
                    result.containers[index].networkIO = reading.networkIO
                    result.containers[index].blockIO = reading.blockIO
                }
                if selected.contains(where: { stats[$0] == nil }) { result.incomplete = true }
            } else { result.incomplete = true }
        }
        result.at = Date()
        result.message = result.incomplete
            ? "Partial Docker snapshot. Resource readings cover at most 32 running containers."
            : "\(result.containers.count) container\(result.containers.count == 1 ? "" : "s") · saved context · local Unix socket."
        return result
    }

    static func executablePath() -> String? {
        ["/Applications/Docker.app/Contents/Resources/bin/docker", "/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isLocalEndpoint(_ endpoint: String) -> Bool {
        guard endpoint.hasPrefix("unix:///"), endpoint.utf8.count <= 1_024,
              !endpoint.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: endpoint), url.scheme == "unix", url.host?.isEmpty != false,
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), url.path.count > 1,
              !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !url.path.split(separator: "/").contains("..") else { return false }
        return true
    }

    static func parseContext(_ data: Data) -> Context? {
        let rows = decodedRows(data)
        guard rows.count == 1, let row = rows.first, row.count == 2,
              !row[0].isEmpty, row[0].utf8.count <= 128,
              !row[0].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              isLocalEndpoint(row[1]) else { return nil }
        return Context(name: row[0], endpoint: row[1])
    }

    static func isContainerID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Only these two read operations can be constructed. No free-form CLI flags,
    /// command execution, environment inspection, stop, delete or prune operations.
    static func arguments(endpoint: String, operation: ReadOperation, containerIDs: [String] = []) -> [String]? {
        guard isLocalEndpoint(endpoint) else { return nil }
        let prefix = ["--host", endpoint, "--tls=false"]
        switch operation {
        case .containers:
            guard containerIDs.isEmpty else { return nil }
            return prefix + ["container", "ls", "--all", "--no-trunc", "--format", containerFormat]
        case .stats:
            guard !containerIDs.isEmpty, containerIDs.count <= 32, containerIDs.allSatisfy(isContainerID) else { return nil }
            return prefix + ["container", "stats", "--no-stream", "--no-trunc", "--format", statsFormat] + containerIDs
        }
    }

    static func parseContainers(_ data: Data) -> [DockerContainerReading] {
        var seen = Set<String>()
        return decodedRows(data).compactMap { row in
            guard row.count == 6, isContainerID(row[0]), seen.insert(row[0]).inserted else { return nil }
            return DockerContainerReading(id: row[0], name: row[1], image: row[2], state: row[3], status: row[4], ports: row[5])
        }
    }

    struct Stats: Sendable {
        var cpuPercent: Double?
        var memoryUsage: String?
        var networkIO: String?
        var blockIO: String?
    }

    static func parseStats(_ data: Data) -> [String: Stats] {
        var result: [String: Stats] = [:]
        for row in decodedRows(data) where row.count == 5 && isContainerID(row[0]) {
            let rawCPU = row[1].hasSuffix("%") ? String(row[1].dropLast()) : ""
            let cpu = Double(rawCPU).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            result[row[0]] = Stats(cpuPercent: cpu, memoryUsage: available(row[2]), networkIO: available(row[3]), blockIO: available(row[4]))
        }
        return result
    }

    private static func available(_ string: String) -> String? {
        string.isEmpty || string == "--" || string == "N/A" ? nil : string
    }

    private static func decodedRows(_ data: Data) -> [[String]] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            var row: [String] = []
            for field in fields {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(field.utf8)), value.utf8.count <= 8_192 else { return nil }
                row.append(value)
            }
            return row
        }
    }
}

struct SleepAssertionReading: Sendable, Identifiable {
    let pid: pid_t
    let processName: String
    let assertionID: String
    let kind: String
    let duration: String
    var id: String { "\(pid)-\(assertionID)" }
}

struct SleepAssertionsSnapshot: Sendable {
    var at = Date()
    var available = false
    var summary: [String: Int] = [:]
    var assertions: [SleepAssertionReading] = []
    var incomplete = false
    var message = "Power assertions have not been refreshed."
}

enum SleepAssertionProbe {
    /// pmset's installed manual documents -g assertions as a read-only summary of
    /// power assertions. User-supplied flags and power-management changes are absent.
    static func refresh() -> SleepAssertionsSnapshot {
        let command = ProjectProbe.runBounded(executable: "/usr/bin/pmset", arguments: ["-g", "assertions"], timeout: 2, byteLimit: 262_144)
        var result = parse(command.data)
        result.incomplete = result.incomplete || command.timedOut || command.truncated
        if command.error != nil || (command.exitCode != 0 && !result.incomplete) {
            result.message = "macOS power assertions are unavailable."
        } else if !result.available {
            result.message = "The macOS power-assertion output format was not recognized."
        } else if result.incomplete {
            result.message = "Partial power-assertion snapshot. Refresh to try again."
        } else {
            result.message = "\(result.assertions.count) process assertion\(result.assertions.count == 1 ? "" : "s") reported by macOS."
        }
        return result
    }

    static func parse(_ data: Data) -> SleepAssertionsSnapshot {
        var result = SleepAssertionsSnapshot()
        let pattern = #"^\s*pid\s+(\d+)\(([^\r\n)]*)\):\s*\[(0x[0-9a-fA-F]+)\]\s+(\d+:\d+:\d+)\s+([A-Za-z][A-Za-z0-9]*)\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let summaryRegex = try? NSRegularExpression(pattern: #"^\s*([A-Za-z][A-Za-z0-9]*)\s+(\d+)\s*$"#)
        var inSummary = false
        var seen = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let string = String(line)
            if string.contains("Assertion status system-wide:") { result.available = true; inSummary = true; continue }
            if string.contains("Listed by owning process:") { inSummary = false; continue }
            let whole = NSRange(string.startIndex..<string.endIndex, in: string)
            if inSummary, let match = summaryRegex?.firstMatch(in: string, range: whole),
               let keyRange = Range(match.range(at: 1), in: string), let countRange = Range(match.range(at: 2), in: string),
               let count = Int(string[countRange]), count >= 0 {
                result.summary[String(string[keyRange])] = count
            }
            guard let match = regex?.firstMatch(in: string, range: whole) else { continue }
            if result.assertions.count >= 256 { result.incomplete = true; continue }
            let values = (1...5).compactMap { index in Range(match.range(at: index), in: string).map { String(string[$0]) } }
            guard values.count == 5, let pid = pid_t(values[0]), pid > 0 else { continue }
            let reading = SleepAssertionReading(pid: pid, processName: String(values[1].prefix(128)), assertionID: values[2], kind: values[4], duration: values[3])
            result.available = true
            if seen.insert(reading.id).inserted { result.assertions.append(reading) }
            // Assertion descriptive names are deliberately not parsed: apps can put
            // document names, media titles and local paths in those descriptions.
        }
        return result
    }

    static func meaning(_ kind: String) -> String {
        switch kind {
        case "PreventUserIdleSystemSleep": return "Prevents idle system sleep"
        case "PreventSystemSleep": return "Prevents system sleep"
        case "PreventUserIdleDisplaySleep", "InternalPreventDisplaySleep": return "Prevents idle display sleep"
        case "UserIsActive": return "User activity signal"
        case "BackgroundTask": return "Background task signal"
        case "NetworkClientActive": return "Network activity signal"
        default: return "Power-management assertion"
        }
    }
}

struct BrowserResourceGroup: Sendable, Identifiable {
    let browser: String
    let category: String
    let pids: [pid_t]
    let residentBytes: Int64?
    let readableCount: Int
    var id: String { "\(browser)-\(category)" }
}

struct BrowserResourcesSnapshot: Sendable {
    var at = Date()
    var groups: [BrowserResourceGroup] = []
    var incomplete = false
    var message = "Browser processes have not been refreshed."
}

enum BrowserResourceProbe {
    struct Category: Sendable, Equatable {
        let browser: String
        let role: String
    }

    static func classify(path: String) -> Category? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        let app = components.first(where: { $0.hasSuffix(".app") })
        let names: [String: String] = ["Google Chrome.app": "Google Chrome", "Google Chrome Canary.app": "Chrome Canary",
            "Chromium.app": "Chromium", "Brave Browser.app": "Brave", "Microsoft Edge.app": "Microsoft Edge",
            "Arc.app": "Arc", "Opera.app": "Opera", "Vivaldi.app": "Vivaldi", "Safari.app": "Safari", "Firefox.app": "Firefox"]
        let executable = components.last ?? ""
        guard let app, let browser = names[app] else {
            // WebKit services are shared by Safari and other apps; their path alone
            // does not identify the owning browser or a tab.
            if path.contains("/WebKit.framework/"), executable.hasPrefix("com.apple.WebKit.") {
                return Category(browser: "WebKit · owner unavailable", role: "Shared web helper")
            }
            return nil
        }
        let lower = executable.lowercased()
        let role: String
        if lower.contains("(renderer)") { role = "Renderer helper" }
        else if lower.contains("(gpu)") { role = "Graphics helper" }
        else if lower.contains("(plugin)") { role = "Plugin helper" }
        else if lower.contains("helper") || lower.contains("plugin-container") { role = "Helper · role unavailable" }
        else { role = "Browser process" }
        return Category(browser: browser, role: role)
    }

    static func refresh() -> BrowserResourcesSnapshot {
        var result = BrowserResourcesSnapshot()
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { result.message = "macOS process list unavailable."; return result }
        let count = min(8_192, Int(needed) / MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: count)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { result.message = "macOS process list unavailable."; return result }
        result.incomplete = Int(needed) / MemoryLayout<pid_t>.size > count
        struct Accumulator { var browser: String; var role: String; var pids: [pid_t] = []; var bytes: Int64 = 0; var readable = 0 }
        var groups: [String: Accumulator] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        for pid in pids.prefix(min(count, Int(bytes) / MemoryLayout<pid_t>.size)) where pid > 1 {
            if ProcessInfo.processInfo.systemUptime > deadline { result.incomplete = true; break }
            guard let identity = ProcessIdentity.capture(pid: pid), identity.uid == getuid(), let category = classify(path: identity.path) else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let readable = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size && info.pti_resident_size <= UInt64(Int64.max)
            guard ProcessIdentity.capture(pid: pid) == identity else { continue }
            let key = "\(category.browser)-\(category.role)"
            var item = groups[key] ?? Accumulator(browser: category.browser, role: category.role)
            item.pids.append(pid)
            if readable {
                let sum = item.bytes.addingReportingOverflow(Int64(info.pti_resident_size))
                if !sum.overflow { item.bytes = sum.partialValue; item.readable += 1 }
            }
            groups[key] = item
        }
        result.groups = groups.values.map {
            BrowserResourceGroup(browser: $0.browser, category: $0.role, pids: $0.pids.sorted(),
                                 residentBytes: $0.readable > 0 ? $0.bytes : nil, readableCount: $0.readable)
        }.sorted { $0.id < $1.id }
        result.message = result.incomplete ? "Partial process snapshot. Only accessible processes owned by you are included." : "Generic executable categories · processes owned by you."
        return result
    }
}
