import Foundation
import Combine
import Darwin

/// Targeted, read-only inspection. None of these directories are "junk": model files
/// remain useful until their owner decides otherwise, even when a tool calls them cache.
enum AIStorageKind: String, Sendable {
    case models, runtimeCache, conversationHistory, other
    var title: String {
        switch self {
        case .models: return "Downloaded models"
        case .runtimeCache: return "Runtime cache"
        case .conversationHistory: return "Conversation history · review in app"
        case .other: return "Other data"
        }
    }
}

struct AIStorageSource: Identifiable, Hashable, Sendable {
    enum Layout: String, Sendable { case ollama, huggingFace, lmStudio, mlx, desktopCache, sessionHistory }
    let id: String
    let name: String
    let relativePath: String
    let kind: AIStorageKind
    let layout: Layout
    let explanation: String

    static let modelSources: [AIStorageSource] = [
        .init(id: "ollama", name: "Ollama", relativePath: ".ollama/models", kind: .models,
              layout: .ollama,
              explanation: "Shared model blobs and manifests. Remove models through Ollama so shared files stay consistent."),
        .init(id: "huggingface", name: "Hugging Face", relativePath: ".cache/huggingface/hub",
              kind: .models, layout: .huggingFace,
              explanation: "Downloaded repositories, including model weights. A cache path does not mean the models are disposable."),
        .init(id: "lmstudio", name: "LM Studio", relativePath: ".lmstudio/models", kind: .models,
              layout: .lmStudio,
              explanation: "Local model repositories. Review the model you no longer use before adding it to the cleanup queue."),
        .init(id: "lmstudio-legacy", name: "LM Studio (legacy)", relativePath: ".cache/lm-studio/models",
              kind: .models, layout: .lmStudio,
              explanation: "Models stored by older installations. Only existing repositories appear here."),
        .init(id: "mlx", name: "MLX", relativePath: ".cache/mlx", kind: .runtimeCache,
              layout: .mlx,
              explanation: "MLX cache entries may include model weights. Review each item; removing weights requires a re-download, and rebuilding runtime caches may slow the next launch.")
    ]

    // These exact cache locations were verified against installed app bundle IDs and
    // their on-disk layouts. Application Support itself is never a cleanup unit: it
    // contains conversations, projects, browser profiles, sessions and other real data.
    static let desktopCacheSources: [AIStorageSource] = {
        let locations: [(String, String, String)] = [
            ("chatgpt-http", "ChatGPT · HTTP cache", "Library/Caches/com.openai.chat/fsCachedData"),
            ("codex-http", "Codex · HTTP cache", "Library/Caches/com.openai.codex/fsCachedData"),
            ("claude-http", "Claude · HTTP cache", "Library/Caches/com.anthropic.claudefordesktop/fsCachedData")
        ] + ["Claude", "Cursor", "Codex"].flatMap { app in
            ["Cache", "Code Cache", "GPUCache"].map { folder in
                ("\(app.lowercased())-\(folder.lowercased().replacingOccurrences(of: " ", with: "-"))",
                 "\(app) · \(folder == "GPUCache" ? "GPU cache" : folder.lowercased())",
                 "Library/Application Support/\(app)/\(folder)")
            }
        }
        return locations.map { id, name, path in
            AIStorageSource(id: id, name: name, relativePath: path, kind: .runtimeCache,
                layout: .desktopCache,
                explanation: "A specific desktop app cache. Quit the app before cleanup; downloaded resources or compiled code may need to be rebuilt. Conversations, projects and session storage are not scanned.")
        }
    }()
    static let historySources: [AIStorageSource] = [
        .init(id: "codex-sessions", name: "Codex · conversation history", relativePath: ".codex/sessions",
              kind: .conversationHistory, layout: .sessionHistory,
              explanation: "Saved conversations, tool results and context snapshots can include repeated embedded screenshots and images. These files support reopening and resuming chats. Counts include log files, not necessarily distinct chats or running sessions."),
        .init(id: "codex-archived", name: "Codex · archived history", relativePath: ".codex/archived_sessions",
              kind: .conversationHistory, layout: .sessionHistory,
              explanation: "Archiving retains conversations on disk. Review chats in Codex and back up needed history before deleting them there."),
        .init(id: "claude-history", name: "Claude · coding history", relativePath: ".claude/projects",
              kind: .conversationHistory, layout: .sessionHistory,
              explanation: "Local Claude coding-session data. Review sessions in Claude before removing any history. This location does not represent all Claude desktop storage.")
    ]
    static let defaults = historySources + modelSources + desktopCacheSources
}

