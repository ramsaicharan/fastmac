import SwiftUI
import AppKit

/// Uses an app-owned service so navigating away and back keeps the last measurement.
/// Opening this view does not start a scan or change the cleanup queue.
struct AIStorageView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var service: AIStorageService
    @StateObject private var models = LocalModelsService()
    @State private var pendingReview: AIStorageItem?
    @State private var reviewedConsequence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("AI view", selection: $store.aiShowsLoadedModels) {
                Text("Storage on disk").tag(false)
                Text("Loaded models").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if let message = service.message {
                Label(message, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 9)
            }
            if store.aiShowsLoadedModels { LocalModelsView(service: models) }
            else if let report = service.report {
                results(report)
            } else {
                empty
            }
        }
        .sheet(item: $pendingReview, onDismiss: { reviewedConsequence = false }) { item in
            reviewSheet(item)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI Storage").font(.title3.weight(.semibold))
                Text("Review conversation history, local models and runtime caches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !store.aiShowsLoadedModels {
                if service.isScanning || service.isPreparingStage {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { service.cancel() }.controlSize(.small)
                } else {
                    Button {
                        service.scan()
                    } label: {
                        Label(service.report == nil ? "Scan AI Storage" : "Rescan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "internaldrive").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(service.isScanning ? "Measuring known AI locations…" : "See where local AI uses disk space")
                .font(.headline)
            Text("Measure known conversation-history folders, local models and specific desktop caches only when you scan. History inspection reads file sizes and dates; it never opens your messages or images. Custom folders are not searched.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 430)
            if !service.isScanning {
                Button("Scan AI Storage") { service.scan() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func results(_ report: AIStorageReport) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(fmt(report.allocated)) measured in known AI locations")
                        .font(.headline).monospacedDigit()
                    Text("Last scan \(report.scannedAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f", report.elapsed))s")
                        .font(.caption).foregroundStyle(.secondary)
                    if report.hasPartialResults {
                        Text("Some locations were not fully measured. Their totals are lower bounds and cleanup staging is disabled.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Disk space can improve after unused models are removed. This does not increase CPU speed or free memory used by a running model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(report.sources) { footprint in
                    sourceCard(footprint)
                }
            }
            .padding(16)
        }
    }

    private func sourceCard(_ footprint: AIStorageFootprint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(footprint.source.name).font(.headline)
                    Text(footprint.source.layout == .mlx ? "Runtime cache and possible model data" : footprint.source.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(footprint.status.title).font(.caption)
                    .foregroundStyle(footprint.status == .complete || footprint.status == .missing ? Color.secondary : Color.orange)
                if footprint.status != .missing {
                    Text(fmt(footprint.allocated)).font(.headline).monospacedDigit()
                }
            }
            Text(footprint.source.explanation).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text(footprint.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Reveal", systemImage: "folder") { reveal(footprint.path) }
                    .controlSize(.small).disabled(footprint.status == .missing)
            }
            if footprint.status == .unreadable {
                Text("Allow access to this folder in System Settings → Privacy & Security, then scan again.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if footprint.transientBytes > 0 {
                Text("\(fmt(footprint.transientBytes)) in download or temporary entries; these are excluded from cleanup suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if footprint.logical > footprint.allocated {
                Text("Logical size \(fmt(footprint.logical)); the headline uses allocated disk space.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if footprint.skippedLinks > 0 {
                Text("\(footprint.skippedLinks) symbolic links skipped. Shared or linked model files were not counted twice.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if footprint.source.layout == .ollama && footprint.status == .complete && footprint.allocated > 0 {
                Text("Review installed models in Ollama. Shared blobs are not queued individually because other models may depend on them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if footprint.source.kind == .conversationHistory {
                historyGuidance(footprint)
            }
            ForEach(footprint.issues, id: \.self) { issue in
                Text(issue).font(.caption2).foregroundStyle(.orange).lineLimit(3)
            }
            if !footprint.items.isEmpty {
                Divider()
                ForEach(footprint.items) { item in
                    itemRow(item, sourceComplete: footprint.status == .complete)
                }
            } else if footprint.status == .complete && footprint.source.layout != .ollama && footprint.source.kind != .conversationHistory {
                Text(footprint.allocated == 0 ? "No downloaded data found." : "No complete model repositories available for review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    private func itemRow(_ item: AIStorageItem, sourceComplete: Bool) -> some View {
        let staged = store.staged.contains { $0.path == item.path }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(item.eligible ? item.kind.title : item.explanation)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let date = item.modifiedAt {
                    Text("Modified \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(fmt(item.allocated)).font(.callout).monospacedDigit()
            if item.kind == .conversationHistory {
                Button("Reveal") { reveal(item.path) }.controlSize(.small)
            } else {
                Button(staged ? "Staged" : "Review") {
                    reviewedConsequence = false; pendingReview = item
                }
                .controlSize(.small)
                .disabled(staged || !sourceComplete || !item.eligible || service.isScanning || service.isPreparingStage)
                .help(item.eligible ? "Review the impact before adding this item to the cleanup queue." : item.explanation)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Reveal in Finder") { reveal(item.path) } }
    }

    private func historyGuidance(_ footprint: AIStorageFootprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RiskBadge(risk: .risky)
            Text("\(footprint.files) files measured · showing up to 20 largest transcript files")
                .font(.caption).foregroundStyle(.secondary)
            Text("History is protected from generic cleanup. To release storage, back up needed chats and delete selected conversations in their app. Archiving keeps the stored data. FastMac does not rewrite transcripts or remove embedded images.")
                .font(.caption).foregroundStyle(.secondary)
            Text("These are disk bytes, not live RAM. Context compaction can add saved snapshots without shrinking the existing log. Older modification dates do not prove a chat is unused.")
                .font(.caption).foregroundStyle(.secondary)
            let isClaude = footprint.source.id == "claude-history"
            let identifiers = isClaude ? ["com.anthropic.claudefordesktop"] : ["com.openai.codex", "com.openai.chat"]
            if let url = identifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                Button(isClaude ? "Open Claude to review chats" : "Open ChatGPT / Codex to review chats") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }.controlSize(.small)
            }
        }
    }

    private func reviewSheet(_ item: AIStorageItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review \(item.name)").font(.title3.weight(.semibold)).lineLimit(2)
            Text("\(fmt(item.allocated)) allocated on disk").font(.callout).monospacedDigit()
            RiskDetail(note: RiskNote(.caution,
                what: item.kind == .models
                    ? "Trashing this repository removes local model weights. Any model that relies on them will need to download them again. Stop its AI app and downloads first."
                    : "Trashing this runtime cache requires the tool to rebuild it. Stop the tool first; the next run may take longer.",
                undo: "Staging only adds the item to the cleanup queue. If later moved to Trash, use Finder → Trash → Put Back, or download or rebuild it again."))
            Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Toggle(item.kind == .models ? "I no longer need this local model and can download it again."
                   : "I understand this cache will need to be rebuilt.", isOn: $reviewedConsequence)
                .font(.callout)
            if let message = service.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") { reveal(item.path) }
                Spacer()
                Button("Cancel") {
                    if service.isPreparingStage { service.cancel() }
                    pendingReview = nil
                }.keyboardShortcut(.cancelAction)
                Button(service.isPreparingStage ? "Checking…" : "Add to Cleanup Queue") {
                    service.prepareForStaging(item) { fresh in
                        guard let fresh else { return }
                        store.stage([fresh.path], sizes: [fresh.path: fresh.allocated],
                                    logicalSizes: [fresh.path: fresh.logical],
                                    reason: "AI Storage: reviewed \(fresh.name); re-download or rebuild needed")
                        pendingReview = nil
                        if store.staged.contains(where: { $0.path == fresh.path }) { store.view = .cleanup }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewedConsequence || service.isPreparingStage || service.isScanning)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
