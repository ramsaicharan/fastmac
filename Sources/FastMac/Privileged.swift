import Foundation

/// Running a maintenance command as root, without FastMac ever seeing your password.
///
/// ## Why not just prompt for the password ourselves?
///
/// Because an app that draws its own password box and then runs `sudo -S` has done three
/// bad things: it has the plaintext password in its own memory, it has trained you to type
/// your admin password into any window that asks, and it is indistinguishable from malware
/// doing the same. That is a genuinely bad pattern, not excessive caution.
///
/// ## What this does instead
///
/// `do shell script … with administrator privileges` hands the request to macOS. **The
/// system** draws the authentication panel, **the system** collects the password, and this
/// process only ever receives the command's output. We never see, store, or transmit the
/// password — the same mechanism Installer and Disk Utility use.
///
/// ## The remaining honest caveat
///
/// FastMac is ad-hoc signed, so the panel will name it without a verified developer. You
/// are trusting a binary you built locally. That is a reasonable thing to trust, but you
/// should know that is what you are doing — which is why every privileged action shows you
/// the exact command first and requires an explicit press.
///
/// ## The rule this file enforces
///
/// Commands are **compile-time constants declared in this file**. Nothing built from user
/// input, a filename, or a scan result is ever eligible. Root plus string interpolation is
/// how you delete someone's disk by accident; the type system is used here to make that
/// impossible rather than merely discouraged.
enum Privileged {

    /// A vetted root command. The initialiser is private, so the only instances that can
    /// exist are the constants below — a caller cannot construct an arbitrary one.
    struct Command {
        let id: String
        let title: String
        /// Shown verbatim before anything runs, so the user can run it themselves instead.
        let shell: String
        let explanation: String
        let note: RiskNote

        fileprivate init(id: String, title: String, shell: String,
                         explanation: String, note: RiskNote) {
            self.id = id; self.title = title; self.shell = shell
            self.explanation = explanation; self.note = note
        }
    }

    // MARK: - The complete set of things FastMac will ever ask root to do

    static let flushDNS = Command(
        id: "flush-dns",
        title: "Flush DNS cache",
        shell: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
        explanation: "Clears cached hostname lookups. Useful when a site resolves to a stale address.",
        note: RiskNote(.safe,
            what: "Empties the DNS cache and restarts the resolver. Network connections continue working.",
            undo: "Nothing to undo — the cache refills as you browse."))

    static let rebuildSpotlight = Command(
        id: "spotlight-rebuild",
        title: "Rebuild Spotlight index",
        shell: "/usr/bin/mdutil -E /",
        explanation: "Discards and rebuilds the search index for the boot volume.",
        note: .spotlightRebuild)

    static let disableSpotlight = Command(
        id: "spotlight-off",
        title: "Turn Spotlight indexing off",
        shell: "/usr/bin/mdutil -i off /",
        explanation: "Stops indexing entirely. Search stops finding new files; `mds` stops using CPU.",
        note: RiskNote(.risky,
            what: "Spotlight stops indexing. Search will not find newly created or changed files.",
            undo: "Turn it back on here; a full reindex follows and takes hours."))

    static let enableSpotlight = Command(
        id: "spotlight-on",
        title: "Turn Spotlight indexing on",
        shell: "/usr/bin/mdutil -i on /",
        explanation: "Re-enables indexing. A full reindex follows.",
        note: RiskNote(.caution,
            what: "Indexing resumes and reindexes the volume — heavy CPU and disk for a while.",
            undo: "Turn it off again here."))

    static let clearSystemFontCache = Command(
        id: "font-cache",
        title: "Clear system font caches",
        shell: "/usr/bin/atsutil databases -remove",
        explanation: "Rebuilds the font databases. Fixes garbled or missing fonts.",
        note: RiskNote(.caution,
            what: "Removes system font caches. Apps may take a moment to redraw text afterwards.",
            undo: "Nothing to undo — macOS rebuilds the caches on demand. A restart helps."))

