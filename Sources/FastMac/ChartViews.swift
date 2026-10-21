import SwiftUI

// Shared interaction: click opens, ⌘/⇧-click selects.
private struct NodeTap: ViewModifier {
    let node: FSNode
    @EnvironmentObject var store: AppStore
    func body(content: Content) -> some View { content }
}

struct HoverInfo: Equatable {
    var text: String
    var at: CGPoint
}

// MARK: - Treemap

struct TreemapView: View {
    @EnvironmentObject var store: AppStore
    @State private var hover: HoverInfo?

    var body: some View {
        GeometryReader { geo in
            let kids = store.current?.children ?? []
            let tiles = Layout.treemap(kids, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for t in tiles where t.rect.width > 1.2 && t.rect.height > 1.2 {
                        let r = t.rect.insetBy(dx: 1, dy: 1)
                        let picked = store.isPicked(t.node.path)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3),
                                 with: .color(Layout.color(t.node.name, depth: 1)))
                        if picked {
                            ctx.stroke(Path(roundedRect: r, cornerRadius: 3),
                                       with: .color(.white), lineWidth: 2.5)
                        }
                        if r.width > 58 && r.height > 24 {
                            let ink: Color = Layout.isLight(depth: 1) ? .black : .white
                            ctx.draw(Text(t.node.name).font(.system(size: 11, weight: .medium))
                                        .foregroundColor(ink),
                                     at: CGPoint(x: r.minX + 7, y: r.minY + 12), anchor: .topLeading)
                            if r.height > 40 {
                                ctx.draw(Text(fmt(t.node.size)).font(.system(size: 10))
                                            .foregroundColor(ink.opacity(0.75)),
                                         at: CGPoint(x: r.minX + 7, y: r.minY + 27), anchor: .topLeading)
                            }
                        }
                    }
                }
                ForEach(tiles.indices, id: \.self) { i in
                    let t = tiles[i]
                    if t.rect.width > 3 && t.rect.height > 3 {
                        HitBox(node: t.node, rect: t.rect,
                               label: "\(t.node.name) — \(fmt(t.node.size))")
                    }
                }
            }
        }
        .padding(12)
    }
}

/// Transparent click/hover target laid over a Canvas-drawn shape.
struct HitBox: View {
    let node: FSNode
    let rect: CGRect
    let label: String
    @EnvironmentObject var store: AppStore

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .help(label)
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command)
                    || NSEvent.modifierFlags.contains(.shift) {
                    store.togglePick(node)
                } else {
                    store.selected = node
                    if node.isDir && !node.children.isEmpty { store.open(node) }
                }
            }
    }
}

// MARK: - Sunburst

struct SunburstView: View {
    @EnvironmentObject var store: AppStore
    private let maxDepth = 7

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let R = side / 2 - 8
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = R / Double(maxDepth + 1)
            let slices = store.current.map { Layout.partition($0, maxDepth: maxDepth) } ?? []

            ZStack {
                Canvas { ctx, _ in
                    for s in slices where s.depth > 0 {
                        let r0 = Double(s.depth) * ring
                        let r1 = r0 + ring - 1.4
                        let a0 = Angle(radians: s.x0 * .pi * 2 - .pi / 2)
                        let a1 = Angle(radians: s.x1 * .pi * 2 - .pi / 2)
                        guard a1.radians - a0.radians > 0.004 else { continue }
                        var p = Path()
                        p.addArc(center: c, radius: r0, startAngle: a0, endAngle: a1, clockwise: false)
                        p.addArc(center: c, radius: r1, startAngle: a1, endAngle: a0, clockwise: true)
                        p.closeSubpath()
                        ctx.fill(p, with: .color(Layout.color(s.node.name, depth: s.depth)))
                        if store.isPicked(s.node.path) {
                            ctx.stroke(p, with: .color(.white), lineWidth: 2)
                        }
                    }
                    // hub
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - ring + 2, y: c.y - ring + 2,
                                                    width: (ring - 2) * 2, height: (ring - 2) * 2)),
                             with: .color(Color(nsColor: .controlBackgroundColor)))
                }
                // hub click = go up
                Circle().fill(.clear).contentShape(Circle())
                    .frame(width: (ring - 2) * 2, height: (ring - 2) * 2)
                    .position(c)
                    .onTapGesture { store.up() }
                VStack(spacing: 2) {
                    Text(store.current?.name ?? "").font(.caption.weight(.medium)).lineLimit(1)
                    Text(fmt(store.current?.size ?? 0)).font(.caption2).foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
                .position(c)

                SunburstHits(slices: slices, center: c, ring: ring)
            }
        }
        .padding(12)
    }
}

