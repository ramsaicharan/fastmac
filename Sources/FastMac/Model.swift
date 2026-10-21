import Foundation

// MARK: - Formatting

func fmt(_ bytes: Int64) -> String {
    let neg = bytes < 0
    var v = Double(abs(bytes)); var i = 0
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    while v >= 1024 && i < 4 { v /= 1024; i += 1 }
    let s = i < 2 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    return (neg ? "-" : "") + s + " " + units[i]
}

private let counter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; return f
}()
func fmtCount(_ n: Int) -> String { counter.string(from: NSNumber(value: n)) ?? "\(n)" }

// MARK: - Tree
//
// A class, deliberately. The tree can hold millions of nodes and is written once by the
// scanner then only read; a value type would copy on every SwiftUI update.

final class FSNode: Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    var size: Int64 = 0         // bytes allocated on disk (st_blocks * 512)
    var logical: Int64 = 0      // st_size — sparse files inflate this
    var files: Int = 0
    var dirs: Int = 0
    var mtime: TimeInterval = 0
    var children: [FSNode] = []
    unowned(unsafe) var parent: FSNode?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    init(name: String, path: String, isDir: Bool) {
        self.name = name; self.path = path; self.isDir = isDir
    }

    var shareOfParent: Double {
        guard let p = parent, p.size > 0 else { return 1 }
        return Double(size) / Double(p.size)
    }

    /// Largest children first, recursively. Called once when the scan lands.
    func sortBySize() {
        children.sort { $0.size > $1.size }
        for c in children where c.isDir { c.sortBySize() }
    }

    func ancestors() -> [FSNode] {
        var out: [FSNode] = []; var n = parent
        while let cur = n { out.append(cur); n = cur.parent }
        return out.reversed()
    }
}

// MARK: - Files kept aside during the walk

struct BigFile: Identifiable, Hashable {
    let path: String
    let size: Int64
    let mtime: TimeInterval
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var ageDays: Int { max(0, Int((Date().timeIntervalSince1970 - mtime) / 86400)) }
}

// MARK: - Scan output

struct ScanResult {
    var root: FSNode
    var bytes: Int64
    var files: Int
    var dirs: Int
    var errors: Int
    var elapsed: Double
    var bigFiles: [BigFile]
    var bySize: [Int64: [String]]     // ≥1 MB, seeds duplicate detection
    var cancelled: Bool = false
    var scannedAt = Date()
    /// The startup disk at the moment the scan finished, so the result can show
    /// what lies outside the scanned folder and what could not be read.
    var disk: DiskOverview?

    var isWholeDisk: Bool { root.path == "/" }
}

// MARK: - Age buckets

enum AgeBucket: Int, CaseIterable, Identifiable {
    case week, month, quarter, halfYear, year, twoYears, ancient
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: "< 1 week";      case .month: "< 1 month"
        case .quarter: "< 3 months"; case .halfYear: "< 6 months"
        case .year: "< 1 year";      case .twoYears: "< 2 years"
        case .ancient: "2+ years"
        }
    }
    var limitDays: Double {
        switch self {
        case .week: 7;    case .month: 30;    case .quarter: 90
        case .halfYear: 180; case .year: 365; case .twoYears: 730
        case .ancient: .infinity
        }
    }
    static func of(ageDays: Int) -> AgeBucket {
        for b in allCases where Double(ageDays) < b.limitDays { return b }
        return .ancient
    }
}
