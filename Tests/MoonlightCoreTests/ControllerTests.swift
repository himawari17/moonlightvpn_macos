import Foundation
import MoonlightCore

/// The pids of cores whose data directory is under `path` — the same way the
/// app itself tells its cores from another client's.
private func corePIDs(under path: String) -> [pid_t] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "mihomo.*\(path)"]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    pgrep.standardError = Pipe()
    guard (try? pgrep.run()) != nil else { return [] }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

/// Preferences that last as long as the test and never reach the disk.
///
/// A named suite would do for isolation, but emptying one afterwards leaves an
/// empty file in `~/Library/Preferences` for every machine the suite ever ran
/// on. `UserDefaults` reads and writes everything through these three.
private final class EphemeralDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() { super.init(suiteName: "vpn.moonlight.tests")! }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = nil
    }
}

/// Polls until `condition` holds, for up to `timeout` seconds.
@MainActor
private func eventually(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return await condition()
}

/// Drives the real controller over the real core — through a start with a
/// port taken, a connect, a core killed and a core hung under the tunnel, a
/// core that keeps dying, and a rest while nobody is looking.
///
/// The controller's surroundings are the test's own: a folder of its own for
/// the subscription and the core's home, preferences kept in memory, a helper
/// socket that does not exist and a proxy control that changes nothing.
/// So it can never reach the proxy settings of the Mac it runs on, nor the
/// helper — and the tunnel — of the person running it.
@MainActor
func controllerTests() async {
    let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/mihomo/mihomo")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        print("· controller tests skipped — run scripts/fetch-mihomo.sh first")
        return
    }

    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("moonlight-controller-\(UUID().uuidString)")
    let support = workspace.appendingPathComponent("Moonlight", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    // Nothing in it needs the network: the nodes are on loopback and the rules
    // name no geodata, so the core starts without downloading anything.
    let panel = """
    proxies:
      - {name: "🇳🇱 Amsterdam", type: ss, server: 127.0.0.1, port: 18081, cipher: aes-256-gcm, password: pw}
      - {name: "🇫🇮 Helsinki",  type: ss, server: 127.0.0.1, port: 18082, cipher: aes-256-gcm, password: pw}
    proxy-groups:
      - {name: "Панель", type: select, proxies: ["🇳🇱 Amsterdam", "🇫🇮 Helsinki"]}
    rules:
      - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
      - MATCH,Панель
    """
    try? panel.write(to: support.appendingPathComponent("subscription.yaml"),
                     atomically: true, encoding: .utf8)

    let defaults = EphemeralDefaults()
    let preferences = Preferences(defaults: defaults)
    // Only ever read for being there: nothing in these tests refreshes.
    preferences.subscriptionURL = "https://subscription.invalid/token"
    preferences.tunnelMode = .systemProxy
    let wantedController = 29_797
    preferences.controllerPort = wantedController
    preferences.mixedPort = 27_897

    // Something else already has the port the core's API wants — the state of
    // a Mac with another client's core running.
    let squatter = Squatter(port: wantedController)

    let tunnel = TunnelController(
        preferences: preferences,
        environment: TunnelController.Environment(
            support: support,
            helper: HelperClient(socketPath: workspace.appendingPathComponent("no-helper.sock").path),
            proxy: .none,
            parkDelay: 0.5,
            watchdogInterval: 1
        )
    )
    func api() -> MihomoAPI {
        MihomoAPI(port: preferences.controllerPort, secret: preferences.coreSecret)
    }
    func cores() -> [pid_t] { corePIDs(under: workspace.path) }
    func lastLog() -> String {
        LogStore.shared.entries.suffix(12).map(\.message).joined(separator: "\n    ")
    }

    Check.currentSuite = "Controller · a core that starts on a Mac where its port is taken"
    let started = await tunnel.ensureCoreRunning()
    Check.isTrue(started, "the core starts — log:\n    \(lastLog())")
    Check.isTrue(squatter != nil && preferences.controllerPort != wantedController,
                 "its API moved off the port something else holds")
    Check.isTrue(await api().answers(), "and answers on the port it moved to")
    Check.equal(tunnel.nodes.count, 2, "the servers are read from it")
    Check.isNil(tunnel.issue, "with nothing to report")
    squatter?.leave()

    Check.currentSuite = "Controller · the idle core comes back when it dies"
    let idle = cores()
    Check.equal(idle.count, 1, "one core is running")
    idle.forEach { kill($0, SIGKILL) }
    let idleBack = await eventually(15) {
        let now = cores()
        guard now.count == 1, now != idle else { return false }
        return await api().answers()
    }
    Check.isTrue(idleBack, "a new core is up without anyone asking — log:\n    \(lastLog())")

    Check.currentSuite = "Controller · a core killed under the tunnel"
    await tunnel.connect()
    Check.equal(tunnel.state, .connected, "connected — log:\n    \(lastLog())")
    await tunnel.select(node: "🇫🇮 Helsinki")
    let carrying = cores()
    carrying.forEach { kill($0, SIGKILL) }
    let recovered = await eventually(20) {
        let now = cores()
        return tunnel.state == .connected && now.count == 1 && now != carrying
    }
    Check.isTrue(recovered, "the tunnel is up again on a new core — log:\n    \(lastLog())")
    Check.isNil(tunnel.issue, "and nothing was reported to the user")
    let chosen = try? await api().groups().first { $0.name == "Панель" }?.now
    Check.equal(chosen, "🇫🇮 Helsinki", "the new core is on the server that was chosen")

    Check.currentSuite = "Controller · a core that hangs under the tunnel"
    // Stopped, not killed: the process is there and says nothing, which no
    // exit handler reports — only asking it finds out.
    let hung = cores()
    hung.forEach { kill($0, SIGSTOP) }
    let unhung = await eventually(45) {
        let now = cores()
        return tunnel.state == .connected && now.count == 1 && now != hung
    }
    Check.isTrue(unhung, "the watchdog replaced it — log:\n    \(lastLog())")
    Check.isNil(tunnel.issue, "again with nothing reported")
    // Had the restart failed, the hung core would be left stopped for ever.
    hung.forEach { kill($0, SIGKILL) }

    Check.currentSuite = "Controller · a core that keeps dying"
    // The third restart of this session is still made…
    let third = cores()
    third.forEach { kill($0, SIGKILL) }
    let thirdBack = await eventually(20) {
        let now = cores()
        return tunnel.state == .connected && now.count == 1 && now != third
    }
    Check.isTrue(thirdBack, "a third restart goes through — log:\n    \(lastLog())")
    // …and the fourth is not: the tunnel comes down and says why.
    cores().forEach { kill($0, SIGKILL) }
    let gaveUp = await eventually(20) {
        if case .failed = tunnel.state { return true }
        return false
    }
    Check.isTrue(gaveUp, "after that the tunnel is brought down — log:\n    \(lastLog())")
    Check.equal(tunnel.issue, .coreStopped, "and the user is told the core stopped")
    let listBack = await eventually(15) { await api().answers() }
    Check.isTrue(listBack, "the idle core is still there for the server list")
    Check.equal(tunnel.issue, .coreStopped, "without taking the explanation away")

    Check.currentSuite = "Controller · the idle core rests while nobody is looking"
    tunnel.setWatched(false)
    let rested = await eventually(10) { cores().isEmpty }
    Check.isTrue(rested, "with nothing connected and nothing on screen, the core is stopped")
    tunnel.setWatched(true)
    let woken = await eventually(15) {
        guard cores().count == 1 else { return false }
        return await api().answers()
    }
    Check.isTrue(woken, "and it is back as soon as something is on screen — log:\n    \(lastLog())")

    if let server = SubscriptionServer() {
        await refreshTests(tunnel: tunnel, preferences: preferences, server: server,
                           subscription: support.appendingPathComponent("subscription.yaml"),
                           lastLog: lastLog)
        server.stop()
    } else {
        Check.isTrue(false, "a loopback subscription server could be opened for the refresh tests")
    }

    await tunnel.shutdown()
    _ = await eventually(5) { cores().isEmpty }
    cores().forEach { kill($0, SIGKILL) }
}

