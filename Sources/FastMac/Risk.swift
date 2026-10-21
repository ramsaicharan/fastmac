import SwiftUI

/// One vocabulary for "what happens if I press this", used by every action in the app.
///
/// The point is not decoration. A person deciding whether to empty a cache, kill a
/// process, or disable a login item needs three things in the same glance: how bad the
/// worst case is, what exactly is lost, and how to get it back. A coloured word alone
/// would be theatre — so every level carries `what` and `undo` text with it, and the
/// UI is expected to show them.
enum Risk: Int, Comparable, CaseIterable {

    /// Regenerates on its own. You pay a re-download or a rebuild, nothing else.
    case safe = 0

    /// Real data, but replaceable or recoverable. You will notice it went.
    case caution = 1

    /// Hard to undo, or changes how the machine behaves. Read before pressing.
    case risky = 2

    /// The app will not do this — it needs admin rights, or the safety guard refuses.
    /// Shown so the user understands *why* there is no button, not hidden away.
    case blocked = 3

    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe:    "Safe"
        case .caution: "Caution"
        case .risky:   "Risky"
        case .blocked: "Needs admin"
        }
    }

    var tint: Color {
        switch self {
        case .safe:    .green
        case .caution: .yellow
        case .risky:   .orange
        case .blocked: .secondary
        }
    }

    var icon: String {
        switch self {
        case .safe:    "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .risky:   "flame.fill"
        case .blocked: "lock.fill"
        }
    }

    /// The one-line meaning of the level itself, shown in the legend and on hover.
    var meaning: String {
        switch self {
        case .safe:    "Regenerates by itself. Costs a re-download or a rebuild."
        case .caution: "Real data, but replaceable or recoverable. You will notice."
        case .risky:   "Hard to undo, or it changes how the Mac behaves."
        case .blocked: "FastMac will not do this — it needs admin rights it deliberately does not take."
        }
    }
}

/// An action the user can take, with its consequences attached rather than implied.
struct RiskNote {
    let risk: Risk
    /// What actually happens, in plain language. Concrete, not reassuring.
    let what: String
    /// How to get back to where you were. "Cannot be undone" is a valid answer.
    let undo: String

    init(_ risk: Risk, what: String, undo: String) {
        self.risk = risk
        self.what = what
        self.undo = undo
    }

    // Notes reused across the app, so the same action reads the same way everywhere.

    static let trash = RiskNote(.caution,
        what: "Moves your selected data to the Trash. Review its contents first; moving to Trash does not make the data disposable or release disk space.",
        undo: "Finder → Trash → Put Back, or ⌘Z straight after.")

    static func trash(path: String) -> RiskNote {
        if let owner = ConversationStorage.owner(of: Safety.canonical(path), includingAncestors: true) {
            return RiskNote(.risky,
                what: "Contains \(owner) conversation history: messages, tool results and possibly embedded images. Removing it can prevent chats from reopening or resuming. FastMac protects it from generic cleanup; review individual chats in the owning app.",
                undo: "Keep a backup before deleting chats. Archiving keeps their stored history and does not free this disk space.")
        }
        return .trash
    }

    static let permanentDelete = RiskNote(.risky,
        what: "Removes the item immediately, bypassing the Trash.",
        undo: "Cannot be undone. Only a backup will bring it back.")

    static let regenerableCache = RiskNote(.safe,
        what: "Deletes cached files the owning tool wrote and can write again.",
        undo: "Nothing to undo — the tool rebuilds or re-downloads on next use.")

    static let buildOutput = RiskNote(.safe,
        what: "Deletes compiled output and downloaded dependencies for a project.",
        undo: "One install or build command restores it, given a network connection.")

    static let quitProcess = RiskNote(.caution,
        what: "Sends SIGTERM. The app gets a chance to save and close cleanly.",
        undo: "Relaunch the app. Unsaved work is usually kept.")

    static let forceQuitProcess = RiskNote(.risky,
        what: "Sends SIGKILL. The process dies immediately with no chance to save.",
        undo: "Relaunch the app. Anything unsaved is gone.")

    static let disableLoginItem = RiskNote(.caution,
        what: "Stops a background item from starting at login. Its app may lose updates, sync, or a helper it relies on.",
        undo: "Re-enable it here; takes effect at next login.")

    static let orphanLoginItem = RiskNote(.safe,
        what: "Removes a startup entry whose program no longer exists on disk.",
        undo: "Nothing to undo — it was already doing nothing but costing boot time.")

    static let thinSnapshots = RiskNote(.caution,
        what: "Deletes local Time Machine snapshots. Your real backups on the backup disk are untouched.",
        undo: "Cannot be undone locally. Restore from the Time Machine drive instead.")

    static let spotlightRebuild = RiskNote(.risky,
        what: "Discards the Spotlight index and rebuilds it. Search is unreliable and the Mac runs hot until it finishes — often hours.",
        undo: "Nothing to undo; it finishes on its own. Do not start this before you need the machine.")

    static let needsAdmin = RiskNote(.blocked,
        what: "This needs administrator rights. FastMac does not ask for your password by design.",
        undo: "Run the shown command yourself in Terminal if you want it.")
}

// MARK: - Shared UI

/// The badge. Small, consistent, and always hoverable for the full explanation.
struct RiskBadge: View {
    let risk: Risk
    var note: RiskNote? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: risk.icon).font(.system(size: 9))
            if !compact { Text(risk.label).font(.caption2.weight(.semibold)) }
        }
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2)
        .background(risk.tint.opacity(0.16))
        .foregroundStyle(risk.tint)
        .clipShape(Capsule())
        .help(helpText)
    }

    private var helpText: String {
        guard let note else { return risk.meaning }
        return "\(risk.label) — \(risk.meaning)\n\nWhat happens: \(note.what)\n\nUndo: \(note.undo)"
    }
}

