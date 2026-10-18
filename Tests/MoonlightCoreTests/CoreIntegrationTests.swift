import Foundation
import MoonlightCore

/// Runs the real mihomo binary.
///
/// The unit tests above check that the generated YAML *says* the right thing;
/// only the core can say whether it will *load* it. Every config shape this app
/// can produce goes through `mihomo -t` here, and one of them is started for
/// real so the RESTful API — which is the app's entire control channel — is
/// exercised rather than assumed.
///
/// Skipped with a clear message when the core is absent, since it is fetched
/// rather than committed (`scripts/fetch-mihomo.sh`).
func coreIntegrationTests() {
    let core = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/mihomo/mihomo")

    guard FileManager.default.isExecutableFile(atPath: core.path) else {
        print("· core integration skipped — run scripts/fetch-mihomo.sh first")
        return
    }

    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("moonlight-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let panel = """
    proxies:
      - {name: "🇳🇱 Amsterdam", type: ss, server: 127.0.0.1, port: 18081, cipher: aes-256-gcm, password: pw}
      - {name: "🇫🇮 Helsinki",  type: ss, server: 127.0.0.1, port: 18082, cipher: aes-256-gcm, password: pw}
    proxy-groups:
      - {name: "Панель", type: select, proxies: ["Быстрый", "🇳🇱 Amsterdam", "🇫🇮 Helsinki"]}
      - {name: "Быстрый", type: url-test, proxies: ["🇳🇱 Amsterdam", "🇫🇮 Helsinki"], url: "https://www.gstatic.com/generate_204", interval: 300}
    rules:
      - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
      - MATCH,Панель
    """

    // A port unlikely to collide with a core the developer is actually running.
    let controllerPort = 19_797
    let secret = "test-secret"
    // The app's own layout: the core's home is a folder inside the app's.
    let home = workspace.appendingPathComponent("core", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // And the app's own geo databases, which it puts in the core's home before
    // the core looks. Without them every GEOSITE rule sent the core to GitHub
    // for GeoSite.dat, and a dropped download failed a config that was fine.
    // A checkout that never fetched them has none, and downloads as before.
    let bundledGeodata = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/geodata")
    let process = MihomoProcess(binary: core, dataDirectory: home, geodata: bundledGeodata)

    func overrides(_ mode: TunnelMode, _ rules: [RoutingRule] = []) -> MihomoConfig.Overrides {
        MihomoConfig.Overrides(
            controllerPort: controllerPort, secret: secret, mixedPort: 17_897,
            mode: mode, routingRules: rules, dataDirectory: home.path
        )
    }

    // And every kind of the user's own rules, both ways round, pointed at each
    // kind of target — but IP-ASN, whose database the app does not ship: the
    // core would download it on every run, and a dropped download would fail
    // a config that was fine. What a blocked one comes to is checked below.
    let everyOwnRule = RoutingRule.Kind.allCases.filter { !$0.needsDownload }.enumerated().map { index, kind in
        RoutingRule(kind: kind, value: kind.placeholder,
                    target: ["DIRECT", "REJECT", "Панель"][index % 3],
                    priority: index.isMultiple(of: 2) ? .override : .extend)
    }

    Check.suite("Core · every generated config loads") {
        // TUN is validated but never started: creating a utun interface needs
        // root, and a test suite must not ask for it.
        let shapes: [(String, MihomoConfig.Overrides)] = [
            ("system proxy", overrides(.systemProxy)),
            ("tun", overrides(.tun)),
            ("own rules", overrides(.systemProxy, everyOwnRule)),
            ("tun + own rules", overrides(.tun, everyOwnRule)),
        ]
        for (name, override) in shapes {
            let path = workspace.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).yaml")
            do {
                let yaml = try MihomoConfig.build(panelYAML: panel, overrides: override)
                try yaml.write(to: path, atomically: true, encoding: .utf8)
                try process.validate(configPath: path)
                Check.isTrue(true, "\(name) config loads")
            } catch {
                Check.isTrue(false, "\(name) config loads — \(error)")
            }
        }
    }

    Check.suite("Core · which exits are unexpected") {
        let path = process.configURL
        final class Exits: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func note() { lock.lock(); count += 1; lock.unlock() }
            var seen: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let exits = Exits()
        process.onUnexpectedExit = { _ in exits.note() }
        defer { process.onUnexpectedExit = nil }
        func settle(until done: () -> Bool = { false }) {
            let deadline = Date().addingTimeInterval(3)
            while !done(), Date() < deadline { usleep(50_000) }
        }
        do {
            let yaml = try MihomoConfig.build(panelYAML: panel, overrides: overrides(.systemProxy))
            try yaml.write(to: path, atomically: true, encoding: .utf8)

            // Asked to stop: not a crash.
            try process.start(configPath: path)
            process.stop()
            settle()
            Check.equal(exits.seen, 0, "a core that was stopped did not exit unexpectedly")

            // Replaced by the next start: the old one's exit is not the new
            // one's crash — which is what a single "stopping" flag made of it.
            try process.start(configPath: path)
            try process.start(configPath: path)
            settle()
            Check.equal(exits.seen, 0, "nor did one replaced by the next start")
            Check.isTrue(process.isRunning, "and the replacement is the one left running")

            // Killed from outside: that is the one to report.
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", "mihomo.*\(home.path)"]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            try pgrep.run()
            let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            pgrep.waitUntilExit()
            found.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.forEach { kill($0, SIGKILL) }
            settle { exits.seen > 0 }
            Check.equal(exits.seen, 1, "a core killed from outside is reported, once")
            Check.isTrue(!process.isRunning, "and is no longer counted as running")
        } catch {
            Check.isTrue(false, "the core starts — \(error)")
        }
        process.stop()
    }

    Check.suite("Core · a core whose API port is taken") {
        // The behaviour the port check exists for, pinned: the core does not
        // exit when it cannot bind its controller. It logs one line and runs
        // on without an API — alive, and never going to answer.
        guard let squatter = Squatter(port: controllerPort) else {
            Check.isTrue(false, "the test could take the controller port")
            return
        }
        defer { squatter.leave() }
        let path = process.configURL
        do {
            let yaml = try MihomoConfig.build(panelYAML: panel, overrides: overrides(.systemProxy))
            try yaml.write(to: path, atomically: true, encoding: .utf8)
            try process.start(configPath: path)
        } catch {
            Check.isTrue(false, "the core starts — \(error)")
            return
        }
        defer { process.stop() }
        let deadline = Date().addingTimeInterval(8)
        while !process.recentLog.contains("External controller listen error"), Date() < deadline {
            usleep(100_000)
        }
        Check.isTrue(process.recentLog.contains("External controller listen error"),
                     "it says so in the words the app looks for — log:\n\(process.recentLog)")
        Check.isTrue(process.isRunning, "and keeps running without its API")
    }

    Check.suite("Core · RESTful API") {
        let path = process.configURL
        do {
            let yaml = try MihomoConfig.build(panelYAML: panel, overrides: overrides(.systemProxy))
            try yaml.write(to: path, atomically: true, encoding: .utf8)
            try process.start(configPath: path)
        } catch {
            Check.isTrue(false, "core starts — \(error)")
            return
        }
        defer { process.stop() }

        let api = MihomoAPI(port: controllerPort, secret: secret)
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            defer { semaphore.signal() }

            guard await api.waitUntilReady(timeout: 40) else {
                Check.isTrue(false, "core answers its API — log:\n\(process.recentLog)")
                return
            }
            Check.isTrue(true, "core answers its API")

            do {
                let groups = try await api.groups()
                let selector = groups.first { $0.name == "Панель" }
                Check.notNil(selector, "the panel's own selector is visible over the API")
                // The selector's list is offered verbatim, groups included: a
                // panel puts its balancers and auto-picker there deliberately,
                // and filtering them out leaves the user picking raw nodes the
                // operator never meant to offer directly.
                let nodes = try await api.nodes(in: "Панель")
                Check.equal(nodes.count, 3, "everything the selector offers is listed")
                Check.equal(nodes.first?.name, "Быстрый", "in the order the selector lists them")
                Check.isTrue(nodes.first?.isGroup == true, "a url-test group is marked as a group")
                Check.equal(nodes.filter { !$0.isGroup }.map(\.name),
                            ["🇳🇱 Amsterdam", "🇫🇮 Helsinki"],
                            "plain nodes keep their names, emoji and all")

                // Selecting is the whole of "pick a server", and the name has to
                // survive being put in a URL path.
                try await api.select(node: "🇫🇮 Helsinki", in: "Панель")
                let after = try await api.groups().first { $0.name == "Панель" }
                Check.equal(after?.now, "🇫🇮 Helsinki", "selection round-trips through the API")

                // Every subscription refresh reloads the running core from the
                // file the app just wrote. mihomo refuses a path outside its
                // home directory, so a config kept anywhere else starts fine and
                // then fails each refresh.
                try await api.reload(path: path.path)
                Check.isTrue(true, "the core reloads the config the app writes")

                let traffic = try await api.totals()
                Check.isTrue(traffic.up >= 0 && traffic.down >= 0, "traffic counters read")

                // An unreachable node reports nil rather than throwing: a
                // timeout is the expected answer for a node that is down.
                let delay = await api.delay(node: "🇳🇱 Amsterdam", timeout: 1500)
                Check.isNil(delay, "an unreachable node measures as unknown, not as an error")

                // Who opened a connection. The core says, where the system
                // lets it read the socket table; where it does not — macOS 27
                // — the app has to find out for itself. Either way the
                // connections page needs a program to put the row under.
                if let target = LoopbackSocket(), let client = LoopbackSocket(connectTo: 17_897) {
                    let destination = "127.0.0.1:\(target.listenerPort)"
                    let reply = client.exchange("CONNECT \(destination) HTTP/1.1\r\nHost: \(destination)\r\n\r\n")
                    Check.isTrue(reply.contains(" 200 "), "the core carries a connection to a local port")
                    var mine: MihomoAPI.Connection?
                    for _ in 0..<30 where mine == nil {
                        mine = try await api.connections().first { $0.host == destination }
                        if mine == nil { try await Task.sleep(nanoseconds: 100_000_000) }
                    }
                    Check.equal(mine?.process, URL(fileURLWithPath: ownExecutable).lastPathComponent,
                                "a connection is named after the program that opened it")
                    Check.equal(mine.map { URL(fileURLWithPath: $0.processPath).resolvingSymlinksInPath().path },
                                ownExecutable, "and carries its path, which is where the row's icon comes from")
                    client.close()
                    target.close()
                } else {
                    Check.isTrue(false, "loopback sockets open")
                }
            } catch {
                Check.isTrue(false, "API calls succeed — \(error)")
            }
        }

        _ = semaphore.wait(timeout: .now() + 90)
        Check.isTrue(process.isRunning, "the core stayed up through the whole exchange")
    }

    // The first launch, where the download is blocked: the core needs its geo
    // databases to parse the rules every subscription has, and gets them from
    // the bundle or not at all. `geox-url` is where it would download them
    // from; pointed at a closed port, any attempt fails at once.
    guard Geodata.files(in: bundledGeodata).count == Geodata.fileNames.count else {
        print("· geodata check skipped — run scripts/fetch-geodata.sh first")
        return
    }

    Check.suite("Core · geodata without the network") {
        let geoPanel = """
        geox-url:
          geosite: "http://127.0.0.1:9/geosite.dat"
          mmdb: "http://127.0.0.1:9/geoip.metadb"
          geoip: "http://127.0.0.1:9/geoip.dat"
          asn: "http://127.0.0.1:9/asn.mmdb"
        proxies:
          - {name: "🇳🇱 Amsterdam", type: ss, server: 127.0.0.1, port: 18081, cipher: aes-256-gcm, password: pw}
        proxy-groups:
          - {name: "Панель", type: select, proxies: ["🇳🇱 Amsterdam"]}
        rules:
          - GEOSITE,category-ru,DIRECT
          - GEOIP,RU,DIRECT
          - MATCH,Панель
        """
        let config = workspace.appendingPathComponent("geodata.yaml")
        try MihomoConfig.build(panelYAML: geoPanel, overrides: overrides(.systemProxy))
            .write(to: config, atomically: true, encoding: .utf8)

        // The control. Without it the check below would pass just as well if
        // the core had stopped needing these files, or had reached the network.
        let emptyHome = workspace.appendingPathComponent("geodata-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        do {
            try MihomoProcess(binary: core, dataDirectory: emptyHome).validate(configPath: config)
            Check.isTrue(false, "an empty home with no network cannot load a GEOSITE rule")
        } catch {
            Check.isTrue(error.localizedDescription.contains("can't download GeoSite.dat"),
                         "an empty home with no network fails on the download — \(error.localizedDescription)")
        }

        // And the app's own way in: a home that has never seen a core, given
        // to a process that knows where the bundled files are.
        let freshHome = workspace.appendingPathComponent("geodata-fresh", isDirectory: true)
        let seeded = MihomoProcess(binary: core, dataDirectory: freshHome, geodata: bundledGeodata)
        do {
            try seeded.validate(configPath: config)
            Check.isTrue(true, "a freshly seeded home loads GEOSITE and GEOIP rules with no network")
        } catch {
            Check.isTrue(false, "a freshly seeded home loads GEOSITE and GEOIP rules with no network — \(error)")
        }
        Check.equal(try FileManager.default.contentsOfDirectory(atPath: freshHome.path).sorted(),
                    Geodata.fileNames.sorted(),
                    "validating is what put the files there, and the core added none")

        // IP-ASN's database is the one the app does not ship. Blocked, it
        // keeps the config from loading — and is said as a download that did
        // not go through, not as the core failing.
        let asnConfig = workspace.appendingPathComponent("asn.yaml")
        let asnRule = RoutingRule(kind: .ipASN, value: RoutingRule.Kind.ipASN.placeholder,
                                  target: "DIRECT", priority: .override)
        try MihomoConfig.build(panelYAML: geoPanel, overrides: overrides(.systemProxy, [asnRule]))
            .write(to: asnConfig, atomically: true, encoding: .utf8)
        do {
            try seeded.validate(configPath: asnConfig)
            Check.isTrue(false, "an IP-ASN rule does not load with its download blocked")
        } catch {
            Check.equal(TunnelIssue.classify(error), .databaseBlocked(asn: true),
                        "a blocked IP-ASN download is told apart from a failed core")
        }
    }
}
