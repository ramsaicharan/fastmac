import Foundation
import Darwin

/// Uses an injected temporary home. No scan of the user's models, staging queue,
/// app preferences or Trash occurs, and every fixture is removed on completion.
enum AIStorageSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ condition: Bool) {
            lines.append("\(condition ? "PASS" : "FAIL")  \(label)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fastmac-ai-check-\(UUID().uuidString)")
            .resolvingSymlinksInPath().path
        do { try fm.createDirectory(atPath: root, withIntermediateDirectories: true) }
        catch { return ["FAIL  create isolated AI storage fixtures: \(error.localizedDescription)"] }
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/.cache/mlx/blocked")
            try? fm.removeItem(atPath: root)
        }
        func directory(_ relative: String) throws {
            try fm.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
        }
        func file(_ relative: String, size: Int = 8192) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try Data(repeating: 0x37, count: size).write(to: URL(fileURLWithPath: path))
        }
        do {
            try file(".ollama/models/blobs/sha256-example", size: 16_384)
            try file(".cache/huggingface/hub/models--org--ready/blobs/weights.safetensors")
            try directory(".cache/huggingface/hub/models--org--ready/snapshots/a")
            try fm.createSymbolicLink(atPath: root + "/.cache/huggingface/hub/models--org--ready/snapshots/a/weights.safetensors",
                                      withDestinationPath: "../../blobs/weights.safetensors")
            try file(".cache/huggingface/hub/models--org--loading/blobs/weights.incomplete")
            try file(".cache/huggingface/hub/models--org--loading/config.json")
            try file(".lmstudio/models/author/ready/model.gguf", size: 12_288)
            try file(".lmstudio/models/author/loading/model.gguf")
            try file(".lmstudio/models/author/loading/model.gguf.part")
            try file(".cache/mlx/kernels/cache.dat")
            try file("outside/sentinel.bin", size: 65_536)
            try fm.createSymbolicLink(atPath: root + "/.cache/mlx/external",
                                      withDestinationPath: root + "/outside")
            let engine = AIStorageEngine(home: root)
            let report = engine.scan()
            check("targeted sweep returns every known source", report.sources.count == AIStorageSource.defaults.count)
            check("sweep completes without cancellation or limits", !report.cancelled && !report.reachedLimit)
            check("source identities remain distinct", Set(report.sources.map(\.id)).count == report.sources.count)
            let ollama = report.sources.first { $0.id == "ollama" }
            check("Ollama footprint is measured", ollama?.status == .complete && (ollama?.allocated ?? 0) > 0)
            check("Ollama shared blob store is never offered as an individual cleanup item", ollama?.items.isEmpty == true)
            let hf = report.sources.first { $0.id == "huggingface" }
            let ready = hf?.items.first { $0.name == "org/ready" }
            let loading = hf?.items.first { $0.name == "org/loading" }
            check("Hugging Face repository is identified as model data", ready?.kind == .models && ready?.eligible == true)
            check("Hugging Face snapshot symlink is skipped instead of double counted", hf?.skippedLinks == 1 && ready?.logical == 8192)
            check("in-progress Hugging Face download is never eligible", loading?.containsDownload == true && loading?.eligible == false)
            check("transient footprint is recorded separately", (hf?.transientBytes ?? 0) > 0)
            let lm = report.sources.first { $0.id == "lmstudio" }
            check("LM Studio stages repository children rather than publisher root", lm?.eligibleItems.count == 1
                  && lm?.eligibleItems.first?.path == root + "/.lmstudio/models/author/ready")
            check("LM Studio partial downloads are withheld", lm?.items.first { $0.name == "loading" }?.eligible == false)
            check("missing source is explicitly reported", report.sources.first { $0.id == "lmstudio-legacy" }?.status == .missing)
            let mlx = report.sources.first { $0.id == "mlx" }
            check("MLX runtime cache stays distinct from model data", mlx?.items.first?.kind == .runtimeCache)
            check("symlink to outside source is never traversed", mlx?.logical == 8192 && mlx?.skippedLinks == 1)
            check("eligible models stay below their source root", report.sources.filter { $0.source.layout != .desktopCache }.allSatisfy { footprint in
                footprint.eligibleItems.allSatisfy { $0.path.hasPrefix(footprint.path + "/") && $0.path != footprint.path }
            })
            try file("Library/Application Support/Cursor/Code Cache/js/compiled")
            try file("Library/Application Support/Cursor/User/project.json", size: 24_576)
            let cursor = engine.scan().sources.first { $0.id == "cursor-code-cache" }
            check("desktop cache is a specific review unit", cursor?.eligibleItems.first?.path == root + "/Library/Application Support/Cursor/Code Cache")
            check("desktop cache inspection excludes projects and user data", cursor?.logical == 8192)
            for i in 1...25 { try file(".codex/sessions/2026/10/11/session-\(i).jsonl", size: i * 8192) }
            try file(".codex/archived_sessions/archived.jsonl", size: 16_384)
            try fm.createSymbolicLink(atPath: root + "/.codex/sessions/external", withDestinationPath: root + "/outside")
            let histories = engine.scan(sources: AIStorageSource.historySources)
            let sessions = histories.sources.first { $0.id == "codex-sessions" }
            check("history metadata scan counts every file beyond display limit", sessions?.files == 25 && sessions?.status == .complete)
            check("history scan retains largest 20 files deterministically", sessions?.items.count == 20 && sessions?.items.first?.name == "session-25.jsonl")
            check("history scan measures bytes without parsing invalid JSON fixture contents", sessions?.logical == Int64((1...25).reduce(0, +) * 8192))
            check("history is never eligible for cache cleanup", histories.sources.allSatisfy { $0.eligibleItems.isEmpty } && sessions?.items.allSatisfy { $0.kind == .conversationHistory && $0.modifiedAt != nil } == true)
            check("history scan excludes external symlink targets", sessions?.skippedLinks == 1)
            check("archived history is measured separately", histories.sources.first { $0.id == "codex-archived" }?.logical == 16_384)
            let lockPath = root + "/.cache/huggingface/hub/.locks/models--org--ready/download.lock"
            try file(".cache/huggingface/hub/.locks/models--org--ready/download.lock", size: 0)
            let lockFD = Darwin.open(lockPath, O_RDONLY)
            if lockFD >= 0 {
                let locked = flock(lockFD, LOCK_EX | LOCK_NB) == 0
                let lockedHF = engine.scan().sources.first { $0.id == "huggingface" }
                check("active Hugging Face lock withholds otherwise complete model", locked && lockedHF?.items.first { $0.name == "org/ready" }?.eligible == false)
                flock(lockFD, LOCK_UN); Darwin.close(lockFD)
                let unlockedHF = engine.scan().sources.first { $0.id == "huggingface" }
                check("stale unlocked Hugging Face lock does not block a complete model", unlockedHF?.items.first { $0.name == "org/ready" }?.eligible == true)
            } else { check("create download lock fixture", false) }

            let token = AIStorageCancellation(); token.cancel()
            let cancelled = engine.scan(cancellation: token)
            check("pre-cancelled scan remains cancelled", cancelled.cancelled)
            check("cancelled scan cannot yield cleanup items", cancelled.sources.allSatisfy { $0.eligibleItems.isEmpty })
            var bounded = AIStorageEngine.Limits(); bounded.entries = 3
            let limited = AIStorageEngine(home: root, limits: bounded).scan()
            check("entry limit reports partial data", limited.reachedLimit && limited.hasPartialResults)
            check("partial sources cannot yield cleanup items", limited.sources.filter { $0.status != .complete }.allSatisfy { $0.eligibleItems.isEmpty })
            var timed = AIStorageEngine.Limits(); timed.seconds = 0
            check("time budget stops before reading files", AIStorageEngine(home: root, limits: timed).scan().allocated == 0)
            var shallow = AIStorageEngine.Limits(); shallow.depth = 1
            let shallowReport = AIStorageEngine(home: root, limits: shallow).scan()
            check("depth limit is surfaced as partial data", shallowReport.reachedLimit && shallowReport.hasPartialResults)

            // Ancestor symlinks must be rejected, not just the final model directory.
            let linkedHome = root + "/linked-home"
            try fm.createDirectory(atPath: linkedHome, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkedHome + "/.cache", withDestinationPath: root + "/.cache")
            let linkedReport = AIStorageEngine(home: linkedHome).scan()
            check("linked parent directory is explicitly skipped", linkedReport.sources.first { $0.id == "huggingface" }?.status == .linked)
            check("linked root never yields cleanup items", linkedReport.sources.allSatisfy { $0.eligibleItems.isEmpty })

            // Hard-linked model files cannot promise their bytes will be reclaimed.
            try directory(".cache/mlx/shared")
            try fm.linkItem(atPath: root + "/outside/sentinel.bin", toPath: root + "/.cache/mlx/shared/model.bin")
            let shared = engine.scan().sources.first { $0.id == "mlx" }?.items.first { $0.name == "shared" }
            check("hard-linked model data is withheld from cleanup suggestions", shared?.kind == .models && shared?.eligible == false)

            // Access denial is visible and disables staging rather than looking empty.
            try file(".cache/mlx/blocked/model.gguf")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/.cache/mlx/blocked")
            let denied = engine.scan().sources.first { $0.id == "mlx" }
            if getuid() == 0 {
                lines.append("PASS  permission-denied fixture requires an unprivileged process; skipped for root")
            } else {
                check("permission denial becomes partial measurement", denied?.status == .partial && denied?.issues.isEmpty == false)
                check("access-denied source offers no cleanup items", denied?.eligibleItems.isEmpty == true)
            }
            check("fixture scan never mutates regular files", fm.contents(atPath: root + "/outside/sentinel.bin")?.count == 65_536)
        } catch {
            lines.append("FAIL  build or inspect AI storage fixtures: \(error.localizedDescription)")
        }
        return lines
    }
}