/// The full consequence block, for confirmation dialogs and detail panes — the place
/// where a person is actually deciding, and deserves more than a coloured word.
struct RiskDetail: View {
    let note: RiskNote

    var body: some View {
        // Every text row must be told it may wrap. A `Label` lays out on a single line by
        // default, so a full sentence demands its entire width from the parent — five of
        // these in a column pushed the split view's sidebar and inspector clean off the
        // screen and left the detail pane scrolled past its own content.
        VStack(alignment: .leading, spacing: 7) {
            RiskBadge(risk: note.risk, note: note)
            Label(note.what, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Label(note.undo, systemImage: "arrow.uturn.backward")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Legend so the vocabulary is learnable in one place instead of inferred.
struct RiskLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Risk.allCases, id: \.rawValue) { r in
                HStack(spacing: 5) {
                    RiskBadge(risk: r, compact: true)
                    Text(r.label).font(.caption2).foregroundStyle(.secondary)
                }
                .help(r.meaning)
            }
        }
    }
}

// MARK: - Checks for the risk vocabulary and the fixed alert edge case

enum RiskSelfCheck {
    static func run() -> [String] {
        var out: [String] = []
        func check(_ label: String, _ ok: Bool) {
            out.append("\(ok ? "PASS" : "FAIL")  \(label)")
        }

        // Every level must carry a usable explanation — a coloured word alone is theatre.
        for r in Risk.allCases {
            check("risk '\(r.label)' has meaning text", !r.meaning.isEmpty)
            check("risk '\(r.label)' has an icon", !r.icon.isEmpty)
        }
        check("risk ordering is safe < caution < risky < blocked",
              Risk.safe < Risk.caution && Risk.caution < Risk.risky && Risk.risky < Risk.blocked)

        // Notes must say what happens AND how to undo it.
        let notes: [(String, RiskNote)] = [
            ("trash", .trash), ("permanentDelete", .permanentDelete),
            ("regenerableCache", .regenerableCache), ("buildOutput", .buildOutput),
            ("quitProcess", .quitProcess), ("forceQuitProcess", .forceQuitProcess),
            ("disableLoginItem", .disableLoginItem), ("orphanLoginItem", .orphanLoginItem),
            ("thinSnapshots", .thinSnapshots), ("spotlightRebuild", .spotlightRebuild),
            ("needsAdmin", .needsAdmin),
        ]
        for (name, n) in notes {
            check("note '\(name)' explains what happens", n.what.count > 20)
            check("note '\(name)' explains undo", n.undo.count > 10)
        }
        check("force quit is rated riskier than quit",
              RiskNote.forceQuitProcess.risk > RiskNote.quitProcess.risk)
        check("permanent delete is rated riskier than trashing",
              RiskNote.permanentDelete.risk > RiskNote.trash.risk)
        check("removing a dead startup entry is rated safe",
              RiskNote.orphanLoginItem.risk == .safe)
        check("spotlight rebuild is rated risky",
              RiskNote.spotlightRebuild.risk == .risky)

        // The regression this file's sibling fix addresses: a rate-limited first firing
        // must NOT consume the edge, or a persistently full disk goes silent forever.
        var ev = AlertEvaluator(freeDiskThresholdBytes: 10 << 30,
                                memoryPressureThreshold: 85,
                                sustainedSeconds: 60,
                                rateLimit: 3600)
        let t0 = Date()
        // Fire once on the way in.
        let first = ev.evaluate(diskFree: 5 << 30, pressure: 10, now: t0)
        check("disk alert fires on crossing the threshold", first.contains(.disk))
        // Still bad, inside the rate limit: silent, but the condition stays armed.
        let during = ev.evaluate(diskFree: 4 << 30, pressure: 10, now: t0.addingTimeInterval(60))
        check("disk alert stays quiet inside the rate limit", during.isEmpty)
        // Recovery, then a fresh crossing after the rate limit: must fire again.
        _ = ev.evaluate(diskFree: 50 << 30, pressure: 10, now: t0.addingTimeInterval(120))
        let again = ev.evaluate(diskFree: 3 << 30, pressure: 10,
                                now: t0.addingTimeInterval(3 * 3600))
        check("disk alert fires again on a later crossing", again.contains(.disk))

        // The exact bug: suppressed-while-crossing must not silence it permanently.
        var ev2 = AlertEvaluator(freeDiskThresholdBytes: 10 << 30,
                                 memoryPressureThreshold: 85,
                                 sustainedSeconds: 60,
                                 rateLimit: 3600)
        let s0 = Date()
        _ = ev2.evaluate(diskFree: 5 << 30, pressure: 10, now: s0)              // fires
        _ = ev2.evaluate(diskFree: 50 << 30, pressure: 10, now: s0.addingTimeInterval(10)) // recovers
        let suppressed = ev2.evaluate(diskFree: 4 << 30, pressure: 10,
                                      now: s0.addingTimeInterval(20))           // crosses, rate-limited
        check("second crossing inside the rate limit is suppressed", suppressed.isEmpty)
        let later = ev2.evaluate(diskFree: 4 << 30, pressure: 10,
                                 now: s0.addingTimeInterval(2 * 3600))          // still bad, limit expired
        check("still-full disk warns once the rate limit expires (the fixed bug)",
              later.contains(.disk))

        return out
    }
}
