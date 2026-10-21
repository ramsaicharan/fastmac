import SwiftUI

/// Admin-level maintenance, presented so the decision is informed rather than reflexive.
///
/// Every row shows what it does, its risk, the exact command, and a copy button — so
/// "run it yourself in Terminal" is always a first-class option, not a consolation prize.
struct PrivilegedActionsView: View {
    @State private var confirming: Privileged.Command?
    @State private var running: String?
    @State private var result: ActionResult?

    /// Identifiable so the alert can own and clear its own state instead of relying on a
    /// `.constant` binding that SwiftUI is unable to reset.
    private struct ActionResult: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if Privileged.all.isEmpty {
                Text("No administrator actions are available on this system.")
                    .foregroundStyle(.secondary).padding(24)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Privileged.all, id: \.id) { cmd in
                        row(cmd)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Run as administrator?", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Authenticate…") { if let c = confirming { run(c) }; confirming = nil }
        } message: {
            if let c = confirming {
                Text("""
                     \(c.title)

                     macOS will ask for your password in its own window. FastMac never sees it.

                     Command: \(c.shell)

                     What happens: \(c.note.what)
                     Undo: \(c.note.undo)
                     """)
            }
        }
        .alert(item: $result) { r in
            Alert(title: Text(r.title), message: Text(r.body), dismissButton: .default(Text("OK")))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Administrator Actions").font(.title3.weight(.semibold))
            Text("""
                 These need root. FastMac does not draw its own password box — it asks macOS \
                 to authenticate you, so your password goes to the system, never to this app. \
                 Every command is a fixed constant in the source; nothing you type or select \
                 is ever passed to a root shell.
                 """)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RiskLegend().padding(.top, 2)
        }
        .padding(16)
    }

    private func row(_ cmd: Privileged.Command) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(cmd.title).font(.headline)
                RiskBadge(risk: cmd.note.risk, note: cmd.note)
                Spacer()
                if running == cmd.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run…") { confirming = cmd }
                        .buttonStyle(.bordered)
                        .disabled(running != nil)
                }
            }
            Text(cmd.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Privileged.terminalEquivalent(cmd))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Privileged.terminalEquivalent(cmd), forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
                    .help("Copy — run it in Terminal yourself instead")
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            RiskDetail(note: cmd.note)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func run(_ cmd: Privileged.Command) {
        running = cmd.id
        Task.detached(priority: .userInitiated) {
            let outcome = Privileged.run(cmd)
            await MainActor.run {
                running = nil
                switch outcome {
                case .succeeded(let output):
                    result = ActionResult(title: cmd.title, body: output.isEmpty
                        ? "Completed successfully."
                        : "Completed.\n\n\(output)")
                case .cancelled:
                    result = ActionResult(title: "Cancelled",
                                          body: "You dismissed the authentication panel. Nothing ran.")
                case .failed(let message):
                    result = ActionResult(title: "Did not run", body: message.isEmpty
                        ? "The command failed with no output."
                        : message)
                }
            }
        }
    }
}