/// Arc hit-testing done with a single gesture rather than hundreds of overlay views.
private struct SunburstHits: View {
    let slices: [Layout.Slice]
    let center: CGPoint
    let ring: Double
    @EnvironmentObject var store: AppStore

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture { location in
                let dx = location.x - center.x, dy = location.y - center.y
                let r = (dx * dx + dy * dy).squareRoot()
                let depth = Int(r / ring)
                guard depth > 0 else { store.up(); return }
                var a = atan2(dy, dx) + .pi / 2
                if a < 0 { a += .pi * 2 }
                let frac = a / (.pi * 2)
                guard let hit = slices.first(where: {
                    $0.depth == depth && frac >= $0.x0 && frac < $0.x1
                }) else { return }
                if NSEvent.modifierFlags.contains(.command)
                    || NSEvent.modifierFlags.contains(.shift) {
                    store.togglePick(hit.node)
                } else {
                    store.selected = hit.node
                    if hit.node.isDir && !hit.node.children.isEmpty { store.open(hit.node) }
                }
            }
    }
}

// MARK: - Flame

struct FlameView: View {
    @EnvironmentObject var store: AppStore
    private let rowH: Double = 21
    private let maxDepth = 15

    var body: some View {
        GeometryReader { geo in
            let slices = store.current.map { Layout.partition($0, maxDepth: maxDepth) } ?? []
            let deepest = slices.map(\.depth).max() ?? 0
            let H = max(geo.size.height, Double(deepest + 1) * rowH + 10)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for s in slices {
                            let x = s.x0 * geo.size.width
                            let w = (s.x1 - s.x0) * geo.size.width
                            guard w > 0.6 else { continue }
                            let y = Double(s.depth) * rowH
                            let r = CGRect(x: x + 0.5, y: y, width: max(0, w - 1), height: rowH - 1.6)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 2),
                                     with: .color(Layout.color(s.node.name, depth: s.depth)))
                            if store.isPicked(s.node.path) {
                                ctx.stroke(Path(roundedRect: r, cornerRadius: 2),
                                           with: .color(.white), lineWidth: 2)
                            }
                            if w > 46 {
                                let ink: Color = Layout.isLight(depth: s.depth) ? .black : .white
                                ctx.draw(Text(s.node.name).font(.system(size: 10.5))
                                            .foregroundColor(ink),
                                         at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
                            }
                        }
                    }
                    .frame(height: H)
                    ForEach(slices.indices, id: \.self) { i in
                        let s = slices[i]
                        let x = s.x0 * geo.size.width
                        let w = (s.x1 - s.x0) * geo.size.width
                        if w > 3 {
                            HitBox(node: s.node,
                                   rect: CGRect(x: x, y: Double(s.depth) * rowH,
                                                width: w, height: rowH - 1.6),
                                   label: "\(s.node.name) — \(fmt(s.node.size))")
                        }
                    }
                }
                .frame(height: H)
            }
        }
        .padding(12)
    }
}

// MARK: - Bubbles

