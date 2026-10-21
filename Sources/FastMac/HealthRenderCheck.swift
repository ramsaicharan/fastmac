import SwiftUI
import AppKit

/// Exports the real SwiftUI views with an explicit appearance. Capturing an AppKit
/// backing layer via cacheDisplay can drop its alpha and invert otherwise valid text.
@MainActor
enum HealthRenderCheck {
    static func run(outputDirectory: String) -> [String] {
        var lines: [String] = []
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["FAIL  render directory: \(error.localizedDescription)"]
        }

        func render<V: View>(_ name: String, _ view: V, width: CGFloat = 1100, height: CGFloat = 900) {
            let renderer = ImageRenderer(content:
                view
                    .environment(\.colorScheme, .light)
                    .preferredColorScheme(.light)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .background(Color.white)
            )
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            renderer.scale = 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage else {
                lines.append("FAIL  \(name): renderer produced no image")
                return
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                lines.append("FAIL  \(name): PNG encoding failed")
                return
            }
            let file = directory.appendingPathComponent(name + ".png")
            do { try png.write(to: file, options: .atomic) }
            catch {
                lines.append("FAIL  \(name): PNG write failed: \(error.localizedDescription)")
                return
            }

            // Normalize the CGImage to RGBA instead of assuming NSBitmapImageRep's
            // channel order. Check for both colored regions and dark text strokes.
            let pixelWidth = image.width, pixelHeight = image.height
            let bufferSize = pixelWidth * pixelHeight * 4
            var pixels = [UInt8](repeating: 0, count: bufferSize)
            let statistics: (colored: Int, dark: Int)? = pixels.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress,
                      let context = CGContext(data: base, width: pixelWidth, height: pixelHeight,
                          bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                let raw = base.assumingMemoryBound(to: UInt8.self)
                var colored = 0, dark = 0
                for offset in stride(from: 0, to: bufferSize, by: 4) {
                    let red = raw[offset], green = raw[offset + 1], blue = raw[offset + 2]
                    if red < 239 || green < 239 || blue < 239 { colored += 1 }
                    if red < 96 && green < 96 && blue < 96 { dark += 1 }
                }
                return (colored, dark)
            }
            guard let statistics else {
                lines.append("FAIL  \(name): pixel inspection failed; saved \(file.path)")
                return
            }
            let correctDimensions = pixelWidth == Int(width * 2) && pixelHeight == Int(height * 2)
            let drewContent = statistics.colored > 1_000 && statistics.dark > 500
            lines.append("\(correctDimensions && drewContent ? "PASS" : "FAIL")  \(name): "
                         + "\(pixelWidth)×\(pixelHeight), \(statistics.colored) nonwhite pixels, "
                         + "\(statistics.dark) dark pixels; \(file.path)")
        }

        let store = AppStore()
        // Only this temporary store is altered. No stage/purge/persistence API runs.
        store.staged = []
        let monitor = HealthMonitor()
        monitor.refresh()
        defer { monitor.stop() }
        // macOS ScrollView itself is unsupported by ImageRenderer. Render the same
        // content production puts inside the scroll container, with no replacement UI.
        render("health-light", HealthView(health: monitor).snapshotContent.environmentObject(store), height: 1200)
        render("ai-storage-empty-light", AIStorageView(store: store, service: AIStorageService()))
        render("cleanup-empty-light", CleanupView(onPurge: {}).snapshotContent.environmentObject(store))

        let modelPath = directory.appendingPathComponent("preview-only-model").path
        store.staged = [StagedItem(path: modelPath, size: 6 * 1_073_741_824, isDir: true,
                                  reason: "AI Storage: reviewed local model; re-download needed")]
        render("cleanup-review-light", CleanupView(onPurge: {}).snapshotContent.environmentObject(store))
        lines.append("PASS  renders invoke no model scan, process sweep, cleanup, or queue persistence")
        return lines
    }
}
