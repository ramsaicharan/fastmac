import Foundation

enum AdvancedResourcesSelfCheck {
    static func run() -> [String] {
        var lines: [String] = []
        func check(_ label: String, _ ok: Bool) { lines.append("\(ok ? "PASS" : "FAIL")  \(label)") }
        let endpoint = "unix:///var/run/docker.sock"
        check("Docker accepts only an absolute local Unix endpoint", DockerResourceProbe.isLocalEndpoint(endpoint))
        check("Docker declines TCP SSH HTTP and relative socket endpoints", ["tcp://127.0.0.1:2375", "ssh://example", "http://example", "unix://remote/socket", "unix://relative", "unix:///"].allSatisfy { !DockerResourceProbe.isLocalEndpoint($0) })
        check("Docker declines endpoint control bytes queries and traversal", ["unix:///tmp/socket\n--help", "unix:///tmp/%00socket", "unix:///tmp/../socket", "unix:///tmp/socket?token=secret", "unix:///tmp/socket#fragment"].allSatisfy { !DockerResourceProbe.isLocalEndpoint($0) })
        let context = DockerResourceProbe.parseContext(Data("\"desktop-linux\"\t\"unix:///var/run/docker.sock\"\n".utf8))
        check("Docker context parser returns only selected name and endpoint", context?.name == "desktop-linux" && context?.endpoint == endpoint)
        check("Docker context parser rejects remote and ambiguous contexts", DockerResourceProbe.parseContext(Data("\"remote\"\t\"ssh://example\"\n".utf8)) == nil && DockerResourceProbe.parseContext(Data("\"a\"\t\"unix:///tmp/a\"\n\"b\"\t\"unix:///tmp/b\"\n".utf8)) == nil)
        let id = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let listed = DockerResourceProbe.arguments(endpoint: endpoint, operation: .containers)
        check("Docker list pins endpoint and does not use a shell or broad inspection", Array(listed?.prefix(3) ?? []) == ["--host", endpoint, "--tls=false"] && listed?.contains("--format") == true && listed?.contains("exec") == false && listed?.contains("inspect") == false)
        let measured = DockerResourceProbe.arguments(endpoint: endpoint, operation: .stats, containerIDs: [id])
        check("Docker stats is one-shot and scoped to full validated IDs", measured?.contains("--no-stream") == true && measured?.last == id)
        check("Docker refuses unsafe IDs empty stats and excessive scopes", ["--help", "a;rm", "$(whoami)", String(repeating: "a", count: 12)].allSatisfy { DockerResourceProbe.arguments(endpoint: endpoint, operation: .stats, containerIDs: [$0]) == nil } && DockerResourceProbe.arguments(endpoint: endpoint, operation: .stats) == nil && DockerResourceProbe.arguments(endpoint: endpoint, operation: .stats, containerIDs: Array(repeating: id, count: 33)) == nil)
        check("Docker remote endpoints never construct daemon arguments", DockerResourceProbe.arguments(endpoint: "ssh://example", operation: .containers) == nil)
        let containers = Data("\"\(id)\"\t\"server\"\t\"image:tag\"\t\"running\"\t\"Up 2 hours\"\t\"127.0.0.1:3000->3000/tcp\"\n".utf8)
        let parsed = DockerResourceProbe.parseContainers(containers)
        check("Docker list preserves only requested overview fields", parsed.count == 1 && parsed.first?.id == id && parsed.first?.name == "server" && parsed.first?.ports == "127.0.0.1:3000->3000/tcp")
        check("Docker missing stats remain unavailable", parsed.first?.cpuPercent == nil && parsed.first?.memoryUsage == nil)
        check("Docker malformed partial rows do not fabricate containers", DockerResourceProbe.parseContainers(Data("\"\(id)\"\t\"server".utf8)).isEmpty)
        var duplicate = containers; duplicate.append(containers)
        check("Docker duplicate container IDs collapse", DockerResourceProbe.parseContainers(duplicate).count == 1)
        let stats = DockerResourceProbe.parseStats(Data("\"\(id)\"\t\"200.5%\"\t\"32MiB / 2GiB\"\t\"1MB / 2MB\"\t\"0B / 0B\"\n\"\(other)\"\t\"--\"\t\"--\"\t\"N/A\"\t\"\"\n".utf8))
        check("Docker CPU convention allows more than one core", stats[id]?.cpuPercent == 200.5)
        check("Docker missing CPU memory and IO are nil", stats[other]?.cpuPercent == nil && stats[other]?.memoryUsage == nil && stats[other]?.networkIO == nil && stats[other]?.blockIO == nil)
        check("Docker selectors never request container arguments or environment", !DockerResourceProbe.containerFormat.contains("Command") && !DockerResourceProbe.containerFormat.contains("Env") && !DockerResourceProbe.statsFormat.contains("Env"))

        let assertionFixture = Data("""
        Assertion status system-wide:
           BackgroundTask                 0
           UserIsActive                   1
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 123(player): [0x000001ab] 00:03:22 PreventUserIdleSystemSleep named: "PRIVATE_DOCUMENT_TITLE"
           pid 456(powerd): [0x000002ab] 00:00:05 UserIsActive named: "PRIVATE_PATH"
        """.utf8)
        let assertions = SleepAssertionProbe.parse(assertionFixture)
        check("sleep parser reads summary counts and process assertion kind", assertions.available && assertions.summary["PreventUserIdleSystemSleep"] == 1 && assertions.assertions.count == 2 && assertions.assertions.first?.pid == 123 && assertions.assertions.first?.duration == "00:03:22")
        check("sleep parser omits document-bearing descriptive names", !assertions.assertions.contains { $0.processName.contains("PRIVATE") || $0.kind.contains("PRIVATE") || $0.duration.contains("PRIVATE") })
        check("ordinary activity is not mislabeled as a sleep blocker", SleepAssertionProbe.meaning("UserIsActive") == "User activity signal" && SleepAssertionProbe.meaning("PreventUserIdleSystemSleep") == "Prevents idle system sleep")
        check("unrecognized sleep format stays unavailable", !SleepAssertionProbe.parse(Data("format changed".utf8)).available)
        check("recognized empty sleep snapshot remains available", SleepAssertionProbe.parse(Data("Assertion status system-wide:\n PreventUserIdleSystemSleep 0\nListed by owning process:\n".utf8)).available)

        let renderer = BrowserResourceProbe.classify(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        check("browser renderer is a generic executable role", renderer?.browser == "Google Chrome" && renderer?.role == "Renderer helper")
        let gpu = BrowserResourceProbe.classify(path: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Helper (GPU).app/Contents/MacOS/Brave Browser Helper (GPU)")
        check("browser graphics helper category is exposed", gpu?.browser == "Brave" && gpu?.role == "Graphics helper")
        let firefox = BrowserResourceProbe.classify(path: "/Applications/Firefox.app/Contents/MacOS/plugin-container")
        check("unexposed browser helper role remains unknown", firefox?.role == "Helper · role unavailable")
        let webkit = BrowserResourceProbe.classify(path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        check("shared WebKit path is not assigned to Safari", webkit?.browser == "WebKit · owner unavailable")
        check("other Electron apps are not mislabeled as browsers", BrowserResourceProbe.classify(path: "/Applications/Editor.app/Contents/Frameworks/Editor Helper (Renderer).app/Contents/MacOS/Editor Helper (Renderer)") == nil)
        check("relative process paths have no browser attribution", BrowserResourceProbe.classify(path: "Google Chrome.app/Contents/MacOS/Google Chrome") == nil)
        // All checks are fixtures. No Docker daemon, power assertion, browser PID,
        // document, Bluetooth device, container environment or project is queried.
        return lines
    }
}
