import Foundation

/// Pure export fixtures. No filesystem writes, live sampling, or preferences.
enum ActivityExportSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(label)") }
        let name = "Private, \"App\"\nUnicode 世界"
        let path = "/Users/private-fixture/Secret App.app"
        let session = "private-session-do-not-export"
        let sampledAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        var sample = ActivitySnapshot(sampledAt: sampledAt, sessionID: session,
            cpuPercent: nil, memoryUsed: nil, memoryTotal: 4096, swapUsed: 0,
            memoryPressure: "normal", diskFree: 0, diskTotal: 100,
            diskReadRate: nil, diskWriteRate: 0, networkDownloadRate: nil,
            networkUploadRate: 0, networkScope: "Default physical interface · en0",
            batteryPercent: nil, gpuPercent: nil, thermalState: "Nominal",
            readableProcesses: 1, listedProcesses: 3,
            apps: [ActivityAppSnapshot(id: path, name: name, cpuPercent: 250, rss: nil, processCount: 2)])
        do {
            let data = try ActivityRepository.json([sample])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = object?["samples"] as? [[String: Any]]
            let row = rows?.first
            let text = String(decoding: data, as: UTF8.self)
            check("JSON export declares a schema version and privacy choice", object?["schema_version"] as? Int == 1
                  && object?["includes_app_names"] as? Bool == false)
            check("JSON default excludes app names, executable paths and session identities", !text.contains("Private")
                  && !text.contains(path) && !text.contains(session)
                  && (row?["top_apps"] as? [[String: Any]])?.isEmpty == true)
            let missing = ["cpu_whole_machine_percent", "memory_bytes", "readable_process_disk_read_bytes_per_second",
                           "network_download_bytes_per_second", "battery_percent", "gpu_percent"]
            check("JSON unavailable readings are explicit null", missing.allSatisfy { row?[$0] is NSNull })
            let zero = ["swap_bytes", "disk_free_bytes", "readable_process_disk_write_bytes_per_second", "network_upload_bytes_per_second"]
            check("JSON known zero readings remain numeric zero", zero.allSatisfy { (row?[$0] as? NSNumber)?.doubleValue == 0 })
            let units = object?["units"] as? [String: String]
            check("JSON declares byte, rate and CPU units", units?["memory_bytes"] == "bytes"
                  && units?["network_upload_bytes_per_second"] == "bytes/second"
                  && units?["cpu_whole_machine_percent"] == "percent")
            let conventions = object?["conventions"] as? [String: String]
            check("JSON distinguishes whole-machine and one-core CPU conventions", conventions?["cpu_whole_machine_percent"]?.contains("all logical cores") == true
                  && conventions?["top_apps.cpu_one_core_percent"]?.contains("one full core") == true)
            let scope = object?["scope"] as? [String: String]
            check("JSON explains readable-process disk and physical network scope", scope?["disk_io"]?.contains("readable user-owned") == true
                  && scope?["network"]?.contains("physical") == true && scope?["network"]?.contains("no application attribution") == true
                  && row?["network_scope"] as? String == sample.networkScope)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = (row?["timestamp"] as? String).flatMap(format.date(from:))
            check("JSON UTC timestamp preserves fractional sample time", timestamp == sampledAt
                  && (row?["timestamp"] as? String)?.hasSuffix("Z") == true)

            let optedInData = try ActivityRepository.json([sample], includeAppNames: true)
            let optedIn = try JSONSerialization.jsonObject(with: optedInData) as? [String: Any]
            let named = ((optedIn?["samples"] as? [[String: Any]])?.first?["top_apps"] as? [[String: Any]])?.first
            let includedText = String(decoding: optedInData, as: UTF8.self)
            check("JSON opted-in names preserve escaping and Unicode", named?["name"] as? String == name)
            check("JSON app export retains one-core CPU and missing resident size", (named?["cpu_one_core_percent"] as? NSNumber)?.doubleValue == 250
                  && named?["rss_bytes"] is NSNull && named?["process_count"] as? Int == 2)
            check("JSON opted-in apps contain only five public summary fields", Set(named?.keys.map { $0 } ?? [])
                  == Set(["name", "process_count", "rss_bytes", "cpu_one_core_percent", "footprint_bytes"]))
            check("JSON opt-in still excludes grouping IDs, paths and session IDs", !includedText.contains(path) && !includedText.contains(session)
                  && named?["id"] == nil && named?["path"] == nil && named?["commands"] == nil
                  && named?["projects"] == nil && named?["notes"] == nil)
            sample.apps = (0..<20).map { ActivityAppSnapshot(id: "private-id-\($0)", name: "App \($0)", cpuPercent: nil, rss: nil, processCount: 1) }
            let leading = try JSONSerialization.jsonObject(with: ActivityRepository.json([sample], includeAppNames: true)) as? [String: Any]
            let apps = (leading?["samples"] as? [[String: Any]])?.first?["top_apps"] as? [[String: Any]]
            check("JSON includes at most the leading 12 app summaries", apps?.count == 12 && apps?.first?["name"] as? String == "App 0"
                  && apps?.last?["name"] as? String == "App 11")
            check("JSON unavailable app metrics remain null", apps?.first?["cpu_one_core_percent"] is NSNull && apps?.first?["rss_bytes"] is NSNull)
            let empty = try JSONSerialization.jsonObject(with: ActivityRepository.json([])) as? [String: Any]
            check("empty JSON export preserves schema metadata and an empty sample array", empty?["schema_version"] as? Int == 1
                  && (empty?["samples"] as? [Any])?.isEmpty == true && empty?["units"] is [String: Any])
            sample.cpuPercent = .infinity
            var rejected = false
            do { _ = try ActivityRepository.json([sample]) } catch { rejected = true }
            check("non-finite measurements cannot produce invalid JSON", rejected)
        } catch {
            lines.append("FAIL  JSON export fixtures encode and parse: \(error.localizedDescription)")
        }
        return lines
    }
}
