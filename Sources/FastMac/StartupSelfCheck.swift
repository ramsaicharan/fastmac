import Foundation
import Darwin

/// Exercises the parsing/classification logic against fixture plists, then runs one real,
/// read-only scan against this machine's actual LaunchAgents/LaunchDaemons so the numbers
/// in the report are genuine. Never touches a real user LaunchAgent's loaded state —
/// the only StartupService call that could (`setEnabled` with `enabled:` on a user agent)
/// is deliberately not exercised here; only its no-op refusal path (for a root-owned
/// item, which returns before running any command) is checked.
enum StartupSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        func info(_ text: String) { lines.append("INFO  \(text)") }

        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "fastmac-startup-selftest-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }

        // MARK: plist parsing

        func writePlist(_ name: String, _ dict: [String: Any]) -> String {
            let path = base + "/" + name
            let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            fm.createFile(atPath: path, contents: data)
            return path
        }

        do {
            let path = writePlist("well-formed.plist", [
                "Label": "com.example.wellformed",
                "ProgramArguments": ["/bin/echo", "hi"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StartInterval": 1800,
            ])
            let item = StartupService.parsePlist(path: path, domain: .userAgent)
            check("parses Label", item.label == "com.example.wellformed", item.label)
            check("parses RunAtLoad", item.runAtLoad == true)
            check("parses KeepAlive (bool form)", item.keepAlive == true)
            check("parses StartInterval", item.startInterval == 1800, "\(item.startInterval ?? -1)")
            check("resolves program from ProgramArguments[0]", item.programPath == "/bin/echo", item.programPath ?? "nil")
            check("binary that exists is not an orphan", item.isOrphanBinary == false)
            check("not a stub", item.isStub == false)
            check("readable", item.unreadable == false)
        }

        do {
            let path = writePlist("keepalive-dict.plist", [
                "Label": "com.example.keepalivedict",
                "Program": "/usr/bin/true",
                "KeepAlive": ["SuccessfulExit": false],
            ])
            let item = StartupService.parsePlist(path: path, domain: .userAgent)
            check("KeepAlive dict form counts as true", item.keepAlive == true)
            check("Program key resolves over ProgramArguments", item.programPath == "/usr/bin/true")
        }

        do {
            let path = writePlist("orphan.plist", [
                "Label": "com.example.orphan",
                "ProgramArguments": ["/opt/does/not/exist/on/this/mac"],
                "RunAtLoad": true,
            ])
            let item = StartupService.parsePlist(path: path, domain: .globalAgent)
            check("missing binary detected as orphan", item.isOrphanBinary == true)
            check("orphan surfaces through isOrphan", item.isOrphan == true)
            let rating = Impact.rate(item)
            check("orphan rated Low", rating.level == .low, rating.level.rawValue)
            check("orphan reason names the missing binary", rating.reason.contains("no longer exists"), rating.reason)
        }

        do {
            let binary = base + "/fixture-binary"
            fm.createFile(atPath: binary, contents: Data())
            let path = writePlist("cached-binary.plist", ["Program": binary])
            let before = StartupService.parsePlist(path: path, domain: .userAgent)
            try? fm.removeItem(atPath: binary)
            check("rendered orphan state stays a scan snapshot", !before.isOrphanBinary)
            let after = StartupService.parsePlist(path: path, domain: .userAgent)
            check("rescan detects a newly missing binary", after.isOrphanBinary)
            check("bulk review keeps a still-missing unchanged program",
                  StartupService.revalidatedOrphans([after]).count == 1)
            fm.createFile(atPath: binary, contents: Data())
            check("bulk review skips a program restored after scanning",
                  StartupService.revalidatedOrphans([after]).isEmpty)
            _ = writePlist("cached-binary.plist", ["Program": base + "/different-missing-binary"])
            check("bulk review skips a changed job even if its new program is missing",
                  StartupService.revalidatedOrphans([after]).isEmpty)
            let relative = writePlist("relative-binary.plist", ["Program": "fixture-tool"])
            check("unresolved relative program is not declared missing",
                  !StartupService.parsePlist(path: relative, domain: .userAgent).isOrphanBinary)
        }

        do {
            // Mirrors the real ~/Library/LaunchAgents/com.google.keystone.agent.plist on
            // this machine: an empty dict, content-free stub.
            let path = writePlist("stub.plist", [:])
            let item = StartupService.parsePlist(path: path, domain: .userAgent)
            check("empty dict has no program", item.programPath == nil)
            check("empty dict detected as stub", item.isStub == true)
            check("stub surfaces through isOrphan", item.isOrphan == true)
            let rating = Impact.rate(item)
            check("stub rated Low", rating.level == .low, rating.level.rawValue)
        }

        do {
            let path = base + "/garbage.plist"
            fm.createFile(atPath: path, contents: Data([0x00, 0x01, 0xFF, 0x22]))
            let item = StartupService.parsePlist(path: path, domain: .userAgent)
            check("malformed plist marked unreadable", item.unreadable == true)
            let rating = Impact.rate(item)
            check("unreadable rated Low, not silently High", rating.level == .low)
        }

        do {
            let path = writePlist("perm-denied.plist", ["Label": "com.example.locked"])
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            let item = StartupService.parsePlist(path: path, domain: .daemon)
            check("unreadable (permission-denied) file detected", item.unreadable == true)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) // so cleanup can remove it
        }

        // MARK: impact classification

        do {
            var item = StartupService.parsePlist(
                path: writePlist("high.plist", [
                    "Label": "com.example.high", "Program": "/bin/echo",
                    "RunAtLoad": true, "KeepAlive": true,
                ]), domain: .userAgent)
            item.isLoaded = true
            item.pid = 999
            let r = Impact.rate(item)
            check("RunAtLoad+KeepAlive+loaded rates High", r.level == .high, r.level.rawValue)
            check("High reason cites RunAtLoad", r.reason.contains("RunAtLoad"), r.reason)
            check("High reason cites KeepAlive", r.reason.contains("KeepAlive"), r.reason)
            check("High reason cites the PID", r.reason.contains("999"), r.reason)
        }

        do {
            let item = StartupService.parsePlist(
                path: writePlist("dormant.plist", [
                    "Label": "com.example.dormant", "Program": "/bin/echo",
                ]), domain: .userAgent)
            let r = Impact.rate(item)
            check("no RunAtLoad, not loaded rates Low", r.level == .low, r.level.rawValue)
            check("Low reason explains why", r.reason.contains("not set to run"), r.reason)
        }

        do {
            let item = StartupService.parsePlist(
                path: writePlist("disabled.plist", [
                    "Label": "com.example.disabled", "Program": "/bin/echo",
                    "RunAtLoad": true, "Disabled": true,
                ]), domain: .userAgent)
            let r = Impact.rate(item)
            check("legacy Disabled key forces Low regardless of RunAtLoad", r.level == .low, r.level.rawValue)
        }

        // MARK: attribution

        check("attributes an .app bundle path to its app name",
              Attribution.owner(label: "com.foo.helper",
                                 programPath: "/Applications/Neat Tool.app/Contents/MacOS/Neat Tool")
                == "Neat Tool")
        check("attributes a homebrew formula from its Cellar path",
              Attribution.owner(label: "irrelevant",
                                 programPath: "/opt/homebrew/Cellar/ollama/0.1.0/bin/ollama")
                == "Homebrew (ollama)")
        check("attributes a homebrew.mxcl label with no path",
              Attribution.owner(label: "homebrew.mxcl.postgresql", programPath: nil)
                == "Homebrew (postgresql)")
        check("attributes a known vendor from the label's reverse-DNS segment",
              Attribution.owner(label: "com.google.keystone.agent", programPath: nil) == "Google")
        check("falls back to a capitalized vendor segment for unknown labels",
              Attribution.owner(label: "com.frobnicate.thing", programPath: nil) == "Frobnicate")

        // MARK: launchctl targeting (string formatting only — nothing is invoked)

        check("user/global agents target the gui domain",
              StartupDomain.userAgent.target(uid: 501, label: "com.x.y") == "gui/501/com.x.y")
        check("daemons target the system domain",
              StartupDomain.daemon.target(uid: 501, label: "com.x.y") == "system/com.x.y")
        check("only userAgent is editable without root",
              StartupDomain.userAgent.editableWithoutRoot && !StartupDomain.globalAgent.editableWithoutRoot
                && !StartupDomain.daemon.editableWithoutRoot)

        // MARK: action refusal path — the one live StartupService call this check makes.
        // It returns before touching launchctl at all, so it is safe to actually invoke.

        do {
            let rootItem = StartupService.parsePlist(
                path: writePlist("root-owned.plist", [
                    "Label": "com.example.rootowned", "Program": "/bin/echo",
                ]), domain: .daemon)
            let outcome = MainActor.assumeIsolated {
                StartupService().setEnabled(rootItem, enabled: true)
            }
            if case .refused(let message) = outcome {
                check("refuses to touch a root-owned daemon", true)
                check("refusal explains why, mentions admin rights", message.contains("administrator"), message)
            } else {
                check("refuses to touch a root-owned daemon", false, "did not refuse")
            }
        }

        // MARK: CPU time sanity, against our own live process

        if let cpu = StartupService.cpuSeconds(pid: getpid()) {
            check("own process CPU time is non-negative and plausible", cpu >= 0 && cpu < 3600, String(format: "%.3f", cpu))
        } else {
            check("could read own process CPU time via PROC_PIDTASKINFO", false)
        }

        // MARK: the real thing — one live, read-only scan of this machine

        let uid = getuid()
        let items = StartupService.performScan(uid: uid)
        check("live scan never touches /System", items.allSatisfy { !$0.plistPath.hasPrefix("/System") })
        check("live scan gives every item a non-empty label", items.allSatisfy { !$0.label.isEmpty })
        check("live scan gives every item a non-empty owner", items.allSatisfy { !$0.owner.isEmpty })

        let orphans = items.filter(\.isOrphan)
        let high = items.filter { Impact.rate($0).level == .high }
        let medium = items.filter { Impact.rate($0).level == .medium }
        let running = items.filter(\.isLoaded)
        let unreadable = items.filter(\.unreadable)

        info("live scan: \(items.count) launch items found "
             + "(\(items.filter { $0.domain == .userAgent }.count) user agent, "
             + "\(items.filter { $0.domain == .globalAgent }.count) global agent, "
             + "\(items.filter { $0.domain == .daemon }.count) daemon)")
        info("live scan: \(orphans.count) orphaned (dead binary or empty stub)")
        info("live scan: \(high.count) High impact, \(medium.count) Medium, "
             + "\(items.count - high.count - medium.count) Low")
        info("live scan: \(running.count) currently loaded/running, \(unreadable.count) unreadable (permissions)")
        for item in high {
            let r = Impact.rate(item)
            info("  HIGH  \(item.owner) — \(item.label) [\(item.domain.title)]: \(r.reason)")
        }
        for item in orphans.prefix(10) {
            info("  ORPHAN  \(item.owner) — \(item.label) [\(item.domain.title)] \(item.plistPath)")
        }

        let failures = lines.filter { $0.hasPrefix("FAIL") }.count
        lines.append(failures == 0 ? "ALL PASS (\(lines.filter { $0.hasPrefix("PASS") }.count) checks)"
                                    : "\(failures) FAILED")
        return lines
    }
}
