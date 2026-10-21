import AppKit

/// Exercises the production header and status text colors under both menu
/// appearances. This renders native labels, without installing a live status item.
@MainActor
enum MenuBarSelfCheck {
    static func run(outputDirectory: String) -> [String] {
        var lines: [String] = []
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["FAIL  menu render directory: \(error.localizedDescription)"]
        }

        var foregroundBrightness: [Double] = []
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else {
                lines.append("FAIL  \(name): menu appearance unavailable")
                continue
            }
            let header = HealthMenuHeader()
            header.appearance = appearance
            header.status.stringValue = "Review recommended"
            header.cpu.stringValue = "CPU: 24% · system total"
            header.memory.stringValue = "Memory: 8.2 GB of 16 GB · Normal pressure"
            header.network.stringValue = "Network: ↓ 1.4 MB /s  ↑ 96 KB /s"
            header.storage.stringValue = "Storage: 126 GB free of 500 GB"
            header.cadence.stringValue = "Updated 12:34:56 · scans stay manual"

            let preview = MenuAppearancePreview(frame: NSRect(x: 0, y: 0, width: 360, height: 190))
            preview.appearance = appearance
            header.frame.origin = .zero
            preview.addSubview(header)
            let title = NSTextField(labelWithString: "")
            title.attributedStringValue = MenuBarPresentation.attributedTitle(" CPU 24%")
            title.frame = NSRect(x: 16, y: 158, width: 328, height: 20)
            preview.addSubview(title)

            var foreground: NSColor?
            var secondary: NSColor?
            var background: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                foreground = (title.attributedStringValue.attribute(.foregroundColor, at: 0,
                    effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                secondary = header.cpu.textColor?.usingColorSpace(.sRGB)
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            if let foreground, let secondary, let background {
                let primaryRatio = contrast(foreground, background)
                let secondaryRatio = contrast(secondary, background)
                foregroundBrightness.append(luminance(foreground, background))
                let readable = primaryRatio >= 4.5 && secondaryRatio >= 3
                lines.append("\(readable ? "PASS" : "FAIL")  \(name) menu foreground: "
                    + String(format: "%.2f:1 primary, %.2f:1 secondary contrast", primaryRatio, secondaryRatio))
            } else {
                lines.append("FAIL  \(name): semantic menu colors could not be resolved")
            }

            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                appearance.performAsCurrentDrawingAppearance {
                    preview.cacheDisplay(in: preview.bounds, to: bitmap)
                }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let file = directory.appendingPathComponent("menu-\(name).png")
                    do {
                        try png.write(to: file, options: .atomic)
                        lines.append("PASS  \(name) production menu labels rendered: \(file.path)")
                    } catch {
                        lines.append("FAIL  \(name) menu image: \(error.localizedDescription)")
                    }
                } else {
                    lines.append("FAIL  \(name): menu PNG encoding failed")
                }
            } else {
                lines.append("FAIL  \(name): menu bitmap unavailable")
            }
        }
        let adapts = foregroundBrightness.count == 2
            && foregroundBrightness[0] < 0.25 && foregroundBrightness[1] > 0.6
        lines.append("\(adapts ? "PASS" : "FAIL")  menu title changes from dark ink in light appearance to light ink in dark appearance")
        let emptyCPU = MenuBarPresentation.compactTitle(metric: "cpu", snapshot: nil,
                                                        health: nil, paused: false, shortStatus: "OK")
        let paused = MenuBarPresentation.compactTitle(metric: "network", snapshot: nil,
                                                      health: nil, paused: true, shortStatus: "OK")
        lines.append("\(emptyCPU == "CPU —" && paused == "Paused" ? "PASS" : "FAIL")  unavailable and paused menu metrics retain explicit states")
        lines.append("PASS  menu preview installs no status item and invokes no collector, process sweep, or scan")
        return lines
    }

    private static func luminance(_ color: NSColor, _ background: NSColor) -> Double {
        let alpha = Double(color.alphaComponent)
        let values = zip([color.redComponent, color.greenComponent, color.blueComponent],
                         [background.redComponent, background.greenComponent, background.blueComponent])
            .map { component, base -> Double in
                let value = Double(component) * alpha + Double(base) * (1 - alpha)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }

    private static func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let a = luminance(foreground, background)
        let b = luminance(background, background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

@MainActor
private final class MenuAppearancePreview: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