/// Refreshes through the controller, from a subscription server on loopback,
/// on the core the tests above left running.
@MainActor
private func refreshTests(
    tunnel: TunnelController, preferences: Preferences, server: SubscriptionServer,
    subscription: URL, lastLog: () -> String
) async {
    preferences.subscriptionURL = server.url

    Check.currentSuite = "Controller · servers in the subscription's order"
    // `include-all` hands the servers to the group sorted by name — Berlin,
    // Helsinki, Amsterdam — whatever order the subscription lists them in.
    server.body = """
    proxies:
      - {name: "🇳🇱 Amsterdam", type: ss, server: 127.0.0.1, port: 18081, cipher: aes-256-gcm, password: pw}
      - {name: "🇫🇮 Helsinki",  type: ss, server: 127.0.0.1, port: 18082, cipher: aes-256-gcm, password: pw}
      - {name: "🇩🇪 Berlin",    type: ss, server: 127.0.0.1, port: 18083, cipher: aes-256-gcm, password: pw}
    proxy-groups:
      - {name: "Панель", type: select, include-all: true, proxies: ["Авто"]}
      - {name: "Авто", type: url-test, include-all: true, lazy: true, url: "http://127.0.0.1:9/", interval: 300}
    rules:
      - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
      - MATCH,Панель
    """
    let ordered = await tunnel.refresh()
    Check.equal(ordered, .updated, "the refresh goes through — log:\n    \(lastLog())")
    Check.equal(tunnel.nodes.map(\.name), ["Авто", "🇳🇱 Amsterdam", "🇫🇮 Helsinki", "🇩🇪 Berlin"],
                "in the subscription's order, not sorted by name")
    Check.isNil(tunnel.issue, "with nothing to report")

    Check.currentSuite = "Controller · a refresh that brings no servers"
    let shown = tunnel.nodes.map(\.name)
    let kept = try? String(contentsOf: subscription, encoding: .utf8)
    server.body = """
    proxies:
      - {name: "→ No hosts found", type: vless, server: 0.0.0.0, port: 1, uuid: 00000000-0000-0000-0000-000000000000}
    proxy-groups:
      - {name: "Панель", type: select, include-all: true}
    rules:
      - MATCH,Панель
    """
    let empty = await tunnel.refresh()
    Check.equal(empty, .failed, "it is not taken as an update")
    Check.equal(tunnel.issue, .noServersSent, "the user is told the list was kept")
    Check.equal(tunnel.nodes.map(\.name), shown, "the servers on screen stay")
    Check.equal(try? String(contentsOf: subscription, encoding: .utf8), kept,
                "and so does the subscription on disk")

    Check.currentSuite = "Controller · a refresh stopped half way"
    server.body = """
    proxies:
      - {name: "🇳🇱 Amsterdam", type: ss, server: 127.0.0.1, port: 18081, cipher: aes-256-gcm, password: pw}
    proxy-groups:
      - {name: "Панель", type: select, proxies: ["🇳🇱 Amsterdam"]}
    rules:
      - MATCH,Панель
    """
    server.delay = 30
    let refreshing = Task { await tunnel.refresh() }
    let offered = await eventually(8) { tunnel.canStopRefresh }
    Check.isTrue(offered, "a refresh that drags on offers to stop")
    let stoppedAt = Date()
    tunnel.cancelRefresh()
    let stopped = await refreshing.value
    Check.equal(stopped, .cancelled, "and stops when asked")
    Check.isTrue(Date().timeIntervalSince(stoppedAt) < 3, "at once, rather than waiting the server out")
    Check.equal(tunnel.nodes.map(\.name), shown, "with the servers untouched")
    Check.isTrue(!tunnel.isRefreshing && !tunnel.canStopRefresh, "and nothing left in flight")
    server.delay = 0
}
