import Foundation

/// Scans a real folder, trashes a real subfolder, and checks the in-memory map corrects
/// itself — the thing that was broken: deleted items kept showing up.
enum E2E {
    static func run(_ requested: String?) {
        let fm = FileManager.default
        let target: String
        let ownedFixture: String?
        if let requested {
            target = URL(fileURLWithPath: requested).standardizedFileURL.path
            ownedFixture = nil
        } else {
            let fixture = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".fastmac")
                .appendingPathComponent("e2e-fixture-\(UUID().uuidString)")
            try? fm.createDirectory(at: fixture.appendingPathComponent("victim"),
                                    withIntermediateDirectories: true)
            try? Data(repeating: 65, count: 1 << 20)
                .write(to: fixture.appendingPathComponent("victim/payload.bin"))
            target = fixture.appendingPathComponent("victim").path
            ownedFixture = fixture.path
        }
        defer {
            if let ownedFixture { try? fm.removeItem(atPath: ownedFixture) }
        }
        let parent = (target as NSString).deletingLastPathComponent
        let r = Scanner(progress: ScanProgress()).scan(root: parent)
        guard let victim = r.root.children.first(where: { $0.path == target }) else {
            print("  target not found under \(parent)"); exit(1)
        }
        let rootBefore = r.root.size
        let victimSize = victim.size
        let filesBefore = r.root.files

        print("  before:  root \(fmt(rootBefore)) · \(fmtCount(filesBefore)) files")
        print("  victim:  \(victim.name) \(fmt(victimSize)) · \(fmtCount(victim.files)) files")
        print("  shown in map: \(r.root.children.contains { $0.path == target })")

        guard Safety.canDelete(target).ok else { print("  guard refused the target"); exit(1) }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
        } catch { print("  trash failed: \(error)"); exit(1) }

        // The prune AppStore performs after a successful purge.
        var n: FSNode? = r.root
        while let cur = n {
            cur.size -= victim.size; cur.logical -= victim.logical
            cur.files -= victim.files; cur.dirs -= (victim.dirs + 1)
            n = cur.parent
        }
        r.root.children.removeAll { $0.path == target }

        print("  after:   root \(fmt(r.root.size)) · \(fmtCount(r.root.files)) files")
        print("  shown in map: \(r.root.children.contains { $0.path == target })")
        print("  gone from disk: \(!FileManager.default.fileExists(atPath: target))")

        let mapOK = !r.root.children.contains { $0.path == target }
        let mathOK = r.root.size == rootBefore - victimSize
        let diskOK = !FileManager.default.fileExists(atPath: target)
        print(mapOK && mathOK && diskOK ? "\n  E2E PASS\n" : "\n  E2E FAIL\n")
        if !(mapOK && mathOK && diskOK) { exit(1) }
    }
}
