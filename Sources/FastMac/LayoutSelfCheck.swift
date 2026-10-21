import Foundation

enum LayoutSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)")
        }
        let nodes = (0..<5_000).map { i -> FSNode in
            let node = FSNode(name: "Folder \(i)", path: "/fixture/\(i)", isDir: true)
            node.size = 1_024
            return node
        }
        let result = Layout.packBounded(nodes, radius: 300)
        let circles = result.bubbles
        check("wide-folder bubble work has a fixed ceiling", result.work <= Layout.bubbleWorkLimit)
        check("wide-folder bubble chart has a bounded nonempty subset",
              !circles.isEmpty && circles.count <= Layout.bubbleItemLimit && circles.count < nodes.count)
        check("bubble circles stay inside the chart", circles.allSatisfy {
            hypot($0.center.x, $0.center.y) + $0.r <= 300.000_001
        })
        var disjoint = true
        for i in circles.indices {
            for j in circles.indices where j > i {
                if hypot(circles[i].center.x - circles[j].center.x,
                         circles[i].center.y - circles[j].center.y) + 0.000_001
                    < circles[i].r + circles[j].r { disjoint = false }
            }
        }
        check("bounded bubble circles never overlap", disjoint)
        let expected = sqrt(1.0 / Double(nodes.count)) * 300 * 0.83
        check("omitted folders retain their share of the area denominator",
              circles.allSatisfy { abs($0.r - expected) < 0.000_001 })
        let repeatResult = Layout.packBounded(Array(nodes.reversed()), radius: 300)
        check("equal-size bubbles are deterministic independent of input order",
              circles.map(\.node.path) == repeatResult.bubbles.map(\.node.path)
              && zip(circles, repeatResult.bubbles).allSatisfy { $0.center == $1.center })
        let larger = Layout.packBounded(nodes, radius: 1_200)
        check("display size does not multiply packing work",
              larger.work == result.work && larger.bubbles.count == circles.count)
        check("invalid bubble radii produce no geometry",
              [0.0, -1.0, .infinity, .nan].allSatisfy { Layout.pack(nodes, radius: $0).isEmpty })
        check("empty folders produce no bubbles", Layout.pack([], radius: 300).isEmpty)
        let parentBytes: Int64 = 10_240
        let directFiles = Layout.pack([nodes[0]], radius: 300, totalBytes: parentBytes)
        check("direct files retain their share of the parent folder",
              directFiles.count == 1 && abs(directFiles[0].r - sqrt(0.1) * 300 * 0.83) < 0.000_001)
        let nested = Layout.pack(nodes, radius: 100, totalBytes: 10_240_000, itemLimit: 14)
        check("nested item limit never renormalizes omitted items",
              !nested.isEmpty && nested.count <= 14 && nested.allSatisfy {
                  abs($0.r - sqrt(1_024.0 / 10_240_000) * 100 * 0.83) < 0.000_001
              })
        return lines
    }
}
