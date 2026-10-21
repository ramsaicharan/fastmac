import SwiftUI
import AppKit

// MARK: - Full Disk Access
//
// There is no public API that simply answers "do I have FDA". Our best-effort
// protected-path probe runs only after an explicit Check Access action. Merely
// opening onboarding or Settings must not touch a protected folder.

/// Full Disk Access detection.
///
/// Delegates to the common probe rather than maintaining a second implementation.
/// The Boolean entry point is kept for existing explicit diagnostic checks; UI
/// uses all three statuses and also distinguishes a check that has not been run.
enum FDACheck {
    static func hasFullDiskAccess() -> Bool { FullDiskAccess.check() == .granted }
    static func openPrivacySettings() { FullDiskAccess.openSettings() }

    static func label(for status: FullDiskAccess.Status?) -> String {
        switch status {
        case .granted: "Full Disk Access appears granted"
        case .denied: "Protected-folder access was denied"
        case .unknown: "Full Disk Access could not be determined"
        case nil: "Full Disk Access has not been checked"
        }
    }

    static func color(for status: FullDiskAccess.Status?) -> Color {
        switch status {
        case .granted: .green
        case .denied: .orange
        case .unknown, nil: .secondary
        }
    }
}

// MARK: - Onboarding sheet

struct OnboardingView: View {
    static let completedKey = "FastMac.OnboardingCompleted"
    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: completedKey) }

    /// The host closes the sheet after the user completes onboarding.
    var onDismiss: () -> Void

    @State private var fdaStatus: FullDiskAccess.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 28)).foregroundStyle(.blue)
                Text("Welcome to FastMac").font(.title2).bold()
            }

            Text("Keep an eye on your Mac from the menu bar. Open the dashboard to understand memory pressure, disk space and the storage used by AI tools.")
                .font(.callout)

            bullet("Lightweight checks, on your terms.",
                  "Health monitoring reads system counters. Folder and AI storage scans run on request; application footprints are analyzed when opened.")
            bullet("Review before cleanup.",
                  "Choose specific items and confirm before they move to the Trash. Space is freed when you empty the Trash in Finder.")
            bullet("Everything runs locally.",
                  "Your files and usage stay on your Mac. There is no account, telemetry or cloud analysis.")

            Text("Closing the dashboard keeps the menu bar running. Use Settings to pause monitoring or opt in to launch at login; use Quit FastMac to stop the app.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            fdaSection

            Spacer(minLength: 4)

            HStack {
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: Self.completedKey)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .onAppear {
            // Acknowledging presentation also covers closing the window or sheet
            // without pressing Get Started. No permission is implied or changed.
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
    }

    private var fdaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(FDACheck.color(for: fdaStatus)).frame(width: 9, height: 9)
                Text(FDACheck.label(for: fdaStatus))
                    .font(.callout).bold()
            }
            Text("Full Disk Access is optional. macOS remembers your permission choices. You can continue now and review access later in Settings if a scan cannot read protected folders.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(fdaStatus == nil ? "Check Access" : "Recheck Access") {
                    fdaStatus = FullDiskAccess.check()
                }
                if fdaStatus != .granted {
                    Button("Open Privacy Settings…") { FDACheck.openPrivacySettings() }
                }
            }
        }
        .padding(12)
        .background(FDACheck.color(for: fdaStatus).opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(FDACheck.color(for: fdaStatus).opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Persistent FDA banner
//
// A small, reusable strip other views can drop in (e.g. above the scan toolbar) so
// the under-reporting bug stays visible after onboarding is dismissed, not just on
// first run. Self-contained — no AppStore dependency, matching the rest of this
// feature's views.

struct FDABanner: View {
    @State private var status: FullDiskAccess.Status?

    var body: some View {
        if status != .granted {
            HStack(spacing: 8) {
                Image(systemName: status == .denied ? "exclamationmark.triangle.fill" : "checkmark.shield")
                    .foregroundStyle(FDACheck.color(for: status))
                Text(FDACheck.label(for: status))
                    .font(.caption)
                Spacer()
                Button("Privacy Settings…") { FDACheck.openPrivacySettings() }.font(.caption)
                Button(status == nil ? "Check Access" : "Recheck") {
                    status = FullDiskAccess.check()
                }.font(.caption)
            }
            .padding(8)
            .background(FDACheck.color(for: status).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
