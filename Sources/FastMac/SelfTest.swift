import Foundation

/// Verifies the bits that are easy to get quietly wrong: the safety guard, and the
/// arithmetic that keeps the map honest after something is deleted.
enum SelfTest {
    private static var failures = 0

    private static func check(_ label: String, _ got: Any, _ want: Any) {
        let ok = "\(got)" == "\(want)"
        if !ok { failures += 1 }
        print("  \(ok ? "PASS" : "FAIL")  \(label): got \(got), want \(want)")
    }

    static func run() {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "fastmac-selftest-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }

        // A tree with known, block-aligned contents.
        //   base/a/big.bin    4 MB
        //   base/a/deep/x.bin 1 MB
        //   base/b/small.bin  1 MB
        for d in ["/a/deep", "/b"] {
            try? fm.createDirectory(atPath: base + d, withIntermediateDirectories: true)
        }
        func write(_ path: String, mb: Int) {
            fm.createFile(atPath: path, contents: Data(count: mb << 20))
        }
        write(base + "/a/big.bin", mb: 4)
        write(base + "/a/deep/x.bin", mb: 1)
        write(base + "/b/small.bin", mb: 1)

        print("\nSAFETY GUARD")
        let home = NSHomeDirectory()
        for (path, shouldAllow) in [
            (home, false), (home + "/Documents", false), (home + "/Library", false),
            ("/System/Library", false), ("/usr/bin", false), ("/", false),
            ("/etc/passwd", false), (home + "/../../tmp", false),
            ("/Applications", false),
            (home + "/.Trash", false), (home + "/.Trash/item", false),
            ("/Volumes/Preboot", false),
            (home + "/Library/Caches/whatever", true),
            ("/Applications/Some.app", true),
        ] {
            let got = Safety.canDelete(path).ok
            check("\(got == shouldAllow ? "" : "")\(path)", got, shouldAllow)
        }

        print("\nSCAN")
        let store = ScanProbe()
        let r = store.scan(base)
        let mb: Int64 = 1 << 20
        check("total files", r.files, 3)
        check("root size >= 6 MB", r.bytes >= 6 * mb, true)
        let a = r.root.children.first { $0.name == "a" }
        let b = r.root.children.first { $0.name == "b" }
        check("a exists", a != nil, true)
        check("a holds 5 MB", (a?.size ?? 0) >= 5 * mb && (a?.size ?? 0) < 6 * mb, true)
        check("a counts 2 files", a?.files ?? -1, 2)
        check("a counts 1 subdir", a?.dirs ?? -1, 1)

        print("\nPRUNE — remove a/deep (a directory node)")
        let rootBefore = r.root.size
        let aBefore = a!.size
        let deep = a!.children.first { $0.name == "deep" }!
        let deepSize = deep.size

        // The same arithmetic AppStore.pruneFromTree performs.
        var n: FSNode? = a
        while let cur = n {
            cur.size -= deep.size; cur.logical -= deep.logical
            cur.files -= deep.files; cur.dirs -= (deep.dirs + 1)
            n = cur.parent
        }
        a!.children.removeAll { $0 === deep }

        check("a shrank by deep's size", a!.size, aBefore - deepSize)
        check("root shrank by deep's size", r.root.size, rootBefore - deepSize)
        check("a now counts 1 file", a!.files, 1)
        check("a now counts 0 subdirs", a!.dirs, 0)
        check("deep is gone from a", a!.children.contains { $0.name == "deep" }, false)
        check("root total still equals a+b",
              r.root.size, a!.size + (b?.size ?? 0))

        print("\nPRUNE — remove b/small.bin (a file, which has no node)")
        let rootBefore2 = r.root.size
        let bBefore = b!.size
        let fileSize: Int64 = 1 << 20
        var m: FSNode? = b
        while let cur = m {
            cur.size -= fileSize; cur.files -= 1; m = cur.parent
        }
        check("b shrank by the file", b!.size, bBefore - fileSize)
        check("root shrank by the file", r.root.size, rootBefore2 - fileSize)
        check("b now counts 0 files", b!.files, 0)

        print("\nMEMORY")
        let mem = MemoryProbe.sample()
        check("physical RAM reported", mem.total > 0, true)
        check("used <= total", mem.used <= mem.total + (1 << 30), true)
        check("pressure in 0…100", mem.pressure >= 0 && mem.pressure <= 100, true)
        check("processes found", MemoryProbe.processes(limit: 3).count > 0, true)

        print(failures == 0 ? "\nALL PASS\n" : "\n\(failures) FAILED\n")
        if failures > 0 { exit(1) }
    }
}

/// Thin wrapper so the test can scan without touching AppStore's main-actor state.
private final class ScanProbe {
    func scan(_ path: String) -> ScanResult {
        Scanner(progress: ScanProgress()).scan(root: path)
    }
}
