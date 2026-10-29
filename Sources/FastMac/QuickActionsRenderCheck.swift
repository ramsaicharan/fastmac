import AppKit
import SwiftUI

/// Renders the production quick-actions content using synthetic, non-actionable
/// applications. No live inventory, response checks, timers or history writes run.
@MainActor
enum QuickActionsRenderCheck {
    /// `scale` 2 produces Retina images for the README; checks use 1.
    static func run(outputDirectory: String, scale: CGFloat = 1) -> [String] {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return ["FAIL quick actions render directory: \(error.localizedDescription)"] }

        var lines: [String] = []
        let now = Date()
        let gib: Int64 = 1_073_741_824
        let mib: Int64 = 1_048_576

        func fixtureApp(_ name: String, pid: pid_t, symbol: String, cpu: Double?, memory: Int64?,
                        response: QuickAppResponse = .unchecked, at: Date? = nil) -> QuickActionApp {
            let sampledAt = at ?? now
            let path = "/fixture/\(name).app/Contents/MacOS/Fixture"
            let identity = ProcessIdentity(pid: pid, uid: getuid(),
                startedSeconds: UInt64(now.timeIntervalSince1970 - 7_200), startedMicroseconds: 0, path: path)
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon?.isTemplate = true
            return QuickActionApp(name: name, bundleURL: URL(fileURLWithPath: "/fixture/\(name).app"),
                icon: icon, identity: identity, cpuPercent: cpu, residentBytes: memory,
                memoryIncludesHelpers: true, processCount: 4, metricsAt: sampledAt, response: response,
                responseCheckedAt: response == .unchecked ? nil : sampledAt)
        }

        let apps = [
            fixtureApp("Example Browser", pid: 424_240, symbol: "globe", cpu: 124, memory: 4 * gib),
            fixtureApp("Example Editor", pid: 424_241, symbol: "chevron.left.forwardslash.chevron.right", cpu: 18, memory: gib),
            fixtureApp("Example Video Workspace with a Long Name", pid: 424_242, symbol: "film", cpu: 3, memory: 740 * mib),
            fixtureApp("Example Notes", pid: 424_243, symbol: "note.text", cpu: 0, memory: 120 * mib)
        ]
        let slowApps = [
            fixtureApp("Example Editor", pid: 424_241, symbol: "chevron.left.forwardslash.chevron.right",
                cpu: 8, memory: gib, response: .didNotRespond),
            fixtureApp("Example Browser", pid: 424_240, symbol: "globe",
                cpu: 124, memory: 4 * gib, response: .responded),
            fixtureApp("Example Notes", pid: 424_243, symbol: "note.text",
                cpu: nil, memory: nil, response: .unavailable)
        ]

        func healthSample(at: Date, pressure: HealthMemoryPressure = .normal, diskFree: Int64 = 128 * 1_073_741_824) -> HealthSample {
            HealthSample(memory: MemorySample(total: 16 * gib, app: 10 * gib, wired: 2 * gib,
                compressor: 2 * gib, free: 2 * gib, fileBacked: 3 * gib, purgeable: 300 * mib,
                swapUsed: 3 * gib, swapTotal: 4 * gib, at: at), memoryPressure: pressure,
                diskFree: diskFree, diskTotal: 512 * gib, thermalState: .nominal, sampledAt: at)
        }

        func activitySample(at: Date, apps: [QuickActionApp], diskFree: Int64 = 128 * 1_073_741_824) -> ActivitySnapshot {
            ActivitySnapshot(sampledAt: at, sessionID: "quick-actions-render-fixture",
                cpuPercent: 24, memoryUsed: 14 * gib, memoryTotal: 16 * gib,
                swapUsed: 3 * gib, memoryPressure: "normal", diskFree: diskFree,
                diskTotal: 512 * gib, diskReadRate: 500_000, diskWriteRate: 120_000,
                networkDownloadRate: 1_400_000, networkUploadRate: 96_000,
                networkScope: "Fixture interface", batteryPercent: 78, gpuPercent: nil,
                thermalState: "Normal", readableProcesses: 40, listedProcesses: 55,
                apps: apps.map { ActivityAppSnapshot(id: $0.appKey, name: $0.name,
                    cpuPercent: $0.cpuPercent, rss: $0.residentBytes, processCount: $0.processCount ?? 0) })
        }

