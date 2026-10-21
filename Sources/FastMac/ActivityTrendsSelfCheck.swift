import Foundation

enum ActivityTrendsSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ condition: Bool) { lines.append("\(condition ? "PASS" : "FAIL")  \(label)") }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ minute: Double, apps: [ActivityAppSnapshot], session: String = "a") -> ActivitySnapshot {
            ActivitySnapshot(sampledAt: base.addingTimeInterval(minute * 60), sessionID: session,
                cpuPercent: 20, memoryUsed: 1000, memoryTotal: 2000, swapUsed: 200,
                memoryPressure: "normal", diskFree: 1000, diskTotal: 5000,
                diskReadRate: nil, diskWriteRate: nil, networkDownloadRate: nil,
                networkUploadRate: nil, networkScope: "fixture", batteryPercent: nil,
                gpuPercent: nil, thermalState: "Normal", readableProcesses: 2, listedProcesses: 3, apps: apps)
        }
        func app(_ rss: Int64?, cpu: Double? = nil, id: String = "app-a") -> ActivityAppSnapshot {
            ActivityAppSnapshot(id: id, name: "Same name", cpuPercent: cpu, rss: rss, processCount: 2)
        }
        var footprintApp = app(100)
        footprintApp.footprint = 300
        let footprintSample = sample(0, apps: [footprintApp])
        let footprintTrend = ActivityTrends.apps(in: [footprintSample], memoryMetric: .footprint).first
        check("footprint comparisons use accounted memory instead of RSS", footprintTrend?.averageBytes == 300)
        check("legacy app records have no invented footprint", ActivityTrends.apps(in: [sample(0, apps: [app(100)])], memoryMetric: .footprint).first?.peakBytes == nil)
        let samples = [sample(0, apps: [app(100, cpu: 120), app(900, id: "app-b")]),
                       sample(1, apps: []), sample(2, apps: [app(nil)]),
                       sample(3, apps: [app(300, cpu: 60)])]
        let trends = ActivityTrends.apps(in: samples)
        let a = trends.first { $0.id == "app-a" }
        check("same display name preserves distinct app identities", trends.count == 2)
        check("missing apps do not lower sample averages", a?.averageBytes == 200 && a?.observations == 3
              && a?.memoryObservations == 2)
        check("CPU average ignores missing baselines and retains values above 100%", a?.averageCPU == 90 && a?.peakCPU == 120)
        check("peak memory retains its inspectable snapshot", a?.peakBytes == 300 && a?.peakMemorySample?.id == samples[3].id)
        check("peak memory ranks apps independently of CPU", trends.first?.id == "app-b")
        check("CPU ranking uses the one-core convention", ActivityTrends.apps(in: samples, sortedBy: .peakCPU).first?.id == "app-a")
        check("input ordering does not change last seen", ActivityTrends.apps(in: samples.reversed()).first { $0.id == "app-a" }?.lastSeen == samples[3].sampledAt)
        var legacy = samples[0]
        legacy.appCPUUnit = nil
        check("legacy CPU with unspecified scale is not reinterpreted", ActivityTrends.apps(in: [legacy]).allSatisfy { $0.peakCPU == nil }
              && ActivityTrends.cpu(for: "app-a", in: legacy) == nil)
        var uncalibrated = samples[0]
        uncalibrated.appCPUMeasurementVersion = nil
        check("pre-fix CPU readings cannot enter calibrated trends", ActivityTrends.apps(in: [uncalibrated]).allSatisfy { $0.peakCPU == nil })
        check("empty history has no invented app statistics", ActivityTrends.apps(in: []).isEmpty)
        let invalid = sample(0, apps: [app(-1, cpu: .infinity)])
        check("invalid readings stay unavailable", ActivityTrends.apps(in: [invalid]).first?.averageBytes == nil
              && ActivityTrends.apps(in: [invalid]).first?.averageCPU == nil)
        let points = ActivityTrendPoint.make(samples, hours: 1) { $0.apps.first { $0.id == "app-a" }?.rss.map(Double.init) }
        check("missing app entries split the memory chart", points.count == 2 && points[0].segment != points[1].segment)
        let gaps = [samples[0], sample(1, apps: [], session: "restart"), sample(20, apps: [], session: "restart")]
        let segments = ActivityTrendPoint.make(gaps, hours: 1) { _ in 0 }
        check("zero-valued readings are retained across session and sleep gaps", segments.count == 3
              && Set(segments.map(\.segment)).count == 3)

        var before = MemorySample(), after = MemorySample()
        before.swapInPages = 100; before.swapOutPages = 40
        after.swapInPages = 110; after.swapOutPages = 40
        let rates = ActivityMemoryRates.make(current: after, previous: before, elapsed: 5)
        check("swap rates measure counter deltas with the native page size", rates.read == Double(MemoryProbe.pageSize) * 2 && rates.write == 0)
        check("swap has no rate on first sample", ActivityMemoryRates.make(current: after, previous: nil, elapsed: 5).read == nil)
        check("swap resets after sleep or invalid timing", [0.0, 76, .infinity, .nan].allSatisfy {
            ActivityMemoryRates.make(current: after, previous: before, elapsed: $0).read == nil
        })
        check("reset swap counters do not underflow", ActivityMemoryRates.make(current: before, previous: after, elapsed: 5).read == nil)
        after.swapInPages = nil
        check("denied counters stay unavailable", ActivityMemoryRates.make(current: after, previous: before, elapsed: 5).read == nil)

        let groups = (0..<20).map { i in
            PerfAppGroup(name: "App \(i)", pids: [Int32(i + 1)], cpuPercent: Double(i), rss: Int64(20 - i),
                diskRead: nil, diskWrite: nil, lifetimeCPUSeconds: 0, appKey: "app-\(i)")
        }
        let chosen = ActivityAppSelection.leading(groups)
        check("history retains both top-six memory and CPU consumers", chosen.count == 12
              && Set(chosen.map(\.id)) == Set((0..<6).map { "app-\($0)" } + (14..<20).map { "app-\($0)" }))
        let duplicate = ActivityAppSelection.leading(Array(groups.prefix(2)))
        check("history selection does not duplicate app groups", duplicate.count == 2)
        var unknown = samples[0]; unknown.memoryPressure = "unknown"
        check("unavailable OS pressure is a gap, not normal", ActivitySystemMetric.pressure.value(unknown) == nil)
        unknown.memoryPressure = "critical"
        check("critical pressure is the highest pressure level", ActivitySystemMetric.pressure.value(unknown) == 2)

        do {
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            var enriched = samples[0]
            enriched.compressedBytes = 123; enriched.swapInRate = 456; enriched.swapOutRate = 0
            let decoded = try decoder.decode(ActivitySnapshot.self, from: encoder.encode(enriched))
            check("new memory metrics round-trip in history", decoded.compressedBytes == 123 && decoded.swapInRate == 456 && decoded.swapOutRate == 0)
            var object = try JSONSerialization.jsonObject(with: encoder.encode(enriched)) as! [String: Any]
            for key in ["appCPUUnit", "appCPUMeasurementVersion", "compressedBytes", "swapInRate", "swapOutRate"] { object.removeValue(forKey: key) }
            let old = try decoder.decode(ActivitySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            check("old logs remain readable without inventing newly tracked values", old.appCPUUnit == nil
                  && old.compressedBytes == nil && old.swapInRate == nil && old.apps.count == 2)
            let exported = try JSONSerialization.jsonObject(with: ActivityRepository.json([old, enriched], includeAppNames: true)) as! [String: Any]
            let rows = exported["samples"] as! [[String: Any]]
            let oldApps = rows[0]["top_apps"] as! [[String: Any]]
            check("legacy JSON CPU exports as null instead of a false unit", oldApps[0]["cpu_one_core_percent"] is NSNull)
            check("new JSON metrics preserve zero versus unavailable", rows[0]["swap_out_bytes_per_second"] is NSNull
                  && (rows[1]["swap_out_bytes_per_second"] as? NSNumber)?.intValue == 0
                  && (rows[1]["compressed_bytes"] as? NSNumber)?.intValue == 123)
            check("CSV export includes the new memory columns", ActivityRepository.csv([enriched], includeAppNames: false)
                .contains("compressed_bytes,swap_in_bytes_per_second,swap_out_bytes_per_second"))
        } catch { lines.append("FAIL  history migration and export: \(error)") }
        return lines
    }
}
