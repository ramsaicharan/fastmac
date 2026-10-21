import Foundation
import Darwin

enum InsightsSelfCheck {
    static func sample(at: Date, session: String = "fixture", cpu: Double? = 20, rss: Int64? = 1_073_741_824) -> ActivitySnapshot {
        .init(sampledAt: at, sessionID: session, cpuPercent: cpu, memoryUsed: 12 * 1_073_741_824,
              memoryTotal: 16 * 1_073_741_824, swapUsed: 4 * 1_073_741_824,
              memoryPressure: "normal", diskFree: 100 * 1_073_741_824, diskTotal: 500 * 1_073_741_824,
              diskReadRate: nil, diskWriteRate: nil, networkDownloadRate: nil, networkUploadRate: nil,
              networkScope: "fixture", batteryPercent: nil, gpuPercent: nil, thermalState: "Nominal",
              readableProcesses: 5, listedProcesses: 10,
              apps: [.init(id: "fixture.app", name: "Fixture App", cpuPercent: 25, rss: rss, processCount: 2)])
    }
    static func health(at: Date) -> HealthSample {
        .init(memory: MemorySample(total: 16 * 1_073_741_824, app: 14 * 1_073_741_824, swapUsed: 8 * 1_073_741_824),
              memoryPressure: .normal, diskFree: 100 * 1_073_741_824, diskTotal: 500 * 1_073_741_824,
              thermalState: .nominal, sampledAt: at)
    }
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ value: Bool) { lines.append("\(value ? "PASS" : "FAIL")  " + title) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = health(at: now)
        let current = sample(at: now)
        check("normal OS pressure stays comfortable despite high occupancy and swap", good.memoryStatus == .comfortable)
        check("healthy measurements do not invent a problem", InsightEngine.evaluate(health: good, samples: [current], now: now).findings.isEmpty)
        let stale = InsightEngine.evaluate(health: health(at: now.addingTimeInterval(-100)), samples: [sample(at: now.addingTimeInterval(-100))], now: now)
        check("stale health and activity yield an explicit coverage finding", stale.findings.map(\.id) == ["coverage"])
        var stressed = good; stressed.memoryPressure = .warning; stressed.diskFree = 1_073_741_824
        let ranked = InsightEngine.evaluate(health: stressed, samples: [current], now: now)
        check("critical storage precedes attention-level memory", ranked.findings.first?.id == "storage-headroom")
        check("memory attribution says measured consumers rather than proven cause", ranked.findings.first(where: { $0.id == "memory-pressure" })?.interpretation.contains("not proven causes") == true)
        var unknown = good; unknown.memoryPressure = .unknown
        check("unavailable OS pressure is not healthy", InsightEngine.evaluate(health: unknown, samples: [current], now: now).findings.contains { $0.id == "coverage" })
        let high = [120.0, 60, 0].map { sample(at: now.addingTimeInterval(-$0), cpu: 85) }
        check("sustained CPU requires continuous duration", InsightEngine.evaluate(health: good, samples: high, now: now).findings.contains { $0.id == "sustained-cpu" })
        check("one high CPU sample does not diagnose sustained activity", !InsightEngine.evaluate(health: good, samples: [high.last!], now: now).findings.contains { $0.id == "sustained-cpu" })
        let gap = [sample(at: now.addingTimeInterval(-200), cpu: 90), sample(at: now, cpu: 90)]
        check("sampling gaps break a sustained-CPU claim", !InsightEngine.evaluate(health: good, samples: gap, now: now).findings.contains { $0.id == "sustained-cpu" })
        var reset = high; reset[2].sessionID = "new-session"
        check("monitor restarts break a sustained-CPU claim", !InsightEngine.evaluate(health: good, samples: reset, now: now).findings.contains { $0.id == "sustained-cpu" })
        let invalid = [120.0, 60, 0].map { sample(at: now.addingTimeInterval(-$0), cpu: .infinity) }
        check("invalid CPU percentages cannot generate a high-demand finding", !InsightEngine.evaluate(health: good, samples: invalid, now: now).findings.contains { $0.id == "sustained-cpu" })
        let growth = [sample(at: now.addingTimeInterval(-120)), sample(at: now.addingTimeInterval(-60)), sample(at: now, rss: 3 * 1_073_741_824)]
        check("matched app growth becomes an informational change", InsightEngine.evaluate(health: good, samples: growth, now: now).findings.contains { $0.id == "growth-fixture.app" && $0.severity == .comfortable })
        var missing = growth; missing[0].apps = []
        check("missing historical apps are never treated as zero RSS", !InsightEngine.evaluate(health: good, samples: missing, now: now).findings.contains { $0.id.hasPrefix("growth-") })
        check("duplicate timestamps do not manufacture duration", InsightEngine.evaluate(health: good, samples: [current, current, current], now: now).sampleCount == 1)
        check("future readings are excluded", InsightEngine.evaluate(health: good, samples: [sample(at: now.addingTimeInterval(300))], now: now).sampleCount == 0)

        check("unknown processes stay unknown", ProcessExplanation.explain(path: "/tmp/WindowServer", name: "WindowServer").role.contains("does not have"))
        check("system explanation is scoped to a system executable path", ProcessExplanation.explain(path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", name: "WindowServer").role.contains("Composes windows"))
        check("helper explanation identifies bundle association", ProcessExplanation.explain(path: "/Applications/Fixture.app/Contents/Frameworks/Helper", name: "Helper").role.contains("helper inside"))
        check("a runtime name is not treated as a verified project", ProcessExplanation.explain(path: "/usr/local/bin/node", name: "node").role.contains("does not establish"))
        let entries = [PaletteEntry(id: "a", title: "Open Insights", detail: "diagnose slow Mac", icon: "", action: .navigate(.insights)),
                       PaletteEntry(id: "b", title: "Stop Node server", detail: "Port 3000 /fixture/project", icon: "", action: .navigate(.projects))]
        check("palette search supports case-insensitive multiple terms", PaletteSearch.filter(entries, query: "NODE 3000").map(\.id) == ["b"])
        check("palette search exposes diagnosis synonyms", PaletteSearch.filter(entries, query: "slow").map(\.id) == ["a"])
        check("palette no-match state stays empty", PaletteSearch.filter(entries, query: "missing-query").isEmpty)

        let ollama = Data(#"{"models":[{"name":"fixture:small","digest":"sha-test","size":4096,"size_vram":2048,"details":{"quantization_level":"Q4"}}]}"#.utf8)
        let lm = Data(#"{"models":[{"key":"fixture","display_name":"Fixture","size_bytes":999999,"loaded_instances":[{"id":"instance-1","config":{"context_length":4096}}]},{"key":"disk-only","size_bytes":100,"loaded_instances":[]}]}"#.utf8)
        let o = try? LocalModelDecoder.decode(ollama, runtime: .ollama)
        let l = try? LocalModelDecoder.decode(lm, runtime: .lmStudio)
        check("Ollama uses runtime-reported RAM and GPU figures", o?.first?.memoryBytes == 4096 && o?.first?.gpuBytes == 2048)
        check("LM Studio disk-only models are not shown as loaded", l?.count == 1 && l?.first?.instance == "instance-1")
        check("LM Studio file size is never reported as active RAM", l?.first?.memoryBytes == nil)
        check("missing metric stays unavailable", LocalModelDecoder.bytes(nil) == nil)
        check("negative memory is rejected", LocalModelDecoder.bytes(-1) == nil)
        check("boolean memory is rejected", LocalModelDecoder.bytes(true) == nil)
        check("overflow memory is rejected", LocalModelDecoder.bytes(Double(Int64.max)) == nil)
        check("fractional bytes are rejected", LocalModelDecoder.bytes(1.5) == nil)
        check("bad runtime response does not mean zero loaded models", (try? LocalModelDecoder.decode(Data("{}".utf8), runtime: .ollama)) == nil)
        check("explicit empty response is a valid unloaded state", (try? LocalModelDecoder.decode(Data(#"{"models":[]}"#.utf8), runtime: .ollama))?.isEmpty == true)
        check("oversized response is rejected", (try? LocalModelDecoder.decode(Data(repeating: 32, count: 1_048_577), runtime: .ollama)) == nil)
        if let model = o?.first, let body = try? LocalModelDecoder.unloadBody(model), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            check("Ollama unload never sends a prompt or requests deletion", json["prompt"] == nil && json["keep_alive"] as? Int == 0 && json["model"] as? String == model.instance)
        } else { check("Ollama unload fixture decodes", false) }
        if let model = l?.first, let body = try? LocalModelDecoder.unloadBody(model), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            check("LM Studio unload targets the reviewed instance", json["instance_id"] as? String == "instance-1" && json.count == 1)
        } else { check("LM Studio unload fixture decodes", false) }

        func node(_ pid: pid_t, parent: pid_t, path: String = "/fixture/node", started: UInt64 = 100) -> AgentObservedProcess {
            .init(identity: .init(pid: pid, uid: getuid(), startedSeconds: started, startedMicroseconds: 0, path: path), parentPID: parent, directory: nil)
        }
        func observation(_ nodes: [AgentObservedProcess], listed: Set<pid_t>? = nil, complete: Bool = true) -> AgentObservation {
            .init(at: now, processes: nodes, listedPIDs: listed ?? Set(nodes.map { $0.identity.pid }), completeEnumeration: complete, limited: !complete, milliseconds: 1)
        }
        let root = node(100, parent: 1, path: "/fixture/claude", started: 50)
        let child = node(101, parent: 100)
        let grandchild = node(102, parent: 101, started: 110)
        var tracker = AgentSessionTracker()
        tracker.ingest(observation([root, child, grandchild, node(999, parent: 1)]))
        check("agent tracking associates only observed ancestor chains", tracker.sessions.first?.children.count == 2)
        check("children of a live agent are not leftovers", tracker.sessions.first?.leftovers.isEmpty == true)
        tracker.ingest(observation([child, grandchild], listed: [100, 101, 102]))
        check("unreadable but listed agent is not marked ended", tracker.sessions.first?.endedAt == nil)
        tracker.ingest(observation([child, grandchild], complete: false))
        check("partial enumeration cannot establish agent exit", tracker.sessions.first?.endedAt == nil)
        tracker.ingest(observation([child, grandchild]))
        check("verified surviving descendants become leftovers after agent exit", tracker.sessions.first?.leftovers.count == 2)
        tracker.ingest(observation([node(101, parent: 1, started: 500)]))
        check("PID reuse removes the old descendant rather than retargeting it", tracker.sessions.first?.leftovers.isEmpty == true)
        var reversed = AgentSessionTracker(); reversed.ingest(observation([root, node(101, parent: 100, started: 10)]))
        check("a parent newer than its child is not valid lineage", reversed.sessions.first?.children.isEmpty == true)
        var orphan = AgentSessionTracker(); orphan.ingest(observation([child]))
        check("already orphaned servers are never assigned an invented agent", orphan.sessions.isEmpty)
        var bounded = AgentSessionTracker()
        bounded.ingest(observation((1...100).map { node(pid_t($0 + 1000), parent: 1, path: "/fixture/codex") }))
        check("agent sessions stay bounded", bounded.sessions.count == 64)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fastmac-startup-baseline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fact = StartupFact(id: "/fixture/a.plist", label: "a", owner: "Fixture", domain: "User", program: "/fixture/a", fingerprint: "original")
        let changed = StartupFact(id: fact.id, label: fact.label, owner: fact.owner, domain: fact.domain, program: fact.program, fingerprint: "changed")
        var baseline = StartupBaseline(accepted: [fact.id: fact])
        check("unchanged startup configuration produces no alert", StartupBaseline.changes(current: [fact], baseline: baseline).isEmpty)
        check("changed startup configuration is distinguished from a new entry", StartupBaseline.changes(current: [changed], baseline: baseline).first?.prior != nil)
        check("missing startup entries do not claim removal", StartupBaseline.changes(current: [], baseline: baseline).isEmpty)
        baseline.accepted[fact.id] = changed
        check("acknowledgement applies only to the reviewed configuration", StartupBaseline.changes(current: [changed], baseline: baseline).isEmpty && !StartupBaseline.changes(current: [fact], baseline: baseline).isEmpty)
        do {
            let repo = StartupBaselineRepository(url: directory.appendingPathComponent("baseline.json"))
            check("first run has no accepted baseline", try repo.read() == nil)
            try repo.write(baseline)
            check("startup acknowledgements survive reload", try repo.read()?.accepted[fact.id] == changed)
            try Data("broken".utf8).write(to: repo.url)
            check("corrupt baseline is reported instead of silently reset", (try? repo.read()) == nil)
        } catch { check("startup baseline fixture persistence", false) }
        return lines
    }

    static func asyncChecks() async -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ value: Bool) { lines.append("\(value ? "PASS" : "FAIL")  " + title) }
        let model = LoadedLocalModel(runtime: .ollama, name: "fixture", instance: "fixture", fingerprint: "digest-a", memoryBytes: nil, gpuBytes: nil, quantization: nil)
        final class Calls { var paths: [String] = []; var reads = 0 }
        let calls = Calls()
        let client = LocalModelClient(transport: { _, path, _, body in
            calls.paths.append(path)
            if body != nil { return Data(#"{"done":true}"#.utf8) }
            calls.reads += 1
            return Data((calls.reads == 1 ? #"{"models":[{"name":"fixture","digest":"digest-a"}]}"# : #"{"models":[]}"#).utf8)
        })
        do {
            let absent = try await client.unload(model, token: "")
            check("unload revalidates, posts, and confirms absence in that order", absent && calls.paths == ["/api/ps", "/api/generate", "/api/ps"])
        } catch { check("unload workflow succeeds against fixture transport", false) }
        let changedCalls = Calls()
        let changed = LocalModelClient(transport: { _, path, _, _ in
            changedCalls.paths.append(path)
            return Data(#"{"models":[{"name":"fixture","digest":"digest-b"}]}"#.utf8)
        })
        do { _ = try await changed.unload(model, token: ""); check("changed model blocks unload", false) }
        catch { check("changed model blocks unload without a POST", changedCalls.paths == ["/api/ps"]) }
        let stillLoaded = LocalModelClient(transport: { _, _, _, _ in Data(#"{"models":[{"name":"fixture","digest":"digest-a"}]}"#.utf8) })
        do { check("accepted unload is not equated to disappearance", try await !stillLoaded.unload(model, token: "")) }
        catch { check("still-loaded fixture is readable", false) }
        let neverCalled = Calls()
        let invalid = LocalModelClient(transport: { _, path, _, _ in neverCalled.paths.append(path); return Data() })
        do { _ = try await invalid.models(.lmStudio, token: "x\r\ny"); check("invalid token refused", false) }
        catch { check("header injection rejected before transport", neverCalled.paths.isEmpty) }
        do { _ = try await invalid.request(runtime: .ollama, path: "/api/delete", token: ""); check("arbitrary endpoints refused", false) }
        catch { check("unsupported endpoint rejected before transport", neverCalled.paths.isEmpty) }
        return lines
    }
}
