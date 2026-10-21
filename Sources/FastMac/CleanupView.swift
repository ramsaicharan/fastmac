import SwiftUI

struct CleanupView: View {
    var onPurge: () -> Void

    var body: some View {
        ScrollView { snapshotContent }
            .navigationTitle("Cleanup Queue")
    }

    /// Shared production content without ScrollView's unsupported platform wrapper.
    var snapshotContent: some View { CleanupContent(onPurge: onPurge) }
}

private struct CleanupContent: View {
    @EnvironmentObject var store: AppStore
    var onPurge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review your cleanup").font(.largeTitle.weight(.semibold))
                    Text("\(store.staged.count) items · \(fmt(store.stagedBytes)) on disk")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "tray.full.fill").font(.system(size: 36))
                    .foregroundStyle(.blue)
            }

            Text("Items move to the Trash after you confirm. You can restore them in Finder until you empty the Trash. Moving items to the Trash alone does not release space on your disk.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let banner = store.banner {
                Text(banner).font(.callout).foregroundStyle(.secondary)
            }

            if store.staged.isEmpty {
                ContentUnavailableView {
                    Label("Your queue is empty", systemImage: "checkmark.circle")
                } description: {
                    Text("Review AI models, caches, or large files and add the items you choose.")
                } actions: {
                    Button("Review AI Storage") { store.view = .aiStorage }
                    Button("Find Quick Wins") { store.view = .quick }
                }
                .frame(minHeight: 260)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.staged) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                                .font(.title2).foregroundStyle(.blue).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.headline)
                                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled).lineLimit(2)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                RiskDetail(note: .trash(path: item.path))
                                if !Safety.canDelete(item.path).ok {
                                    Text(Safety.canDelete(item.path).why).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text(fmt(item.allocated)).monospacedDigit()
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            }
                            Button("Remove") { store.unstage(item.path) }
                                .disabled(store.purgeInFlight)
                        }.padding(16)
                        Divider()
                    }
                }
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Clear queue") { store.clearStaged() }
                        .disabled(store.purgeInFlight)
                    Spacer()
                    if store.purgeInFlight { ProgressView().controlSize(.small) }
                    Button("Move \(store.staged.count) items to Trash", action: onPurge)
                        .buttonStyle(.borderedProminent)
                        .disabled(store.purgeInFlight || store.progress.running || store.refreshing)
                }
            }
        }.padding(28)
    }
}