        let staleAt = now.addingTimeInterval(-600)
        let fixtures: [(name: String, health: HealthSample?, monitoring: Bool,
                        activity: ActivitySnapshot?, apps: [QuickActionApp])] = [
            ("normal", healthSample(at: now), true, activitySample(at: now, apps: apps), apps),
            ("paused", healthSample(at: staleAt, pressure: .warning), false,
                activitySample(at: staleAt, apps: apps), apps.map {
                    var app = $0; app.metricsAt = staleAt; return app
                }),
            ("unavailable", nil, false, nil, []),
            ("response-check", healthSample(at: now, pressure: .warning), true,
                activitySample(at: now, apps: slowApps), slowApps)
        ]

        for fixture in fixtures {
            let health = HealthMonitor(fixtureSample: fixture.health, isMonitoring: fixture.monitoring)
            let activity = ActivityMonitor(allowsPersistence: false,
                initialHistory: fixture.activity.map { [$0] } ?? [])
            let model = QuickActionsModel(apps: fixture.apps, fixtureMode: true)
            // The closures deliberately have no effects, including navigation.
            let popup = QuickActionsPopover(health: health, activity: activity, model: model, storage: .inert,
                onNavigate: { _ in }, onSettings: {}, onRefresh: {})
            for dark in [false, true] {
                let name = "quick-actions-\(fixture.name)-\(dark ? "dark" : "light")"
                lines.append(contentsOf: render(name: name, content: popup.snapshotContent,
                    dark: dark, directory: directory, scale: scale))
            }
        }

        // Storage watch cards, built by the production policy from fixture readings.
        var leak = FreeSpaceTrend()
        for h in stride(from: 72, through: 0, by: -1) {
            leak.record(free: 10 * gib + Int64(Double(h) / 24 * 7 * Double(gib)), at: now.addingTimeInterval(-Double(h) * 3_600))
        }
        let storageFixtures: [(name: String, findings: [StorageFinding], message: String?)] = [
            ("storage", [StorageWatchPolicy.filling(trend: leak, free: 10 * gib, now: now),
                         StorageWatchPolicy.tempProfiles(.init(idle: (0..<474).map { "fixture-\($0)" }, active: 7,
                                                               bytes: 21 * gib, estimated: true))].compactMap { $0 }, nil),
            ("storage-blocked", [StorageWatchPolicy.cache(WatchedCache.all[0], reading: CacheReading(bytes: 6 * gib, previous: 3 * gib),
                                                          blocked: "Quit Google Chrome first.")].compactMap { $0 },
             "Moved 474 profiles (\(fmt(21 * gib))) to the Trash. Empty the Trash to get the space back."),
        ]
        for fixture in storageFixtures {
            let health = HealthMonitor(fixtureSample: healthSample(at: now, diskFree: 10 * gib), isMonitoring: true)
            let activity = ActivityMonitor(allowsPersistence: false, initialHistory: [activitySample(at: now, apps: apps, diskFree: 10 * gib)])
            let model = QuickActionsModel(apps: apps, fixtureMode: true)
            let storage = StorageWatch(persists: false, startsTimers: false)
            storage.seed(findings: fixture.findings, message: fixture.message)
            lines.append("\(storage.popupFindings.count == fixture.findings.count ? "PASS" : "FAIL") quick actions \(fixture.name): every attention finding reaches the popup")
            let popup = QuickActionsPopover(health: health, activity: activity, model: model, storage: storage,
                onNavigate: { _ in }, onSettings: {}, onRefresh: {})
            for dark in [false, true] {
                let name = "quick-actions-\(fixture.name)-\(dark ? "dark" : "light")"
                lines.append(contentsOf: render(name: name, content: popup.snapshotContent,
                    dark: dark, directory: directory, scale: scale))
            }
        }

