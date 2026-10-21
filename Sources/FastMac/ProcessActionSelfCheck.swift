import Foundation
import Darwin

/// Pure fixtures: this never calls terminate(), sends a signal, or quits an app.
enum ProcessActionSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) {
            lines.append("\(ok ? "PASS" : "FAIL")  \(label)")
        }
        let pid: pid_t = getpid() == 99_999 ? 99_998 : 99_999
        let expected = ProcessIdentity(pid: pid, uid: getuid(), startedSeconds: 100,
                                       startedMicroseconds: 7, path: "/fixture/worker")
        let reused = ProcessIdentity(pid: pid, uid: getuid(), startedSeconds: 200,
                                     startedMicroseconds: 7, path: expected.path)
        let execChanged = ProcessIdentity(pid: pid, uid: getuid(), startedSeconds: 100,
                                          startedMicroseconds: 7, path: "/fixture/replacement")
        let ownerChanged = ProcessIdentity(pid: pid, uid: getuid() &+ 1, startedSeconds: 100,
                                           startedMicroseconds: 7, path: expected.path)
        check("process action accepts an unchanged owned identity (validation only)",
              PerfActions.validate(expected: expected, current: expected).ok)
        check("process action rejects a reused PID", !PerfActions.validate(expected: expected, current: reused).ok)
        check("process action rejects a changed executable", !PerfActions.validate(expected: expected, current: execChanged).ok)
        check("process action rejects a changed owner", !PerfActions.validate(expected: expected, current: ownerChanged).ok)
        check("process action rejects missing or exited identity",
              !PerfActions.validate(expected: nil, current: expected).ok
              && !PerfActions.validate(expected: expected, current: nil).ok)
        let selfIdentity = ProcessIdentity(pid: getpid(), uid: getuid(), startedSeconds: 100,
                                           startedMicroseconds: 7, path: expected.path)
        check("process action protects FastMac itself", !PerfActions.validate(expected: selfIdentity, current: selfIdentity).ok)

        func sample(_ pid: pid_t, _ path: String, read: Int64?, write: Int64?, cpu: Double = 100) -> PerfProcSample {
            PerfProcSample(pid: pid, ppid: 1, comm: "helper", appName: "Same Name", path: path,
                           uid: getuid(), owned: true, rss: 100, cpuPercent: cpu, cpuCores: cpu / 100,
                           lifetimeCPUSeconds: 0, diskRead: read, diskWrite: write)
        }
        let main = sample(30, "/Applications/Same Name.app/Contents/MacOS/Main", read: 0, write: 0)
        let helper = sample(31, "/Applications/Same Name.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
                            read: nil, write: 0, cpu: 150)
        let copy = sample(32, "/fixture/Same Name.app/Contents/MacOS/Main", read: 0, write: nil)
        let groups = PerfProbe.group([main, helper, copy])
        check("helpers group by outer app path; same-name app copies stay separate", groups.count == 2
              && groups.first { $0.id == "/Applications/Same Name.app" }?.count == 2)
        let app = groups.first { $0.id == "/Applications/Same Name.app" }
        check("group disk read stays unavailable if any member is unreadable", app?.diskRead == nil)
        check("known zero disk writes remain zero", app?.diskWrite == 0)
        check("multi-core app CPU may exceed 100 percent", app?.cpuPercent == 250)
        var unavailable = helper
        unavailable.cpuAvailable = false
        let incompleteCPU = PerfProbe.group([main, unavailable]).first
        check("an app CPU rate stays unavailable when a helper has no valid baseline", incompleteCPU?.cpuAvailable == false)
        var measuredIdle = main
        measuredIdle = sample(30, main.path, read: 0, write: 0, cpu: 0)
        check("a measured zero CPU rate remains available", PerfProbe.group([measuredIdle]).first?.cpuAvailable == true)
        let advisories = PerfProbe.advisories(groups: groups, system: SystemSnapshot(coreCount: 10))
        check("CPU advisory explains one-core percent", advisories.contains { $0.contains("100% = one core") }
              && !advisories.contains { $0.contains("total CPU capacity") })
        return lines
    }
}