enum AIStorageStatus: String, Sendable {
    case complete, missing, unreadable, partial, linked, cancelled
    var title: String {
        switch self {
        case .complete: return "Measured"
        case .missing: return "Not found"
        case .unreadable: return "Access needed"
        case .partial: return "Partial measurement"
        case .linked: return "Linked location skipped"
        case .cancelled: return "Cancelled"
        }
    }
}

struct AIStorageItem: Identifiable, Sendable {
    let sourceID: String
    let path: String
    let name: String
    let kind: AIStorageKind
    let allocated: Int64
    let logical: Int64
    let device: UInt64
    let inode: UInt64
    let containsDownload: Bool
    let complete: Bool
    let eligible: Bool
    let explanation: String
    var modifiedAt: Date? = nil
    var id: String { path }
}

struct AIStorageFootprint: Identifiable, Sendable {
    let source: AIStorageSource
    let path: String
    let status: AIStorageStatus
    let allocated: Int64
    let logical: Int64
    let transientBytes: Int64
    let files: Int
    let skippedLinks: Int
    let issues: [String]
    let items: [AIStorageItem]
    var id: String { source.id }
    var eligibleItems: [AIStorageItem] { status == .complete ? items.filter(\.eligible) : [] }
}

struct AIStorageReport: Sendable {
    let sources: [AIStorageFootprint]
    let scannedAt: Date
    let elapsed: Double
    let cancelled: Bool
    let reachedLimit: Bool
    var allocated: Int64 { sources.reduce(0) { $0 + $1.allocated } }
    var hasPartialResults: Bool { sources.contains { [.partial, .unreadable, .linked, .cancelled].contains($0.status) } }
}

