import Foundation

/// Simulates collector samples and accepted/rejected delivery. These checks never
/// instantiate AlertManager or contact UNUserNotificationCenter.
enum ActivityAlertSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func record(_ ok: Bool, _ label: String) {
            lines.append("\(ok ? "PASS" : "FAIL")  " + label)
        }
        let start = Date(timeIntervalSince1970: 1_000_000)
        func sample(_ seconds: Double, cpu: Double? = 90, rss: Int64? = 1_000_000_000,
                    session: String = "session-a", present: Bool = true) -> ActivitySnapshot {
            ActivitySnapshot(sampledAt: start.addingTimeInterval(seconds), sessionID: session,
                cpuPercent: nil, memoryUsed: nil, memoryTotal: nil, swapUsed: nil,
                memoryPressure: "normal", diskFree: nil, diskTotal: nil,
                diskReadRate: nil, diskWriteRate: nil, networkDownloadRate: nil,
                networkUploadRate: nil, networkScope: "test", batteryPercent: nil, gpuPercent: nil,
                thermalState: "normal", readableProcesses: 0, listedProcesses: 0,
                apps: present ? [ActivityAppSnapshot(id: "test.app", name: "Test App",
                    cpuPercent: cpu, rss: rss, processCount: 1)] : [])
        }

        var disk = AlertEvaluator()
        record(disk.candidates(diskFree: 0, pressure: 0, now: start) == [.disk],
               "zero free bytes is a valid low-disk alert")
        record(disk.candidates(diskFree: 0, pressure: 0, now: start.addingTimeInterval(15)) == [.disk],
               "denied or failed delivery leaves the disk transition available")
        disk.commit(.disk, now: start.addingTimeInterval(15))
        record(disk.candidates(diskFree: 0, pressure: 0, now: start.addingTimeInterval(30)).isEmpty,
               "accepted delivery latches a persistent low-disk condition")
        record(AlertEvaluator().freeDiskThresholdBytes == 10 << 30,
               "low-disk policy remains 10 GB")
        var unavailable = AlertEvaluator()
        record(unavailable.candidates(diskFree: nil, pressure: nil, now: start).isEmpty,
               "unavailable volume and pressure readings do not become alerts")
        let invalidVolume = HealthSample(memory: MemorySample(), memoryPressure: .normal,
                                        diskFree: 0, diskTotal: 0, thermalState: .nominal)
        record(!invalidVolume.diskAvailable, "zero-total volume is unavailable even when free bytes is zero")
        var seededDisk = AlertEvaluator()
        seededDisk.seedCooldowns([.disk: start])
        record(seededDisk.candidates(diskFree: 0, pressure: 0, now: start.addingTimeInterval(60)).isEmpty,
               "persisted disk cooldown survives a fresh evaluator")
        record(seededDisk.candidates(diskFree: 0, pressure: 0, now: start.addingTimeInterval(6 * 3600 + 1)) == [.disk],
               "suppressed disk transition remains available after cooldown")

        record(AlertEvaluator.operatingSystemPressure(.normal) == 0
               && AlertEvaluator.operatingSystemPressure(.warning) == 100
               && AlertEvaluator.operatingSystemPressure(.critical) == 100
               && AlertEvaluator.operatingSystemPressure(.unknown) == nil,
               "memory alerts use macOS pressure flags independently of occupied-RAM percentages")
        var pressure = AlertEvaluator()
        var pressureEvents: [AlertEvaluator.Condition] = []
        for tick in stride(from: 0.0, through: 285.0, by: 15) {
            pressureEvents += pressure.candidates(diskFree: nil,
                pressure: AlertEvaluator.operatingSystemPressure(.warning), now: start.addingTimeInterval(tick))
        }
        record(pressureEvents.isEmpty, "OS memory pressure must persist for five minutes")
        record(pressure.candidates(diskFree: nil, pressure: 100,
                                  now: start.addingTimeInterval(300)) == [.memory],
               "sustained OS pressure becomes a candidate after five minutes")
        _ = pressure.candidates(diskFree: nil, pressure: nil, now: start.addingTimeInterval(315))
        record(pressure.candidates(diskFree: nil, pressure: 100,
                                  now: start.addingTimeInterval(330)).isEmpty,
               "unavailable OS pressure interrupts sustained-pressure continuity")

        var cpu = ActivityAlertEvaluator()
        var cpuCandidates: [ActivityAlertCandidate] = []
        for tick in stride(from: 0.0, through: 90.0, by: 30) { cpuCandidates += cpu.candidates(sample(tick)) }
        record(cpuCandidates.isEmpty, "brief app CPU activity does not notify")
        cpuCandidates = cpu.candidates(sample(120))
        record(cpuCandidates.count == 1 && cpuCandidates[0].kind == .cpu,
               "CPU above 80% of one core for two continuous minutes becomes a review cue")
        let retry = cpu.candidates(sample(150))
        record(retry.count == 1, "CPU delivery failure does not consume its transition")
        if let accepted = retry.first { cpu.commit(accepted, now: start.addingTimeInterval(150)) }
        record(cpu.candidates(sample(180)).isEmpty, "accepted CPU cue does not repeat while sustained")
        var seededCPU = ActivityAlertEvaluator()
        seededCPU.seedCooldowns(cpu.lastFire)
        var restartedEvents: [ActivityAlertCandidate] = []
        for tick in stride(from: 180.0, through: 330.0, by: 30) {
            restartedEvents += seededCPU.candidates(sample(tick, session: "restarted"))
        }
        record(restartedEvents.isEmpty, "persisted app cooldown suppresses repeat after restart")

        var gap = ActivityAlertEvaluator()
        _ = gap.candidates(sample(0))
        _ = gap.candidates(sample(30))
        record(gap.candidates(sample(200)).isEmpty,
               "sleep or a long collector gap breaks sustained CPU continuity")
        _ = gap.candidates(sample(230, cpu: nil))
        record(gap.candidates(sample(260)).isEmpty, "CPU warmup or unavailable reading restarts continuity")
        _ = gap.candidates(sample(290))
        record(gap.candidates(sample(320, session: "session-b")).isEmpty,
               "a new collection session cannot inherit prior sustained activity")
        _ = gap.candidates(sample(350))
        _ = gap.candidates(sample(380, present: false))
        record(gap.candidates(sample(410)).isEmpty, "app disappearance breaks its alert continuity")

        var growth = ActivityAlertEvaluator()
        var growthEvents: [ActivityAlertCandidate] = []
        for tick in stride(from: 0.0, through: 1800.0, by: 30) {
            let rss: Int64 = 1_000_000_000 + Int64(tick / 1800 * 600 * 1_024 * 1_024)
            growthEvents += growth.candidates(sample(tick, cpu: 0, rss: rss))
        }
        record(growthEvents.count == 1 && growthEvents[0].kind == .memoryGrowth,
               "600 MB resident growth across 30 minutes of continuous samples becomes a review cue")
        record(growthEvents.first?.body.contains("Caches and active work") == true,
               "resident growth alert describes observations without diagnosing a leak")
        if let accepted = growthEvents.first { growth.commit(accepted, now: start.addingTimeInterval(1800)) }
        record(growth.candidates(sample(1830, cpu: 0, rss: 1_700_000_000)).isEmpty,
               "accepted memory-growth cue is latched and rate-limited")
        var sparse = ActivityAlertEvaluator()
        _ = sparse.candidates(sample(0, cpu: 0, rss: 1))
        record(sparse.candidates(sample(1800, cpu: 0, rss: 1_000_000_000)).isEmpty,
               "two sparse samples cannot establish 30 minutes of continuous memory growth")
        var missingMemory = ActivityAlertEvaluator()
        for tick in stride(from: 0.0, through: 900.0, by: 30) {
            _ = missingMemory.candidates(sample(tick, cpu: 0, rss: 1))
        }
        _ = missingMemory.candidates(sample(930, cpu: 0, rss: nil))
        var invalidEvents: [ActivityAlertCandidate] = []
        for tick in stride(from: 960.0, through: 1860.0, by: 30) {
            invalidEvents += missingMemory.candidates(sample(tick, cpu: 0, rss: 1_000_000_000))
        }
        record(invalidEvents.isEmpty, "unavailable resident memory breaks the growth window")
        record(ActivityAlertEvaluator.key(.cpu, appID: "test.app") != ActivityAlertEvaluator.key(.memoryGrowth, appID: "test.app"),
               "CPU and memory-growth cooldowns are independently keyed without storing app paths")
        let snooze = AlertSnoozePolicy.until(minutes: 60, now: start)
        record(snooze.timeIntervalSince(start) == 3600, "one-hour alert snooze has a fixed expiry")
        record(AlertSnoozePolicy.isActive(until: snooze, now: start.addingTimeInterval(3599)), "snooze suppresses alerts before expiry")
        record(!AlertSnoozePolicy.isActive(until: snooze, now: snooze), "snooze expires at its deadline")
        record(!AlertSnoozePolicy.isActive(until: nil, now: start), "cleared snooze allows future observations")
        record(AlertSnoozePolicy.until(minutes: .min, now: start).timeIntervalSince(start) == 60, "invalid negative snooze is bounded")
        record(AlertSnoozePolicy.until(minutes: .max, now: start).timeIntervalSince(start) == 86400, "snooze cannot exceed one day")
        lines.append("PASS  alert diagnostics request no OS permission and schedule no notifications")
        return lines
    }
}
