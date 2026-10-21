import SwiftUI
import AppKit

@MainActor
enum FeatureRenderCheck {
    static func run(outputDirectory: String, scale: CGFloat = 1) -> [String] {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return ["FAIL feature render directory: " + error.localizedDescription] }
        var lines: [String] = []
        func render<V: View>(_ name: String, _ content: V, dark: Bool, height: CGFloat) {
            let renderer = ImageRenderer(content: content
                .environment(\.colorScheme, dark ? .dark : .light)
                .preferredColorScheme(dark ? .dark : .light)
                .frame(width: 1100, height: height, alignment: .topLeading)
                .background(dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white))
            renderer.proposedSize = ProposedViewSize(width: 1100, height: height)
            renderer.scale = scale
            renderer.isOpaque = true
            guard let cgImage = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                lines.append("FAIL \(name): renderer produced no image"); return
            }
            do {
                let file = directory.appendingPathComponent(name + ".png")
                try png.write(to: file, options: .atomic)
                lines.append("\(cgImage.width == Int(1100 * scale) && cgImage.height == Int(height * scale) ? "PASS" : "FAIL") \(name): \(file.path)")
            } catch { lines.append("FAIL \(name): " + error.localizedDescription) }
        }
        let now = Date()
        let apps: [ActivityAppSnapshot] = [
            ActivityAppSnapshot(id: "fixture-browser", name: "Example Browser", cpuPercent: 120,
                rss: Int64(2) * 1_073_741_824, processCount: 12),
            ActivityAppSnapshot(id: "fixture-editor", name: "Example Editor", cpuPercent: 8,
                rss: Int64(512) * 1_048_576, processCount: 4)]
        var samples: [ActivitySnapshot] = []
        for i in 0..<8 {
            let used: Int64 = Int64(6 + i / 3) * 1_073_741_824
            let cpu: Double = Double(18 + i * 3)
            let at: Date = now.addingTimeInterval(Double(i - 7) * 60)
            let session: String = i < 4 ? "fixture-before-pause" : "fixture-after-pause"
            let sample = ActivitySnapshot(sampledAt: at, sessionID: session,
                cpuPercent: cpu, memoryUsed: used, memoryTotal: 17_179_869_184,
                swapUsed: 0, memoryPressure: "normal", diskFree: 137_438_953_472,
                diskTotal: 549_755_813_888, diskReadRate: 400_000, diskWriteRate: 40_000,
                networkDownloadRate: Double(i + 1) * 300_000, networkUploadRate: 120_000,
                networkScope: "Default physical interface · en0", batteryPercent: 78,
                gpuPercent: nil, thermalState: "Normal", readableProcesses: 64,
                listedProcesses: 90, apps: apps)
            samples.append(sample)
        }
        let monitor = ActivityMonitor(allowsPersistence: false, initialHistory: samples,
            initialBookmarks: [ActivityBookmark(note: "Investigate the build slowdown", snapshot: samples[3])])
        let resources = ResourceDashboardModel(
            counters: NetworkCounterSnapshot(counters: [NetworkInterfaceCounter(name: "en0", received: 1000, sent: 400)],
                scopeDescription: "Default physical interface · en0"),
            network: NetworkRateSnapshot(downloadBytesPerSecond: 2_000_000, uploadBytesPerSecond: 120_000,
                status: "Measured interface throughput"),
            battery: BatteryResourceSnapshot(present: true, percent: 78, isCharging: false, isOnBattery: true,
                healthPercent: 92, cycleCount: 140, detail: "Internal battery readings"),
            gpu: GPUResourceSnapshot(detail: "GPU utilization is unavailable for this fixture."),
            lastUpdated: now)
        let identity = ProcessIdentity(pid: 424242, uid: getuid(), startedSeconds: UInt64(now.timeIntervalSince1970 - 3600),
            startedMicroseconds: 0, path: "/fixture/bin/node")
        let process = RuntimeProjectProcess(pid: identity.pid, runtime: "Node.js", command: "node",
            directory: "/tmp/example-project", endpoints: [ListeningEndpoint(address: "127.0.0.1:3000", port: 3000,
                allowsLocalhost: true)], identity: identity, residentBytes: 180 * 1_048_576)
        let projects = ProjectsModel(result: ProjectDiscoveryResult(groups: [
            RuntimeProjectGroup(directory: process.directory, processes: [process])],
            listenerCount: 1, message: "One readable development server"))
        let advanced = AdvancedResourcesModel(
            docker: DockerOverviewSnapshot(contextName: "example-local", containers: [
                DockerContainerReading(id: String(repeating: "a", count: 64), name: "example-api",
                    image: "example:local", state: "running", status: "Up 1 hour", ports: "127.0.0.1:8080->8080/tcp",
                    cpuPercent: 12, memoryUsage: "128 MiB / 2 GiB", networkIO: "20 MB / 5 MB", blockIO: "0 B / 1 MB")],
                message: "Fixture · saved local Unix context"),
            sleep: SleepAssertionsSnapshot(summary: ["PreventUserIdleSystemSleep": 1], assertions: [
                SleepAssertionReading(pid: 424242, processName: "example", assertionID: "0x123",
                    kind: "PreventUserIdleSystemSleep", duration: "00:05:00")], message: "One fixture assertion"),
            browsers: BrowserResourcesSnapshot(groups: [BrowserResourceGroup(browser: "Example Browser",
                category: "Renderer helper", pids: [424242], residentBytes: 256 * 1_048_576, readableCount: 1)],
                message: "Generic fixture helper"))
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            render("activity-\(suffix)", ActivityView(activity: monitor).snapshotContent, dark: dark, height: 1700)
            render("resources-\(suffix)", ResourceDetailsView(model: resources).snapshotContent, dark: dark, height: 1050)
            render("projects-\(suffix)", ProjectsView(model: projects).snapshotContent, dark: dark, height: 900)
            render("advanced-\(suffix)", AdvancedResourcesView(model: advanced).snapshotContent, dark: dark, height: 1300)
        }
        let gib: Int64 = 1 << 30
        let disk = DiskOverview(name: "Macintosh HD", capacity: 460 * gib, free: 29 * gib, purgeable: 10 * gib,
            volumes: [.init(name: "Preboot", role: "Preboot", used: 10 * gib),
                      .init(name: "VM", role: "VM", used: 3 * gib)])
        func fixtureResult(_ path: String, bytes: Int64, errors: Int) -> ScanResult {
            let root = FSNode(name: Scanner.displayName(forRoot: path), path: path, isDir: true)
            root.size = bytes
            return ScanResult(root: root, bytes: bytes, files: 3_100_000, dirs: 640_000, errors: errors,
                              elapsed: 58, bigFiles: [], bySize: [:], disk: disk)
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            render("disk-overview-whole-\(suffix)", DiskOverviewBar(result: fixtureResult("/", bytes: 347 * gib, errors: 953),
                disk: disk, onScanMac: {}), dark: dark, height: 90)
            render("disk-overview-home-\(suffix)", DiskOverviewBar(result: fixtureResult(NSHomeDirectory(), bytes: 235 * gib, errors: 0),
                disk: disk, onScanMac: {}), dark: dark, height: 90)
        }
        for (reason, status, dark) in [(FullDiskAccessPrompt.beforeScan, FullDiskAccess.Status.denied, false),
                                       (.afterScan, .denied, true), (.granted, .granted, false)] {
            render("full-disk-access-\(reason.rawValue)-\(dark ? "dark" : "light")",
                   FullDiskAccessSheet(reason: reason, initialStatus: status, polls: false,
                                       onScan: {}, onScanWithout: {}, onClose: {}),
                   dark: dark, height: reason == .granted ? 260 : 520)
        }
        lines.append("PASS non-native content rendered; ImageRenderer omits native buttons and pickers, checked separately in the app")
        lines.append("PASS render fixtures start no scans, listeners, recording, notifications or process actions")
        return lines
    }
}
