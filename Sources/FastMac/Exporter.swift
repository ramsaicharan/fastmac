import AppKit
import UniformTypeIdentifiers

// MARK: - Pure builders
//
// Building the CSV/JSON payload is separated from showing an NSSavePanel so it can
// be exercised headlessly (see ShellSelfCheck) — panels can't be driven without a
// user, but the bytes they'd write can always be checked.
//
// The tree only holds directory nodes (files are folded into their parent's
// counters — see Model.swift), so a full recursive walk stays bounded by the
// directory count, not the file count, even for a whole-home scan.

enum Exporter {
    struct ExportRow: Codable {
        let path: String
        let name: String
        let bytes: Int64
        let logicalBytes: Int64
        let files: Int
        let dirs: Int
    }

    struct ExportBigFile: Codable {
        let path: String
        let size: Int64
        let mtime: TimeInterval
    }

    struct ExportPayload: Codable {
        var version = 1
        var root: String
        var bytes: Int64
        var files: Int
        var dirs: Int
        var errors: Int
        var elapsed: Double
        var scannedAt: Date
        var directories: [ExportRow]
        var bigFiles: [ExportBigFile]
    }

    private static func rows(_ node: FSNode, into out: inout [ExportRow]) {
        out.append(ExportRow(path: node.path, name: node.name, bytes: node.size,
                             logicalBytes: node.logical, files: node.files, dirs: node.dirs))
        for c in node.children where c.isDir { rows(c, into: &out) }
    }

    static func buildPayload(_ result: ScanResult) -> ExportPayload {
        var out: [ExportRow] = []
        rows(result.root, into: &out)
        let big = result.bigFiles.map { ExportBigFile(path: $0.path, size: $0.size, mtime: $0.mtime) }
        return ExportPayload(root: result.root.path, bytes: result.bytes, files: result.files,
                             dirs: result.dirs, errors: result.errors, elapsed: result.elapsed,
                             scannedAt: result.scannedAt, directories: out, bigFiles: big)
    }

    static func buildJSON(_ result: ScanResult) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(buildPayload(result))
    }

    static func buildCSV(_ result: ScanResult) -> String {
        var out: [ExportRow] = []
        rows(result.root, into: &out)
        var csv = "path,name,bytes,logical_bytes,files,dirs\n"
        for r in out {
            csv += "\(csvField(r.path)),\(csvField(r.name)),\(r.bytes),\(r.logicalBytes),\(r.files),\(r.dirs)\n"
        }
        return csv
    }

    private static func csvField(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: side-effecting: NSSavePanel

    @MainActor
    static func exportJSON(_ result: ScanResult, suggestedName: String? = nil) {
        guard let data = buildJSON(result) else { return }
        savePanel(suggestedName: (suggestedName ?? defaultName(result)) + ".json",
                 type: .json) { url in try? data.write(to: url, options: .atomic) }
    }

    @MainActor
    static func exportCSV(_ result: ScanResult, suggestedName: String? = nil) {
        let csv = buildCSV(result)
        savePanel(suggestedName: (suggestedName ?? defaultName(result)) + ".csv",
                 type: .commaSeparatedText) { url in
            try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private static func defaultName(_ result: ScanResult) -> String {
        "fastmac-" + (result.root.name.isEmpty ? "scan" : result.root.name)
    }

    @MainActor
    private static func savePanel(suggestedName: String, type: UTType, write: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(url)
    }
}