final class AIStorageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// All traversal is relative to held directory descriptors, with O_NOFOLLOW on each
/// directory open. A directory replaced with a symlink between stat and open cannot
/// send the walk outside the requested location. Entry, time, depth and result limits
/// keep a scan useful without turning the menu-bar companion into an indexer.
struct AIStorageEngine: Sendable {
    struct Limits: Sendable {
        var entries = 150_000
        var seconds: Double = 30
        var depth = 32
        var items = 1_000
    }
    let home: String
    let limits: Limits
    init(home: String = NSHomeDirectory(), limits: Limits = Limits()) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        self.limits = limits
    }

    func scan(sources: [AIStorageSource] = AIStorageSource.defaults,
              cancellation: AIStorageCancellation = AIStorageCancellation()) -> AIStorageReport {
        let start = Date()
        let context = WalkContext(limits: limits, cancellation: cancellation, start: start)
        let homeFD = Darwin.open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if homeFD >= 0 { Darwin.close(homeFD) } }
        var footprints: [AIStorageFootprint] = []
        for source in sources {
            let path = home + "/" + source.relativePath
            if !context.canContinue {
                footprints.append(empty(source, path: path,
                                        status: cancellation.isCancelled ? .cancelled : .partial,
                                        issue: cancellation.isCancelled ? "Scan cancelled before this location was measured."
                                            : "Scan budget reached before this location was measured."))
                continue
            }
            guard homeFD >= 0 else {
                footprints.append(empty(source, path: path, status: .unreadable,
                                        issue: "The home directory could not be opened without following a link."))
                continue
            }
            let opened = openDirectory(source.relativePath, relativeTo: homeFD)
            guard let fd = opened.fd else {
                footprints.append(empty(source, path: path, status: opened.status,
                                        issue: opened.status == .missing ? nil : "\(opened.detail): \(path)"))
                continue
            }
            context.beginSource()
            var items: [AIStorageItem] = []
            var rootIdentity = stat()
            let hasRootIdentity = fstat(fd, &rootIdentity) == 0
            let measured = walk(fd: fd, path: path, source: source, level: 0,
                                context: context, items: &items)
            Darwin.close(fd)
            if source.layout == .huggingFace {
                items = items.map { item in
                    guard context.busyRepositories.contains((item.path as NSString).lastPathComponent) else { return item }
                    return AIStorageItem(sourceID: item.sourceID, path: item.path, name: item.name,
                        kind: item.kind, allocated: item.allocated, logical: item.logical,
                        device: item.device, inode: item.inode, containsDownload: true,
                        complete: item.complete, eligible: false,
                        explanation: "An active repository download lock was found. Finish the download and scan again.")
                }
            }
            if source.layout == .desktopCache, hasRootIdentity,
               measured.allocated > 0 || measured.logical > 0 {
                items = [AIStorageItem(sourceID: source.id, path: path, name: source.name,
                    kind: .runtimeCache, allocated: measured.allocated, logical: measured.logical,
                    device: UInt64(rootIdentity.st_dev), inode: UInt64(rootIdentity.st_ino),
                    containsDownload: measured.containsDownload, complete: measured.complete,
                    eligible: measured.complete && !measured.containsDownload && !measured.hasHardlinks,
                    explanation: measured.containsDownload ? "Temporary or download entries were found. Quit the app and scan again."
                        : measured.hasHardlinks ? "Shared hard-linked cache files were found. Manage these in the app."
                        : "The app will rebuild this specific cache. Its next launch may be slower.")]
            }
            let status: AIStorageStatus = cancellation.isCancelled ? .cancelled
                : (measured.complete && context.issues.isEmpty ? .complete : .partial)
            footprints.append(AIStorageFootprint(source: source, path: path, status: status,
                allocated: measured.allocated, logical: measured.logical,
                transientBytes: measured.transientBytes, files: measured.files,
                skippedLinks: measured.skippedLinks, issues: context.issues,
                items: items.sorted { $0.allocated > $1.allocated }))
        }
        return AIStorageReport(sources: footprints, scannedAt: start,
                               elapsed: Date().timeIntervalSince(start),
                               cancelled: cancellation.isCancelled, reachedLimit: context.reachedLimit)
    }

    private func empty(_ source: AIStorageSource, path: String, status: AIStorageStatus,
                       issue: String?) -> AIStorageFootprint {
        AIStorageFootprint(source: source, path: path, status: status, allocated: 0,
            logical: 0, transientBytes: 0, files: 0, skippedLinks: 0,
            issues: issue.map { [$0] } ?? [], items: [])
    }

    private func openDirectory(_ relative: String, relativeTo base: Int32)
        -> (fd: Int32?, status: AIStorageStatus, detail: String) {
        let components = relative.split(separator: "/").map(String.init)
        guard !relative.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return (nil, .unreadable, "Invalid relative location")
        }
        var current = dup(base)
        guard current >= 0 else { return (nil, .unreadable, "Unable to open location") }
        for component in components {
            var st = stat()
            guard fstatat(current, component, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                Darwin.close(current)
                return (nil, code == ENOENT ? .missing : .unreadable, "Unable to inspect location")
            }
            if st.st_mode & S_IFMT == S_IFLNK {
                Darwin.close(current)
                return (nil, .linked, "Symbolic links are not traversed")
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else {
                return (nil, errno == ENOENT ? .missing : .unreadable, "Unable to read location")
            }
            current = next
        }
        return (current, .complete, "")
    }

    private struct Identity: Hashable { let device: UInt64; let inode: UInt64 }
    private struct Measurement {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var transientBytes: Int64 = 0
        var files = 0
        var skippedLinks = 0
        var containsDownload = false
        var complete = true
        var hasModelFile = false
        var hasHardlinks = false
        mutating func merge(_ other: Measurement) {
            allocated += other.allocated; logical += other.logical
            transientBytes += other.transientBytes; files += other.files
            skippedLinks += other.skippedLinks
            containsDownload = containsDownload || other.containsDownload
            complete = complete && other.complete
            hasModelFile = hasModelFile || other.hasModelFile
            hasHardlinks = hasHardlinks || other.hasHardlinks
        }
    }

    private final class WalkContext {
        let limits: Limits
        let cancellation: AIStorageCancellation
        let start: Date
        var entries = 0
        var reachedLimit = false
        var issues: [String] = []
        var identities: Set<Identity> = []
        var busyRepositories: Set<String> = []
        init(limits: Limits, cancellation: AIStorageCancellation, start: Date) {
            self.limits = limits; self.cancellation = cancellation; self.start = start
        }
        func beginSource() { issues = []; identities = []; busyRepositories = [] }
        var canContinue: Bool {
            guard !cancellation.isCancelled else { return false }
            guard entries < limits.entries, Date().timeIntervalSince(start) < limits.seconds else {
                reachedLimit = true; return false
            }
            return true
        }
        func issue(_ text: String) { if issues.count < 12 { issues.append(text) } }
    }

    private func walk(fd: Int32, path: String, source: AIStorageSource, level: Int,
                      context: WalkContext, items: inout [AIStorageItem]) -> Measurement {
        var measured = Measurement()
        guard context.canContinue else { measured.complete = false; return measured }
        guard level <= limits.depth else {
            measured.complete = false; context.reachedLimit = true
            context.issue("Depth limit reached: \(path)"); return measured
        }
        var before = stat()
        guard fstat(fd, &before) == 0 else { measured.complete = false; return measured }
        // fdopendir owns its descriptor, so pass a duplicate and keep the caller's fd.
        let copy = dup(fd)
        guard copy >= 0 else { measured.complete = false; return measured }
        guard let dir = fdopendir(copy) else {
            Darwin.close(copy); measured.complete = false
            context.issue("Unable to list: \(path)"); return measured
        }
        defer { closedir(dir) }
        while true {
            guard context.canContinue else { measured.complete = false; break }
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { measured.complete = false; context.issue("Directory listing failed: \(path)") }
                break
            }
            var nameBuffer = entry.pointee.d_name
            let name = withUnsafePointer(to: &nameBuffer) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            context.entries += 1
            let childPath = path + "/" + name
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                measured.complete = false; context.issue("Unable to inspect: \(childPath)"); continue
            }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { measured.skippedLinks += 1; continue }
            var child = Measurement()
            let transient = Self.isDownloadMarker(name)
            if mode == S_IFDIR {
                let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    measured.complete = false; context.issue("Unable to read: \(childPath)"); continue
                }
                child = walk(fd: childFD, path: childPath, source: source,
                             level: level + 1, context: context, items: &items)
                Darwin.close(childFD)
            } else if mode == S_IFREG {
                child.files = 1
                let identity = Identity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
                if context.identities.insert(identity).inserted {
                    child.allocated = max(0, Int64(st.st_blocks)) * 512
                    child.logical = max(0, Int64(st.st_size))
                }
                child.hasModelFile = Self.isModelFile(name)
                child.hasHardlinks = st.st_nlink > 1
                if source.layout == .sessionHistory, name.hasSuffix(".jsonl"), child.logical > 0 {
                    // Keep only the largest 20 records while measuring the entire tree.
                    // Metadata only: even a multi-GB transcript is never opened here.
                    items.append(AIStorageItem(sourceID: source.id, path: childPath, name: name,
                        kind: .conversationHistory, allocated: child.allocated, logical: child.logical,
                        device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                        containsDownload: false, complete: true, eligible: false,
                        explanation: "Saved conversation data. Manage it in the owning app.",
                        modifiedAt: Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))))
                    items.sort { $0.allocated == $1.allocated ? $0.path < $1.path : $0.allocated > $1.allocated }
                    if items.count > 20 { items.removeLast() }
                }
                if source.layout == .huggingFace, name.hasSuffix(".lock"),
                   let repository = repositoryForLock(childPath) {
                    let lockFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    if lockFD < 0 {
                        child.complete = false; context.issue("Unable to check repository lock: \(childPath)")
                    } else {
                        // Existing Python FileLock locks use flock. A nonblocking probe
                        // detects an active owner without creating or changing the file.
                        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                            flock(lockFD, LOCK_UN)
                        } else if errno == EWOULDBLOCK || errno == EAGAIN {
                            context.busyRepositories.insert(repository)
                        } else {
                            child.complete = false; context.issue("Unable to verify repository lock: \(childPath)")
                        }
                        Darwin.close(lockFD)
                    }
                }
            } else {
                // Devices, sockets and named pipes have no place in a cleanup proposal.
                continue
            }
            // Download marker trees contribute to footprint, never to an eligible item.
            if transient {
                child.containsDownload = true
                child.transientBytes = child.allocated
            }
            measured.merge(child)
            if isCandidate(source: source, level: level, name: name, isDirectory: mode == S_IFDIR),
               child.allocated > 0 || child.logical > 0 {
                if items.count >= limits.items {
                    measured.complete = false; context.reachedLimit = true
                    context.issue("Review item limit reached; totals may include additional entries.")
                } else {
                    let kind: AIStorageKind = source.layout == .mlx && child.hasModelFile ? .models : source.kind
                    let eligible = child.complete && !child.containsDownload && !child.hasHardlinks && !name.hasPrefix(".")
                        && (mode == S_IFDIR || st.st_nlink == 1)
                    items.append(AIStorageItem(sourceID: source.id, path: childPath,
                        name: displayName(name, source: source), kind: kind,
                        allocated: child.allocated, logical: child.logical,
                        device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                        containsDownload: child.containsDownload, complete: child.complete,
                        eligible: eligible,
                        explanation: child.containsDownload ? "Download or temporary files were found. Finish the download and scan again."
                            : child.hasHardlinks ? "Hard-linked files may be shared with another location. Manage this repository in its AI tool."
                            : kind == .models ? "Removing this repository removes its local model files. Download it again before using it."
                            : "The tool can rebuild this cache; its next launch or operation may take longer."))
                }
            }
        }
        var after = stat()
        if fstat(fd, &after) != 0 || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
            || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec {
            measured.complete = false
            context.issue("Location changed while scanning; scan again: \(path)")
        }
        if !measured.complete && context.reachedLimit {
            context.issue("Scan budget reached; the measured size is a lower bound.")
        }
        return measured
    }

    private func isCandidate(source: AIStorageSource, level: Int, name: String, isDirectory: Bool) -> Bool {
        guard !Self.isDownloadMarker(name), !name.hasPrefix(".") else { return false }
        switch source.layout {
        case .ollama: return false // A blob may be shared by several model manifests.
        case .huggingFace: return level == 0 && isDirectory && name.hasPrefix("models--")
        case .lmStudio:
            return (level == 1 && isDirectory) || (level == 0 && !isDirectory && Self.isModelFile(name))
        case .mlx: return level == 0
        case .desktopCache: return false // The exact, verified cache root is one review unit.
        case .sessionHistory: return false // History is metadata-only, never a cleanup candidate.
        }
    }

    private func repositoryForLock(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: ".locks"), index + 1 < parts.count,
              parts[index + 1].hasPrefix("models--") else { return nil }
        return parts[index + 1]
    }

    private func displayName(_ name: String, source: AIStorageSource) -> String {
        source.layout == .huggingFace ? String(name.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/") : name
    }

    static func isDownloadMarker(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == ".locks" || lower == ".lock" || lower == "tmp" || lower == "temp"
            || lower == ".git" || lower == ".downloads" || lower == ".download"
            || lower.hasSuffix(".lock") || lower.hasSuffix(".incomplete")
            || lower.hasSuffix(".partial") || lower.hasSuffix(".part")
            || lower.hasSuffix(".download") || lower.hasSuffix(".tmp")
            || lower.contains("-partial-") || lower.hasPrefix("tmp-")
    }
    static func isModelFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["gguf", "ggml", "safetensors", "pt", "pth", "onnx", "bin"].contains(ext)
    }
}