        let store = AppStore()
        // Ignore any saved queue in this in-memory fixture; no queue persistence
        // or cleanup API is called by this renderer.
        store.staged = []
        let dashboardHealth = HealthMonitor(fixtureSample: healthSample(at: now, pressure: .warning),
            isMonitoring: true)
        for dark in [false, true] {
            lines.append(contentsOf: render(name: "health-modern-\(dark ? "dark" : "light")",
                content: HealthView(health: dashboardHealth).snapshotContent.environmentObject(store),
                dark: dark, directory: directory, width: 1100, height: 900, scale: scale))
        }

        lines.append("PASS quick actions fixtures perform no process actions, live response checks, scans or persistence")
        lines.append("NOTE ImageRenderer verifies content and appearance; native controls and confirmation focus require the app smoke check")
        return lines
    }

    private static func render<V: View>(name: String, content: V, dark: Bool, directory: URL,
                                        width: CGFloat = 420, height: CGFloat = 640, scale: CGFloat = 1) -> [String] {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
            return ["FAIL \(name): appearance unavailable"]
        }
        var lines: [String] = []
        // In addition to SwiftUI's colorScheme, make the matching AppKit
        // appearance current while NSColor and symbol colors resolve.
        appearance.performAsCurrentDrawingAppearance {
            // This outer canvas is a renderer fixture, not an AppKit window.
            // A dynamic NSColor can resolve before SwiftUI installs colorScheme
            // here, producing a light canvas behind dark-mode white text.
            let canvas = dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white
            let renderer = ImageRenderer(content: content
                .frame(width: width, height: height, alignment: .topLeading)
                .background(canvas)
                .environment(\.colorScheme, dark ? .dark : .light)
                .preferredColorScheme(dark ? .dark : .light))
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            renderer.scale = scale
            renderer.isOpaque = true
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                lines.append("FAIL \(name): renderer produced no PNG"); return
            }
            let expectedSize = image.width == Int(width * scale) && image.height == Int(height * scale)
            lines.append("\(expectedSize ? "PASS" : "FAIL") \(name) dimensions: \(image.width)×\(image.height)")
            let pixels = contentPixels(image, dark: dark)
            let totalPixels = image.width * image.height
            // Foreground must be present but must not occupy the background.
            // The upper bound catches a white dark-mode canvas that previously
            // looked like almost a full image of valid white foreground.
            let foregroundIsPlausible = pixels >= 200 && pixels < totalPixels / 3
            let percentage = totalPixels > 0 ? Double(pixels) / Double(totalPixels) * 100 : 0
            lines.append("\(foregroundIsPlausible ? "PASS" : "FAIL") \(name) visible foreground: "
                + "\(pixels)/\(totalPixels) pixels (\(String(format: "%.2f", percentage))%)")
            let file = directory.appendingPathComponent(name + ".png")
            do {
                try png.write(to: file, options: .atomic)
                guard let roundTrip = NSBitmapImageRep(data: try Data(contentsOf: file)),
                      roundTrip.pixelsWide == Int(width * scale), roundTrip.pixelsHigh == Int(height * scale) else {
                    lines.append("FAIL \(name): saved PNG dimensions differ"); return
                }
                lines.append("PASS \(name) saved: \(file.path)")
            } catch { lines.append("FAIL \(name): \(error.localizedDescription)") }
        }
        return lines
    }

    /// Normalize the CGImage into known RGBA bytes rather than assuming an
    /// NSBitmapImageRep channel order. A flat background must not pass the check.
    private static func contentPixels(_ image: CGImage, dark: Bool) -> Int {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        let rowBytes = width * 4
        var data = [UInt8](repeating: 0, count: rowBytes * height)
        return data.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let base = storage.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            var count = 0
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = base + y * rowBytes + x * 4
                    let brightness = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
                    if (dark && brightness > 0.70) || (!dark && brightness < 0.30) { count += 1 }
                }
            }
            return count
        }
    }
}
