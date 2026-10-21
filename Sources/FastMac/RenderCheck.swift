import SwiftUI

/// Renders views off-screen and reports whether they actually produced pixels.
///
/// "The tab is empty" is otherwise unfalsifiable without a display: the code compiles, the
/// data is present, and there is no crash — yet nothing appears. ImageRenderer gives a
/// headless answer to "did this view draw anything".
@MainActor
enum RenderCheck {
    static func run() -> [String] {
        var out: [String] = []

        func probe<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 900, height: 650)) {
            let renderer = ImageRenderer(content:
                view.frame(width: size.width, height: size.height)
                    .background(Color.white)
            )
            renderer.scale = 1
            guard let img = renderer.nsImage else {
                out.append("FAIL  \(name): renderer produced no image")
                return
            }
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                out.append("FAIL  \(name): no bitmap representation")
                return
            }
            // Scan every pixel via the raw buffer. Strided sampling silently missed
            // 1px antialiased glyph strokes, which made a perfectly good view read as
            // blank — the test was wrong, not the view.
            guard rep.bitsPerPixel % 8 == 0, let base = rep.bitmapData else {
                out.append("FAIL  \(name): no raw bitmap buffer")
                return
            }
            let w = rep.pixelsWide, h = rep.pixelsHigh
            let bpp = rep.bitsPerPixel / 8
            let rowBytes = rep.bytesPerRow
            var lit = 0
            for y in 0..<h {
                let row = base + y * rowBytes
                for x in 0..<w {
                    let px = row + x * bpp
                    // Rendered on white. ImageRenderer has no window appearance, so
                    // SwiftUI's default label colour resolves to black — on a black
                    // background that is invisible, which is what broke the earlier runs.
                    if px[0] < 239 || px[1] < 239 || px[2] < 239 { lit += 1 }
                }
            }
            let total = w * h
            let pct = total > 0 ? Double(lit) / Double(total) * 100 : 0
            let drew = lit > 200        // more than a stray antialiasing artefact
            out.append("\(drew ? "PASS" : "FAIL")  \(name): \(w)x\(h), "
                       + "\(lit)/\(total) px lit (" + String(format: "%.3f%%", pct) + ")")
        }

        // Controls, to separate "ForEach is broken under ImageRenderer" from
        // "this particular view is broken".
        probe("A. single Text", Text("hello world").font(.title))
        probe("B. VStack of 3 Text", VStack(alignment: .leading) {
            Text("alpha"); Text("beta"); Text("gamma")
        })
        probe("C. ForEach over 3 strings", VStack(alignment: .leading) {
            ForEach(["alpha", "beta", "gamma"], id: \.self) { Text($0) }
        })
        probe("D. ForEach over Privileged.all", VStack(alignment: .leading) {
            ForEach(Privileged.all, id: \.id) { Text($0.title) }
        })
        probe("E. ForEach over mapped titles", VStack(alignment: .leading) {
            ForEach(Privileged.all.map(\.title), id: \.self) { Text($0) }
        })
        probe("Administrator tab", PrivilegedActionsView())

        probe("Risk legend", RiskLegend(), size: CGSize(width: 600, height: 40))
        probe("Risk badge", RiskBadge(risk: .risky, note: .forceQuitProcess),
              size: CGSize(width: 200, height: 40))
        return out
    }
}