@MainActor
final class AIStorageService: ObservableObject {
    @Published private(set) var report: AIStorageReport?
    @Published private(set) var isScanning = false
    @Published private(set) var isPreparingStage = false
    @Published private(set) var message: String?
    private let engine: AIStorageEngine
    private var cancellation: AIStorageCancellation?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(home: String = NSHomeDirectory()) { engine = AIStorageEngine(home: home) }
    // No timer and no on-appear scan. Only the scan action starts filesystem work.
    func scan() {
        guard !isScanning, !isPreparingStage else { return }
        generation &+= 1
        let currentGeneration = generation
        let cancellation = AIStorageCancellation()
        self.cancellation = cancellation
        isScanning = true; message = nil
        let engine = engine
        task = Task.detached(priority: .utility) { [weak self] in
            let result = engine.scan(cancellation: cancellation)
            guard let owner = self else { return }
            await MainActor.run {
                guard owner.generation == currentGeneration else { return }
                if result.cancelled || cancellation.isCancelled {
                    owner.message = owner.report == nil
                        ? "Scan cancelled. No cleanup items were selected."
                        : "Scan cancelled. The previous measurement was kept."
                } else {
                    owner.report = result
                    owner.message = result.reachedLimit ? "Scan budget reached. Partial sizes are lower bounds; staging is disabled for those locations." : nil
                }
                owner.isScanning = false; owner.cancellation = nil; owner.task = nil
            }
        }
    }
    func cancel() {
        guard (isScanning || isPreparingStage), let cancellation else { return }
        cancellation.cancel(); message = "Cancelling scan…"
    }