    // MARK: - Parameterised, but only within a hard-validated shape
    //
    // Removing a dead launch item genuinely needs a path argument, so the closed-constant
    // rule cannot cover it. Instead the path must survive `isVettedLaunchPlist` before a
    // Command can exist at all: an absolute path in a known launch directory, a plain
    // filename, `.plist`, and not one byte outside a conservative character set. Anything
    // with a space, quote, semicolon, backtick or `$` is rejected outright — so nothing
    // that reaches the root shell can carry a second command with it.

    static let launchDirectories = [
        "/Library/LaunchAgents", "/Library/LaunchDaemons",
    ]

    static func isVettedLaunchPlist(_ path: String) -> Bool {
        guard path.hasSuffix(".plist"), !path.contains("..") else { return false }
        guard let dir = launchDirectories.first(where: { path.hasPrefix($0 + "/") }) else { return false }
        let name = String(path.dropFirst(dir.count + 1))
        guard !name.isEmpty, !name.contains("/") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Move a dead system launch item to a disabled backup beside itself.
    ///
    /// Renaming rather than deleting is deliberate: a startup entry is cheap to keep and
    /// expensive to reconstruct if the judgement was wrong. `.plist.fastmac-disabled` is
    /// ignored by launchd and is one `mv` away from being restored.
    static let disabledSuffix = ".fastmac-disabled"
    /// Items disabled before the rename from DiskMap carry this suffix and must stay restorable.
    static let legacyDisabledSuffix = ".diskmap-disabled"

    static func disableLaunchItem(path: String, label: String) -> Command? {
        guard isVettedLaunchPlist(path) else { return nil }
        let backup = path + disabledSuffix
        return Command(
            id: "disable-launch-item:" + label,
            title: "Disable \(label)",
            shell: "/bin/mv '\(path)' '\(backup)'",
            explanation: "Renames the startup entry so launchd stops loading it. The file stays on disk.",
            note: RiskNote(.caution,
                what: "Renames \(path) to \(backup). launchd ignores it from the next boot.",
                undo: "Rename it back: sudo mv '\(backup)' '\(path)'"))
    }

    static func restoreLaunchItem(path: String, label: String,
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Command? {
        guard isVettedLaunchPlist(path) else { return nil }
        let legacy = path + legacyDisabledSuffix
        let backup = !exists(path + disabledSuffix) && exists(legacy) ? legacy : path + disabledSuffix
        return Command(
            id: "restore-launch-item:" + label,
            title: "Restore \(label)",
            shell: "/bin/mv '\(backup)' '\(path)'",
            explanation: "Puts the startup entry back where launchd will load it.",
            note: RiskNote(.caution,
                what: "Renames \(backup) back to \(path). It loads again at next boot.",
                undo: "Disable it again from this screen."))
    }

    static let all: [Command] = [
        flushDNS, rebuildSpotlight, disableSpotlight, enableSpotlight, clearSystemFontCache,
    ]

    // MARK: - Execution

    enum Outcome {
        case succeeded(output: String)
        case cancelled                  // the user dismissed the system panel
        case failed(String)
    }

    /// Runs one vetted command via the system authentication panel.
    ///
    /// Blocking, so call it off the main actor. `Command` cannot be constructed outside
    /// this file, which is what makes the AppleScript string below safe to build.
    static func run(_ command: Command) -> Outcome {
        // The command text is a constant from this file. The only escaping needed is for
        // the AppleScript string literal itself.
        let escaped = command.shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err

        do { try task.run() } catch {
            return .failed("Could not start osascript: \(error.localizedDescription)")
        }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let stdout = String(data: oData, encoding: .utf8) ?? ""
        let stderr = String(data: eData, encoding: .utf8) ?? ""

        if task.terminationStatus == 0 {
            Audit.log("privileged:\(command.id)", bytes: 0, path: command.shell)
            return .succeeded(output: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // -128 is the documented "user cancelled" code from the authentication panel.
        if stderr.contains("-128") || stderr.contains("User canceled") {
            return .cancelled
        }
        Audit.log("privileged-failed:\(command.id)", bytes: 0, path: command.shell)
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Run several vetted commands under a SINGLE authentication.
    ///
    /// Nine dead entries should not mean nine password prompts. Every command is still a
    /// validated constant, and they are joined with `&&` so the batch stops at the first
    /// failure rather than ploughing on.
    static func runAll(_ commands: [Command], title: String) -> Outcome {
        guard !commands.isEmpty else { return .succeeded(output: "") }
        let joined = commands.map(\.shell).joined(separator: " && ")
        let escaped = joined
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return .failed("Could not start osascript: \(error.localizedDescription)")
        }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let stdout = String(data: oData, encoding: .utf8) ?? ""
        let stderr = String(data: eData, encoding: .utf8) ?? ""

        if task.terminationStatus == 0 {
            for c in commands { Audit.log("privileged:\(c.id)", bytes: 0, path: c.shell) }
            return .succeeded(output: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if stderr.contains("-128") || stderr.contains("User canceled") { return .cancelled }
        Audit.log("privileged-batch-failed:\(title)", bytes: 0, path: joined)
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What to show when the user would rather run it themselves — always offered.
    static func terminalEquivalent(_ command: Command) -> String { "sudo " + command.shell }
}

// MARK: - Checks

enum PrivilegedSelfCheck {
    static func run() -> [String] {
        var out: [String] = []
        func check(_ label: String, _ ok: Bool) { out.append("\(ok ? "PASS" : "FAIL")  \(label)") }

        check("there is a fixed, finite set of privileged commands", Privileged.all.count == 5)
        for c in Privileged.all {
            check("'\(c.title)' shows its exact shell command", !c.shell.isEmpty)
            check("'\(c.title)' explains itself", c.explanation.count > 20)
            check("'\(c.title)' carries undo guidance", c.note.undo.count > 10)
            // Absolute paths only: a bare name would resolve against whatever PATH root has.
            check("'\(c.title)' uses absolute executable paths",
                  c.shell.split(separator: ";").allSatisfy {
                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("/")
                  })
            // Nothing interpolated — no placeholder ever reaches a root shell.
            check("'\(c.title)' contains no interpolation",
                  !c.shell.contains("\\(") && !c.shell.contains("$("))
            check("'\(c.title)' offers a copyable sudo line",
                  Privileged.terminalEquivalent(c).hasPrefix("sudo /"))
        }
        // Path validation is the whole safety story for the parameterised commands.
        let good = "/Library/LaunchDaemons/com.apple.xcscontrol.plist"
        check("accepts a real system launch plist", Privileged.isVettedLaunchPlist(good))
        for bad in [
            "/Library/LaunchDaemons/evil.plist; rm -rf /",
            "/Library/LaunchDaemons/../../etc/passwd.plist",
            "/Library/LaunchDaemons/a b.plist",
            "/Library/LaunchDaemons/$(whoami).plist",
            "/Library/LaunchDaemons/`id`.plist",
            "/Library/LaunchDaemons/x'.plist",
            "/tmp/evil.plist",
            "/Library/LaunchDaemons/sub/dir.plist",
            "/Library/LaunchDaemons/notaplist.txt",
            "/Users/x/Library/LaunchAgents/user.plist",
        ] {
            check("rejects \(bad)", !Privileged.isVettedLaunchPlist(bad))
        }
        check("a rejected path yields no Command at all",
              Privileged.disableLaunchItem(path: "/tmp/evil.plist; rm -rf /", label: "x") == nil)
        check("a vetted path yields a Command",
              Privileged.disableLaunchItem(path: good, label: "xcscontrol") != nil)
        check("disable is reversible by a restore command",
              Privileged.restoreLaunchItem(path: good, label: "xcscontrol") != nil)

        check("destructive Spotlight rebuild is rated risky",
              Privileged.rebuildSpotlight.note.risk == .risky)
        check("DNS flush is rated safe", Privileged.flushDNS.note.risk == .safe)
        return out
    }
}
