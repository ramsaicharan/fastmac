import SwiftUI

/// Pure geometry. Kept apart from the views so each algorithm can be reasoned about alone.
enum Layout {

    // MARK: squarified treemap

    struct Tile { let node: FSNode; let rect: CGRect }

    static func treemap(_ kids: [FSNode], in bounds: CGRect) -> [Tile] {
        let live = kids.filter { $0.size > 0 }
        let total = live.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        var out: [Tile] = []
        // Work in Double throughout. CGFloat and Double are the same type on 64-bit, but
        // only the Xcode toolchain bridges them implicitly here — Command Line Tools'
        // Swift rejects [CGFloat] where [Double] is expected, so be explicit.
        let boundsW = Double(bounds.width), boundsH = Double(bounds.height)
        let items = live.map { (node: $0,
                                area: Double($0.size) / Double(total) * boundsW * boundsH) }
        var x = Double(bounds.minX), y = Double(bounds.minY), w = boundsW, h = boundsH
        var i = 0

        func worst(_ row: [Double], _ sum: Double, _ side: Double) -> Double {
            guard sum > 0, side > 0 else { return 0 }
            let thickness = sum / side
            var lo = Double.infinity, hi = 0.0
            for a in row { let len = a / thickness; lo = min(lo, len); hi = max(hi, len) }
            guard hi > 0, thickness > 0 else { return 0 }
            return min(thickness / hi, lo / thickness)   // 1.0 is a perfect square
        }

        while i < items.count {
            let horizontal = w >= h
            let side = horizontal ? h : w
            guard side > 0 else { break }

            // Track the row by index range, not by value: two folders of identical size
            // would otherwise resolve to the same node.
            let start = i
            var areas = [items[i].area]
            var sum = items[i].area
            var best = worst(areas, sum, side)
            i += 1
            while i < items.count {
                let next = sum + items[i].area
                let score = worst(areas + [items[i].area], next, side)
                if score < best { break }          // adding it makes the row worse — close it
                areas.append(items[i].area); sum = next; best = score; i += 1
            }

            let thickness = sum / side
            var offset = horizontal ? y : x
            for idx in start..<i {
                let len = items[idx].area / thickness
                let r = horizontal
                    ? CGRect(x: x, y: offset, width: thickness, height: len)
                    : CGRect(x: offset, y: y, width: len, height: thickness)
                // CGRect takes CGFloat; the values above are Double by design.
                out.append(Tile(node: items[idx].node, rect: r))
                offset += len
            }
            if horizontal { x += thickness; w -= thickness } else { y += thickness; h -= thickness }
            if w <= 0.5 || h <= 0.5 { break }
        }
        return out
    }

    // MARK: partition (drives sunburst and flame)

    struct Slice { let node: FSNode; let depth: Int; let x0: Double; let x1: Double }

    static func partition(_ root: FSNode, maxDepth: Int) -> [Slice] {
        var out: [Slice] = []
        func walk(_ n: FSNode, _ d: Int, _ a: Double, _ b: Double) {
            out.append(Slice(node: n, depth: d, x0: a, x1: b))
            guard d < maxDepth, !n.children.isEmpty else { return }
            let total = n.children.reduce(Int64(0)) { $0 + $1.size }
            guard total > 0 else { return }
            var cursor = a
            let span = b - a
            for c in n.children {
                let w = span * Double(c.size) / Double(total)
                if w > span * 0.002 { walk(c, d + 1, cursor, cursor + w) }
                cursor += w
            }
        }
        walk(root, 0, 0, 1)
        return out
    }

    // MARK: circle packing

    struct Bubble { let node: FSNode; let center: CGPoint; let r: Double }

    static let bubbleItemLimit = 120
    static let bubbleWorkLimit = 180_000

    /// The chart intentionally shows a subset. A deterministic work ceiling prevents
    /// wide folders from blocking SwiftUI while preserving each circle's share of
    /// the entire folder. Normalized coordinates keep work independent of screen size.
    static func pack(_ kids: [FSNode], radius R: Double, totalBytes: Int64? = nil,
                     itemLimit: Int = bubbleItemLimit) -> [Bubble] {
        packBounded(kids, radius: R, totalBytes: totalBytes, itemLimit: itemLimit).bubbles
    }