    /// Re-measure the selected source immediately before staging. The original inode
    /// must still identify the chosen repository; an active download or partial read
    /// disables the action. Only the host's existing queue handles the eventual Trash.
    func prepareForStaging(_ item: AIStorageItem, completion: @escaping (AIStorageItem?) -> Void) {
        guard !isScanning, !isPreparingStage,
              let source = report?.sources.first(where: { $0.id == item.sourceID })?.source else {
            completion(nil); return
        }
        generation &+= 1
        let currentGeneration = generation
        isPreparingStage = true; message = "Checking this item before staging…"
        let engine = engine
        let cancellation = AIStorageCancellation()
        self.cancellation = cancellation
        task = Task.detached(priority: .utility) { [weak self] in
            let freshReport = engine.scan(sources: [source], cancellation: cancellation)
            let footprint = freshReport.sources.first
            let fresh = footprint?.eligibleItems.first {
                $0.path == item.path && $0.device == item.device && $0.inode == item.inode
            }
            guard let owner = self else { return }
            await MainActor.run {
                guard owner.generation == currentGeneration else { completion(nil); return }
                owner.isPreparingStage = false; owner.cancellation = nil; owner.task = nil
                let prepared = cancellation.isCancelled ? nil : fresh
                owner.message = cancellation.isCancelled ? "Stage check cancelled. Nothing was added to the cleanup queue."
                    : prepared == nil ? "This item changed, is downloading, or could not be fully read. Scan again before staging." : nil
                completion(prepared)
            }
        }
    }
}
