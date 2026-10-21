import Foundation

/// Known transcript stores, including their ancestors, must not enter generic cleanup.
/// This is a path classification only; it never reads messages or credentials.
enum ConversationStorage {
    static func owner(of path: String, home: String = NSHomeDirectory(), includingAncestors: Bool = false) -> String? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        let roots = [
            (".codex/sessions", "Codex"), (".codex/archived_sessions", "Codex"),
            (".codex/history.jsonl", "Codex"), (".claude/projects", "Claude")
        ]
        for (relative, owner) in roots {
            let root = home + "/" + relative
            if path == root || path.hasPrefix(root + "/")
                || (includingAncestors && root.hasPrefix(path + "/")) { return owner }
        }
        return nil
    }
}