struct BubbleView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        GeometryReader { geo in
            let R = max(0, min(geo.size.width, geo.size.height - 38) / 2 - 10)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let children = store.current?.children ?? []
            let bubbles = Layout.pack(children, radius: R, totalBytes: store.current?.size)
            let eligibleCount = children.filter { $0.size > 0 }.count
            ZStack {
                Canvas { ctx, _ in
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                               with: .color(.secondary.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    for b in bubbles {
                        let center = CGPoint(x: c.x + b.center.x, y: c.y + b.center.y)
                        let rect = CGRect(x: center.x - b.r, y: center.y - b.r,
                                          width: b.r * 2, height: b.r * 2)
                        ctx.fill(Path(ellipseIn: rect),
                                 with: .color(Layout.color(b.node.name, depth: 1).opacity(0.92)))
                        if store.isPicked(b.node.path) {
                            ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2.5)
                        }
                        // one level of nesting inside the roomy ones
                        if b.r > 44 {
                            for inner in Layout.pack(b.node.children, radius: b.r * 0.88,
                                                     totalBytes: b.node.size, itemLimit: 14)
                            where inner.r > 2.5 {
                                let ic = CGPoint(x: center.x + inner.center.x, y: center.y + inner.center.y)
                                ctx.fill(Path(ellipseIn: CGRect(x: ic.x - inner.r, y: ic.y - inner.r,
                                                                width: inner.r * 2, height: inner.r * 2)),
                                         with: .color(Layout.color(inner.node.name, depth: 2)))
                            }
                        }
                        if b.r > 26 {
                            let ink: Color = Layout.isLight(depth: 1) ? .black : .white
                            ctx.draw(Text(b.node.name).font(.system(size: 10.5, weight: .medium))
                                        .foregroundColor(ink),
                                     at: CGPoint(x: center.x, y: center.y - (b.r > 44 ? b.r * 0.55 : 0)))
                            if b.r > 38 {
                                ctx.draw(Text(fmt(b.node.size)).font(.system(size: 9.5))
                                            .foregroundColor(ink.opacity(0.8)),
                                         at: CGPoint(x: center.x, y: center.y - (b.r > 44 ? b.r * 0.55 : 0) + 14))
                            }
                        }
                    }
                }
                ForEach(bubbles.indices, id: \.self) { i in
                    let b = bubbles[i]
                    Circle().fill(.clear).contentShape(Circle())
                        .frame(width: b.r * 2, height: b.r * 2)
                        .position(x: c.x + b.center.x, y: c.y + b.center.y)
                        .help("\(b.node.name) — \(fmt(b.node.size))")
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command)
                                || NSEvent.modifierFlags.contains(.shift) {
                                store.togglePick(b.node)
                            } else {
                                store.selected = b.node
                                if !b.node.children.isEmpty { store.open(b.node) }
                            }
                        }
                }
                VStack {
                    HStack(spacing: 8) {
                        Text("\(bubbles.count) of \(eligibleCount) items shown · sizes use the whole folder")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("View all in Folders") { store.view = .folders }
                            .buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Mind map

struct MindMapView: View {
    @EnvironmentObject var store: AppStore
    private let maxDepth = 4

    // Local funcs are not allowed inside a ViewBuilder closure, so geometry lives here.
    private struct Geo {
        let W: Double, H: Double, colW: Double, rowH: Double
        func x(_ d: Int) -> Double { 30 + Double(d) * colW }
        func y(_ r: Double) -> Double { 24 + (r + 0.5) * rowH }
        func box(_ n: Layout.TreeNode) -> CGRect {
            let w = max(62.0, min(96.0, Double(n.node.name.count) * 6.4 + 16))
            return CGRect(x: x(n.depth), y: y(n.row) - 10, width: w, height: 20)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let root = store.current ?? FSNode(name: "", path: "", isDir: true)
            let t = Layout.tidyTree(root, maxDepth: maxDepth)
            let g = Geo(W: max(geo.size.width, 980.0),
                        H: max(geo.size.height, Double(t.rows) * 26 + 40),
                        colW: (max(geo.size.width, 980.0) - 200) / Double(maxDepth + 1),
                        rowH: (max(geo.size.height, Double(t.rows) * 26 + 40) - 40) / Double(t.rows))

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for l in t.links {
                            let a = g.box(l.from), b = g.box(l.to)
                            let x1 = a.maxX, y1 = a.midY, x2 = b.minX, y2 = b.midY
                            let mx = (x1 + x2) / 2
                            var p = Path()
                            p.move(to: CGPoint(x: x1, y: y1))
                            p.addCurve(to: CGPoint(x: x2, y: y2),
                                       control1: CGPoint(x: mx, y: y1),
                                       control2: CGPoint(x: mx, y: y2))
                            ctx.stroke(p, with: .color(.secondary.opacity(0.35)), lineWidth: 1.3)
                        }
                        for n in t.nodes {
                            let r = g.box(n)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 5),
                                     with: .color(Layout.color(n.node.name, depth: n.depth)))
                            if store.isPicked(n.node.path) {
                                ctx.stroke(Path(roundedRect: r, cornerRadius: 5),
                                           with: .color(.white), lineWidth: 2)
                            }
                            let ink: Color = Layout.isLight(depth: n.depth) ? .black : .white
                            ctx.draw(Text(n.node.name).font(.system(size: 10.5)).foregroundColor(ink),
                                     at: CGPoint(x: r.minX + 7, y: r.midY), anchor: .leading)
                            ctx.draw(Text(fmt(n.node.size)).font(.system(size: 10))
                                        .foregroundColor(.secondary),
                                     at: CGPoint(x: r.maxX + 7, y: r.midY), anchor: .leading)
                        }
                    }
                    .frame(width: g.W, height: g.H)
                    ForEach(t.nodes.indices, id: \.self) { i in
                        HitBox(node: t.nodes[i].node, rect: g.box(t.nodes[i]),
                               label: "\(t.nodes[i].node.name) — \(fmt(t.nodes[i].node.size))")
                    }
                }
                .frame(width: g.W, height: g.H)
            }
        }
        .padding(12)
    }
}
