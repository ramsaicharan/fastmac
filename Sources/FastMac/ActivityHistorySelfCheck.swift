import Foundation

/// Temporary fixtures only: no live sampling, user data, UI callbacks, or app signals.
/// Repository completions run on its queue, so these semaphores are safe in the CLI.
enum ActivityHistorySelfCheck {
    private final class Reply<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Value?
        func set(_ value: Value) { lock.lock(); result = .some(value); lock.unlock() }
        func get() -> Value? { lock.lock(); defer { lock.unlock() }; return result }
    }

    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": " + detail)")
        }
        func wait<Value>(_ label: String, _ operation: (@escaping (Value) -> Void) -> Void) -> Value? {
            let semaphore = DispatchSemaphore(value: 0)
            let reply = Reply<Value>()
            operation { value in reply.set(value); semaphore.signal() }
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                check(label, false, "repository completion timed out")
                return nil
            }
            return reply.get()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastmac-activity-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_800_000_000) // exact minute; independent of wall clock
        let privateName = "Private, \"App\"\nName"
        func sample(_ offset: TimeInterval, session: String = "session-a", unavailable: Bool = false) -> ActivitySnapshot {
            ActivitySnapshot(sampledAt: base.addingTimeInterval(offset), sessionID: session,
                cpuPercent: unavailable ? nil : 20, memoryUsed: unavailable ? nil : 1024,
                memoryTotal: unavailable ? nil : 4096, swapUsed: unavailable ? nil : 0,
                memoryPressure: "normal", diskFree: unavailable ? nil : 50,
                diskTotal: unavailable ? nil : 100, diskReadRate: unavailable ? nil : 0,
                diskWriteRate: unavailable ? nil : 12, networkDownloadRate: unavailable ? nil : 40,
                networkUploadRate: unavailable ? nil : 0, networkScope: "fixture aggregate",
                batteryPercent: unavailable ? nil : 80, gpuPercent: nil, thermalState: "Nominal",
                readableProcesses: 2, listedProcesses: 4,
                apps: [ActivityAppSnapshot(id: "/fixture/private/App.app", name: privateName,
                                           cpuPercent: 150, rss: 1024, processCount: 2)])
        }
        func folder(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }
        func dayFile(_ date: Date, in directory: URL) -> URL {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyy-MM-dd"
            return directory.appendingPathComponent(format.string(from: date) + ".jsonl")
        }
        func append(_ repo: ActivityRepository, _ value: ActivitySnapshot, days: Int = 30) -> Bool {
            guard let response: String? = wait("activity append responds", { callback in
                repo.append(value, retentionDays: days, completion: callback)
            }) else { return false }
            return response == nil
        }
        func load(_ repo: ActivityRepository, from: Date, until: Date, limit: Int = 1500) -> [ActivitySnapshot]? {
            guard let response: ([ActivitySnapshot], String?) = wait("activity load responds", { callback in
                repo.load(from: from, until: until, limit: limit) { callback(($0, $1)) }
            }) else { return nil }
            check("activity read has no repository error", response.1 == nil, response.1 ?? "")
            return response.0
        }

        let repo = ActivityRepository(directory: folder("sessions"))
        var first = sample(0)
        first.apps = (0..<20).map {
            ActivityAppSnapshot(id: "fixture-\($0)", name: "App \($0)", cpuPercent: 1, rss: 10, processCount: 1)
        }
        check("activity repository saves asynchronously", append(repo, first))
        check("activity repository accepts same-minute sample", append(repo, sample(15)))
        let coalesced = load(repo, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(100))
        check("one session is coalesced to one sample per minute", coalesced?.count == 1)
        check("persisted top app details are capped", coalesced?.first?.apps.count == 12)
        check("new session in the same minute is saved", append(repo, sample(30, session: "session-b")))
        check("next minute saves a sample", append(repo, sample(60, session: "session-b")))
        let restarted = ActivityRepository(directory: repo.directory)
        check("restarted repository preserves a new session", append(restarted, sample(75, session: "session-c")))
        let sessions = load(restarted, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(100))
        check("restart and same-minute session boundaries remain visible", sessions?.count == 4
              && sessions?.map(\.sessionID) == ["session-a", "session-b", "session-b", "session-c"])
        let range = load(restarted, from: base.addingTimeInterval(45), until: base.addingTimeInterval(70))
        check("range query excludes samples outside its bounds", range?.count == 1 && range?.first?.sampledAt == base.addingTimeInterval(60))
        let bounded = load(restarted, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(100), limit: 2)
        check("graph query respects its requested bound", bounded?.count == 2)
        let negative = load(restarted, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(100), limit: -1)
        check("invalid graph limit is handled without crashing", negative != nil && (negative?.count ?? 0) <= 1)

        let streamDirectory = folder("stream")
        let stream = ActivityRepository(directory: streamDirectory)
        do {
            try FileManager.default.createDirectory(at: streamDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var fixture = try encoder.encode(sample(60, session: "stream"))
            fixture.append(contentsOf: Data("\nnot json\n".utf8))
            var future = sample(120, session: "stream"); future.version = 999
            fixture.append(try encoder.encode(future)); fixture.append(0x0A)
            fixture.append(contentsOf: Data(String(repeating: "x", count: 70_000).utf8)); fixture.append(0x0A)
            fixture.append(try encoder.encode(sample(180, session: "stream"))); fixture.append(0x0A)
            fixture.append(contentsOf: Data("{\"version\":1,\"sampledAt\":".utf8)) // torn final record
            try fixture.write(to: dayFile(base, in: streamDirectory))
            let recovered = load(stream, from: base, until: base.addingTimeInterval(300))
            check("streaming read skips corrupt, oversized, future and torn lines", recovered?.count == 2
                  && recovered?.map(\.sampledAt) == [base.addingTimeInterval(60), base.addingTimeInterval(180)])
            check("a new sample can be appended after a torn final record", append(stream, sample(240, session: "stream")))
            let appended = load(stream, from: base, until: base.addingTimeInterval(300))
            check("first valid sample after a torn write remains readable", appended?.count == 3
                  && appended?.last?.sampledAt == base.addingTimeInterval(240))
        } catch { check("streaming fixtures created", false, error.localizedDescription) }

        let retention = ActivityRepository(directory: folder("retention"))
        check("old activity fixture is saved", append(retention, sample(-40 * 86_400), days: 999))
        check("new activity fixture triggers pruning", append(retention, sample(0), days: 999))
        check("retention setting is capped at 30 days", !FileManager.default.fileExists(atPath:
              dayFile(base.addingTimeInterval(-40 * 86_400), in: retention.directory).path))
        do {
            let oversized = dayFile(base.addingTimeInterval(-86_400), in: retention.directory)
            _ = FileManager.default.createFile(atPath: oversized.path, contents: nil)
            let handle = try FileHandle(forWritingTo: oversized)
            try handle.truncate(atOffset: UInt64(ActivityRepository.maximumBytes + 1)) // sparse; no 100 MB allocation
            try handle.close()
            check("byte-limit fixture triggers pruning", append(retention, sample(60)))
            let files = try FileManager.default.contentsOfDirectory(at: retention.directory, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = files.reduce(0) { total, file in total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            check("daily logs stay within the 100 MB ceiling", bytes <= ActivityRepository.maximumBytes
                  && !FileManager.default.fileExists(atPath: oversized.path))
        } catch { check("efficient byte-limit fixture created", false, error.localizedDescription) }

        let moments = (0..<105).map { ActivityBookmark(note: "Moment \($0)", snapshot: sample(TimeInterval($0 * 60))) }
        if let saved: String? = wait("bookmark save responds", { callback in repo.saveBookmarks(moments, completion: callback) }) {
            check("bookmarks save atomically", saved == nil)
        }
        if let loaded: ([ActivityBookmark], String?) = wait("bookmark load responds", { callback in repo.bookmarks { callback(($0, $1)) } }) {
            check("saved moments retain latest 100", loaded.1 == nil && loaded.0.count == 100
                  && loaded.0.first?.note == "Moment 5" && loaded.0.last?.note == "Moment 104")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: repo.directory.appendingPathComponent("bookmarks.json").path)
            check("bookmarks are restricted to their owner", ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        } catch { check("bookmark permissions are readable", false, error.localizedDescription) }

        let privateCSV = ActivityRepository.csv([sample(0, unavailable: true)], includeAppNames: false)
        let namedCSV = ActivityRepository.csv([sample(0)], includeAppNames: true)
        let privateRows = parseCSV(privateCSV), namedRows = parseCSV(namedCSV)
        check("default CSV excludes app names and executable paths", !privateCSV.contains("Private")
              && !privateCSV.contains("/fixture/private") && !namedCSV.contains("/fixture/private"))
        check("CSV escapes quotes, commas and newlines in opted-in app names", namedRows.count == 2
              && namedRows.last?.count == 22 && namedRows.last?[18] == privateName)
        let unavailableIndices = [1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 13, 14, 19, 20, 21]
        check("unavailable CSV metrics are blank rather than fabricated zeros", privateRows.count == 2
              && privateRows[1].count == 22 && unavailableIndices.allSatisfy { privateRows[1][$0].isEmpty })

        do {
            let unrelated = repo.directory.appendingPathComponent("keep.txt")
            try Data("unrelated fixture".utf8).write(to: unrelated)
            if let cleared: String? = wait("activity clear responds", { callback in repo.clear(completion: callback) }) {
                check("clearing own recordings succeeds", cleared == nil)
            }
            let empty = load(repo, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(300))
            if let remaining: ([ActivityBookmark], String?) = wait("cleared bookmarks load responds", { callback in repo.bookmarks { callback(($0, $1)) } }) {
                check("clear removes activity and saved moments", empty?.isEmpty == true && remaining.0.isEmpty && remaining.1 == nil)
            }
            check("clear preserves unrelated files", FileManager.default.fileExists(atPath: unrelated.path))
            check("clear resets the same-minute append gate", append(repo, first))
            let fresh = load(repo, from: base.addingTimeInterval(-1), until: base.addingTimeInterval(100))
            check("recording resumes after clear", fresh?.count == 1)
        } catch { check("clear isolation fixture created", false, error.localizedDescription) }
        return lines
    }

    /// Minimal RFC 4180 reader used to verify exported field boundaries, including
    /// multiline quoted app names. This is a check helper, not application code.
    private static func parseCSV(_ csv: String) -> [[String]] {
        let characters = Array(csv)
        var rows: [[String]] = [], row: [String] = [], value = ""
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    value.append("\""); index += 1
                } else { quoted.toggle() }
            } else if character == ",", !quoted {
                row.append(value); value = ""
            } else if character == "\n", !quoted {
                row.append(value); rows.append(row); row = []; value = ""
            } else { value.append(character) }
            index += 1
        }
        if !value.isEmpty || !row.isEmpty { row.append(value); rows.append(row) }
        return rows
    }
}