    static func packBounded(_ kids: [FSNode], radius R: Double, totalBytes: Int64? = nil,
                            itemLimit: Int = bubbleItemLimit)
        -> (bubbles: [Bubble], work: Int) {
        guard R.isFinite, R > 0 else { return ([], 0) }
        let live = kids.filter { $0.size > 0 }
        let total = max(live.reduce(0.0) { $0 + Double($1.size) }, Double(totalBytes ?? 0))
        guard total.isFinite, total > 0 else { return ([], 0) }
        let unitRadius = 180.0
        let scale = R / unitRadius
        let sized = live.sorted {
            $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size
        }.prefix(max(0, min(itemLimit, bubbleItemLimit))).map {
            (node: $0, r: (Double($0.size) / total).squareRoot() * unitRadius * 0.83)
        }

        var placed: [(node: FSNode, x: Double, y: Double, r: Double)] = []
        var work = 0
        placement: for item in sized where item.r > 1.2 {
            if placed.isEmpty { placed.append((item.node, 0, 0, item.r)); continue }
            var done = false
            var rad = item.r * 0.4
            while rad + item.r <= unitRadius && !done {
                let steps = max(14, Int(rad * 1.1))
                for s in 0..<steps {
                    guard work < bubbleWorkLimit else { break placement }
                    work += 1
                    let a = Double(s) / Double(steps) * .pi * 2 + rad * 0.37
                    let x = cos(a) * rad, y = sin(a) * rad
                    var clash = false
                    for p in placed {
                        guard work < bubbleWorkLimit else { break placement }
                        work += 1
                        let dx = x - p.x, dy = y - p.y
                        let clearance = item.r + p.r + 1.1
                        if dx * dx + dy * dy < clearance * clearance {
                            clash = true
                            break
                        }
                    }
                    if !clash { placed.append((item.node, x, y, item.r)); done = true; break }
                }
                rad += max(1.2, item.r * 0.16)
            }
        }
        return (placed.map {
            Bubble(node: $0.node, center: CGPoint(x: $0.x * scale, y: $0.y * scale), r: $0.r * scale)
        }, work)
    }

    // MARK: tidy tree (mind map)

    struct TreeNode { let node: FSNode; let depth: Int; let row: Double }
    struct TreeLink { let from: TreeNode; let to: TreeNode }

    static func tidyTree(_ root: FSNode, maxDepth: Int, maxKids: Int = 9)
        -> (nodes: [TreeNode], links: [TreeLink], rows: Int) {
        var nodes: [TreeNode] = []
        var links: [TreeLink] = []
        var leaf = 0.0

        @discardableResult
        func walk(_ n: FSNode, _ d: Int, _ parent: TreeNode?) -> TreeNode {
            let kids = d < maxDepth ? Array(n.children.prefix(maxKids)) : []
            var row = 0.0
            var made: [TreeNode] = []
            if kids.isEmpty { row = leaf; leaf += 1 }
            else {
                for k in kids { made.append(walk(k, d + 1, nil)) }
                row = (made.map(\.row).min()! + made.map(\.row).max()!) / 2
            }
            let me = TreeNode(node: n, depth: d, row: row)
            nodes.append(me)
            for m in made { links.append(TreeLink(from: me, to: m)) }
            if let parent { links.append(TreeLink(from: parent, to: me)) }
            return me
        }
        walk(root, 0, nil)
        return (nodes, links, max(1, Int(leaf)))
    }

    // MARK: colour

    /// Stable hue per name so a folder keeps its colour between views and rescans.
    static func color(_ name: String, depth: Int) -> Color {
        var h = 0
        for b in name.utf8 { h = (h &* 31 &+ Int(b)) & 0xFFFFFF }
        let hue = Double(abs(h) % 360) / 360
        let light = max(0.26, 0.60 - Double(depth) * 0.06)
        return Color(hue: hue, saturation: 0.52, brightness: light + 0.18)
    }
    static func isLight(depth: Int) -> Bool { (0.60 - Double(depth) * 0.06) > 0.52 }
}
