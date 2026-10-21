import Foundation

/// Whole-disk accounting: every byte lands in exactly one labelled part, and a
/// scan of "/" never walks the same volume twice.
enum DiskOverviewSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(name)") }
        let gib: Int64 = 1 << 30

        let disk = DiskOverview(name: "Fixture HD", capacity: 460 * gib, free: 29 * gib, purgeable: 10 * gib,
            volumes: [.init(name: "Macintosh HD", role: "System", used: 13 * gib),
                      .init(name: "Data", role: "Data", used: 404 * gib),
                      .init(name: "Preboot", role: "Preboot", used: 10 * gib),
                      .init(name: "Recovery", role: "Recovery", used: 1 * gib),
                      .init(name: "VM", role: "VM", used: 3 * gib)])

        let whole = disk.segments(scannedPath: "/", scannedBytes: 347 * gib)
        check("whole-disk parts add up to the disk capacity",
              whole.reduce(0) { $0 + $1.bytes } == disk.capacity)
        check("support volumes exclude the walkable System and Data volumes",
              whole.first { $0.kind == .macOSVolumes }?.bytes == 14 * gib)
        check("unread space is what the scan and support volumes leave of used space",
              whole.first { $0.kind == .unread }?.bytes == 431 * gib - 347 * gib - 14 * gib)

        let home = disk.segments(scannedPath: NSHomeDirectory(), scannedBytes: 235 * gib)
        check("folder scans show the rest of the disk instead of unread space",
              home.map(\.kind) == [.scanned, .elsewhere, .free]
              && home.reduce(0) { $0 + $1.bytes } == disk.capacity)

        let oversized = disk.segments(scannedPath: "/", scannedBytes: 900 * gib)
        check("a scan larger than used space (clones, hard links) never produces negative parts",
              oversized.allSatisfy { $0.bytes >= 0 } && oversized.reduce(0) { $0 + $1.bytes } == disk.capacity)

        let fixture = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array>
          <dict><key>ContainerReference</key><string>disk1</string><key>Volumes</key><array>
            <dict><key>Name</key><string>iSCPreboot</string><key>Roles</key><array><string>Preboot</string></array><key>CapacityInUse</key><integer>99</integer></dict>
          </array></dict>
          <dict><key>ContainerReference</key><string>disk3</string><key>Volumes</key><array>
            <dict><key>Name</key><string>Data</string><key>Roles</key><array><string>Data</string></array><key>CapacityInUse</key><integer>400</integer></dict>
            <dict><key>Name</key><string>VM</string><key>Roles</key><array><string>VM</string></array><key>CapacityInUse</key><integer>3</integer></dict>
          </array></dict>
        </array></dict></plist>
        """
        let parsed = DiskOverviewProbe.volumes(fromAPFSList: fixture, container: "disk3")
        check("diskutil output is read only for the startup container",
              parsed.map(\.name) == ["Data", "VM"] && parsed.map(\.used) == [400, 3])
        check("unparseable diskutil output yields no volumes rather than a guess",
              DiskOverviewProbe.volumes(fromAPFSList: "not a plist", container: "disk3").isEmpty)

        let rootExclusions = Scanner.exclusions(forRoot: "/")
        check("a whole-disk scan skips the data-volume mirror and other volumes",
              ["/System/Volumes", "/Volumes", "/dev"].allSatisfy(rootExclusions.contains)
              && !rootExclusions.contains("/") && !rootExclusions.contains("/Users"))
        check("refreshing /System keeps the data-volume mirror excluded",
              Scanner.exclusions(forRoot: "/System").contains("/System/Volumes"))
        check("an ordinary folder scan has no exclusions",
              Scanner.exclusions(forRoot: NSTemporaryDirectory() + "fastmac-fixture").isEmpty)
        check("the startup disk is named, not shown as a slash",
              Scanner.displayName(forRoot: "/") != "/" && !Scanner.displayName(forRoot: "/").isEmpty)

        // Build "/" → home path components → Library → Caches, as a whole-disk scan would.
        let root = FSNode(name: "Fixture HD", path: "/", isDir: true)
        var parent = root
        var path = ""
        for part in (NSHomeDirectory() + "/Library/Caches").split(separator: "/") {
            path += "/" + part
            let node = FSNode(name: String(part), path: path, isDir: true)
            node.parent = parent
            parent.children = [node]
            parent = node
        }
        parent.size = 64 << 20
        let wins = Analysis.quickWins(root: root)
        check("quick wins find home caches in a tree rooted at /",
              wins.contains { $0.label == "User caches" && $0.size == 64 << 20 })
        check("access is requested before a whole-disk scan only when known to be missing",
              FullDiskAccess.shouldPromptBeforeScan(status: .denied, skipped: false)
              && !FullDiskAccess.shouldPromptBeforeScan(status: .granted, skipped: false)
              && !FullDiskAccess.shouldPromptBeforeScan(status: .unknown, skipped: false))
        check("choosing to scan without access stops the pre-scan prompt",
              !FullDiskAccess.shouldPromptBeforeScan(status: .denied, skipped: true))
        let link = FullDiskAccess.systemSettingsURL.absoluteString
        check("the settings link opens Privacy & Security at Full Disk Access",
              link.hasPrefix("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
              && link.hasSuffix("?Privacy_AllFiles")
              && FullDiskAccess.legacySystemSettingsURL.absoluteString.hasSuffix("?Privacy_AllFiles"))
        return lines
    }
}
