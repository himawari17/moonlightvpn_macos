import Foundation
import Combine
import Yams

/// The single object the UI drives and observes.
///
/// It owns the order things happen in, which for a tunnel is not
/// interchangeable — the comments on ``connect()`` say why each step is where it
/// is. Everything below it (the core process, the helper, the REST API, the
/// panel) is stateless with respect to the others.
@MainActor
public final class TunnelController: ObservableObject {

    // MARK: Published state

    @Published public private(set) var state: ConnectionState = .disconnected
    @Published public private(set) var nodes: [Node] = []
    @Published public private(set) var info = SubscriptionInfo()
    @Published public private(set) var subscriptionSource: SubscriptionClient.Source?
    /// Uptime and speeds, which tick every second — see ``TrafficMeter`` for
    /// why they are not published here.
    public let meter = TrafficMeter()
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isPinging = false
    /// Nodes whose probe has not come back yet in the current pass.
    ///
    /// Per node, not one flag for the whole pass: a single flag made every row
    /// show `…` until the slowest node timed out, which hid the results that had
    /// already arrived and made an otherwise streaming measurement look like it
    /// took as long as its worst entry.
    @Published public private(set) var pendingProbes: Set<String> = []
    /// What went wrong last, as a kind the app words for the user. Cleared by
    /// the next success of the same thing.
    @Published public private(set) var issue: TunnelIssue?
    @Published public private(set) var lastRefresh: Date?

    @Published public var selectedNode: String?
    @Published public var autoSelect: Bool
    /// Rules, everything through the server, or nothing — see ``RoutingMode``.
    @Published public private(set) var routingMode: RoutingMode
    /// How traffic reaches the core: the system proxy, or TUN through the
    /// helper. Published rather than read from the preferences, so a switch
    /// made while disconnected — which changes nothing else — still redraws
    /// the controls showing it.
    @Published public private(set) var tunnelMode: TunnelMode
    /// The subscription's proxy groups, in its order — what a rule of the
    /// user's own can point at besides `DIRECT` and `REJECT`.
    @Published public private(set) var ruleTargets: [String] = []
    /// The subscription's own rules, as it wrote them.
    @Published public private(set) var profileRules: [String] = []

    // MARK: Collaborators

    /// What the controller needs from the machine around it, and how patient
    /// it is. The app runs on ``live``; the test suite hands in its own, so it
    /// can take a real core through a connect, a crash and a restart without
    /// touching this Mac's proxy settings, the installed helper, or the tunnel
    /// of whoever is running it.
    public struct Environment: Sendable {
        /// Where the subscription and the core's home are kept.
        public var support: URL
        public var helper: HelperClient
        public var proxy: ProxyControl
        /// How long the idle core is left running with nothing of the app on
        /// screen and nothing connected.
        public var parkDelay: TimeInterval
        /// How often a connected core is asked whether it is still there.
        public var watchdogInterval: TimeInterval

        public init(
            support: URL,
            helper: HelperClient = HelperClient(),
            proxy: ProxyControl = .system,
            parkDelay: TimeInterval = 180,
            watchdogInterval: TimeInterval = 15
        ) {
            self.support = support
            self.helper = helper
            self.proxy = proxy
            self.parkDelay = parkDelay
            self.watchdogInterval = watchdogInterval
        }

        public static var live: Environment {
            Environment(support: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Moonlight", isDirectory: true))
        }
    }

    private let preferences: Preferences
    private let environment: Environment
    private let core: MihomoProcess
    private let helper: HelperClient
    private let proxy: ProxyControl
    private let subscriptions: SubscriptionClient
    private var api: MihomoAPI

    private let support: URL
    private let coreBinary: URL
    private let helperBinary: URL
    private let geodata: URL
    /// The helper core's version as last read, so the check costs a process
    /// launch once rather than on every connect.
    private var configURL: URL { core.configURL }
    private var panelURL: URL { support.appendingPathComponent("subscription.yaml") }

    /// The proxy group the app steers. Discovered from the running core rather
    /// than assumed — see ``MihomoConfig/primarySelectorName(groups:rules:)``.
    private var selectorGroup: String?
    private var trafficTask: Task<Void, Never>?
    private var uptimeTimer: Timer?
    /// The idle core's start while it is under way, so a second caller waits
    /// for it instead of starting another — see ``ensureCoreRunning()``.
    private var coreStartup: Task<Bool, Never>?
    /// Set while one core hands over to another: the idle one stopping for
    /// TUN's privileged one, or either stopping on a disconnect. That work
    /// waits off the main thread, and an idle core started in the gap — by a
    /// ping or a refresh — would take the ports the other one needs.
    private var coreHandover = false
    private var startedAt: Date?
    /// Which transport actually started the core, so teardown undoes the same
    /// one even if the preference changed while connected.
    private var activeMode: TunnelMode?

    // Keeping the core alive — see "Keeping the core up" below.

    /// Restarts left before a core that keeps dying is given up on.
    private var restartBudget = RestartBudget()
    /// Set while the tunnel's core is being restarted on purpose — brought back
    /// after it died, or reloaded under TUN — so the exit handler and the
    /// watchdog do not take that for another death and restart it again.
    private var restarting = false
    private var watchdog: Task<Void, Never>?
    /// Whether anything of the app is on screen — see ``setWatched(_:)``.
    private var watched = true
    /// The wait before the idle core is rested — see ``parkWhenIdle()``.
    private var parking: Task<Void, Never>?
    /// The app is on its way out: nothing is to be started any more.
    private var quitting = false

    public init(
        preferences: Preferences = .shared,
        bundle: Bundle = .main,
        environment: Environment = .live
    ) {
        self.preferences = preferences
        self.environment = environment
        helper = environment.helper
        proxy = environment.proxy
        self.subscriptions = SubscriptionClient(device: DeviceIdentity(
            hwid: preferences.hwid,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: Self.hardwareModel(),
            appVersion: bundle.appVersion
        ))

        support = environment.support
        // The core's home as well, since its config is written there before
        // the core first starts.
        let coreHome = support.appendingPathComponent("core", isDirectory: true)
        try? FileManager.default.createDirectory(at: coreHome, withIntermediateDirectories: true)
        // Where the config lived before it moved into the core's home.
        try? FileManager.default.removeItem(at: support.appendingPathComponent("config.yaml"))

        coreBinary = bundle.coreBinaryURL
        helperBinary = bundle.helperBinaryURL
        geodata = bundle.geodataURL
        core = MihomoProcess(binary: bundle.coreBinaryURL, dataDirectory: coreHome,
                             geodata: bundle.geodataURL)
        api = MihomoAPI(port: preferences.controllerPort, secret: preferences.coreSecret)

        selectedNode = preferences.selectedNode
        autoSelect = preferences.autoSelect
        routingMode = preferences.routingMode
        tunnelMode = preferences.tunnelMode
        lastRefresh = preferences.lastRefresh
        // Cached figures outlive the subscription they describe, and a fresh
        // install that inherited them from a removed plan would show days and
        // traffic for a subscription that is not there.
        if preferences.subscriptionURL?.isEmpty == false {
            var cached = preferences.cachedInfo ?? SubscriptionInfo()
            // Cached by an older build that read Remnawave's "never expires"
            // (a date in 2099) literally; fixed at the next refresh anyway.
            if let expire = cached.expire, SubscriptionInfo.expiry(expire) == nil {
                cached.expire = nil
            }
            info = cached
        } else {
            preferences.cachedInfo = nil
            info = SubscriptionInfo()
        }

        core.onUnexpectedExit = { [weak self] status in
            Task { @MainActor in
                self?.handleCoreExit(status)
            }
        }

        recoverFromCrash()
        retireSplitTunnelling()

        // Warm the core as soon as there is a subscription, so the first latency
        // pass is instant rather than paying for a cold start. The redactions
        // go first: the core's log quotes server addresses.
        Task {
            await updateRedactions()
            await refreshRoutingInputs()
            await ensureCoreRunning()
        }
        Task { await refreshHelperStatus() }
    }

    /// The panel's own auto-picker, if its selector offers one.
    ///
    /// Taken in the selector's order, so a panel that lists a general picker
    /// first and country-specific ones later gets the general one — those later
    /// ones are named for a country and belong in the list as ordinary rows.
    public var panelAutoNode: Node? {
        nodes.first { $0.isAutoPicker }
    }

    /// Everything the selector offers except the picker promoted to the top,
    /// so it is not listed twice.
    public var selectableNodes: [Node] {
        guard let auto = panelAutoNode else { return nodes }
        return nodes.filter { $0.name != auto.name }
    }

    public var hasSubscription: Bool {
        preferences.subscriptionURL?.isEmpty == false
    }

    /// Whether `link` is the subscription already in use — so a link that
    /// adds it again can say it will be updated rather than replaced.
    public func isCurrentSubscription(_ link: String) -> Bool {
        guard let current = preferences.subscriptionURL.flatMap(SubscriptionClient.normalize) else {
            return false
        }
        return SubscriptionClient.normalize(link) == current
    }

    /// Whether a previously fetched subscription is on disk, so there is
    /// something to show and run before the network answers.
    public var hasCachedSubscription: Bool {
        FileManager.default.fileExists(atPath: panelURL.path)
    }
    public var helperInstalled: Bool { HelperInstaller.isInstalled && helper.isInstalled }

    /// Whether the installed helper is this build's — its program and the core
    /// it runs. See ``refreshHelperStatus()``, which is what sets it.
    ///
    /// The helper and its root-owned copy of the core are made when it is
    /// installed, and nothing updated them afterwards. An app update that
    /// needed a newer core (the service's XHTTP servers need 1.19.30 or later)
    /// left TUN on the old one; one that fixed the helper itself (it ignored
    /// SIGTERM until 1.6.4) never reached anyone who had it installed.
    @Published public private(set) var helperIsCurrent = true

    /// Compares the installed helper with this build's, off the main thread.
    ///
    /// Stored and refreshed rather than computed where it is read: reading the
    /// core's version means launching it and waiting, and `waitUntilExit`
    /// spins the calling thread's run loop. Asked from inside the Settings
    /// view, that ran a layout pass in the middle of the one being drawn, and
    /// SwiftUI aborted — opening Settings crashed the app.
    public func refreshHelperStatus() async {
        guard helperInstalled else {
            helperIsCurrent = true
            return
        }
        let helperBinary = helperBinary, coreBinary = coreBinary
        helperIsCurrent = await Task.detached(priority: .utility) {
            let bundledCore = MihomoProcess.version(of: coreBinary)
            let installedCore = MihomoProcess.version(of: HelperInstaller.installedCore)
            // A build run outside an app bundle has no helper of its own to
            // compare, and should not keep asking to install one.
            let helperMatches = !FileManager.default.fileExists(atPath: helperBinary.path)
                || FileManager.default.contentsEqual(atPath: helperBinary.path,
                                                     andPath: HelperInstaller.installedHelper.path)
            return helperMatches && (bundledCore == nil || bundledCore == installedCore)
        }.value
    }

    /// Replaces the helper's copy of the core with this build's — the one admin
    /// prompt the install itself asks for.
    public func updateHelper() async throws {
        LogStore.shared.client("Updating the system helper to this build's core")
        let helperBinary = helperBinary, coreBinary = coreBinary, geodata = geodata
        try await Task.detached(priority: .userInitiated) {
            try HelperInstaller.install(helper: helperBinary, core: coreBinary,
                                        geodata: Geodata.files(in: geodata))
        }.value
        // launchd takes a moment to bring the daemon back and open its socket.
        for _ in 0..<30 {
            if (try? helper.version()) != nil { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        await refreshHelperStatus()
    }

    /// The core's own log tail, for the settings screen's diagnostics.
    public var coreLog: String {
        activeMode == .tun ? ((try? helper.status().log) ?? "") : core.recentLog
    }

    /// ``coreLog``, read off the main thread: in TUN mode it is a round trip
    /// to the helper.
    private func readCoreLog() async -> String {
        let helper = helper, core = core, tun = activeMode == .tun
        return await offMain { tun ? ((try? helper.status().log) ?? "") : core.recentLog }
    }

    /// Runs blocking work — a child process, a round trip to the helper, a
    /// parse of the whole subscription — off the main actor.
    ///
    /// All of it used to run on the main thread. A connect ran `networksetup`
    /// seven times per network service, the helper's stop waits for its core
    /// to exit, `mihomo -t`
    /// loads the whole config, and the subscription was parsed three times
    /// over: the window froze for a second or more at exactly the moment the
    /// moon was animating, and again after every refresh.
    nonisolated private func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    nonisolated private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// ``offMain(_:)`` with idle-core starts held off until it is done — see
    /// ``coreHandover``.
    private func handingOver<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        coreHandover = true
        defer { coreHandover = false }
        return try await offMain(work)
    }

    // MARK: - Subscription

    /// Adds a subscription and fetches it. The design promises a link from the
    /// bot "adds itself", so this both stores and loads rather than only storing.
    ///
    /// The link is only kept once it has actually loaded. It used to be stored
    /// first, so a mistyped link — or a server having a bad minute — replaced a
    /// working subscription with one that loads nothing.
    @discardableResult
    public func importSubscription(_ url: String) async -> Bool {
        guard SubscriptionClient.normalize(url) != nil else {
            issue = .invalidLink
            return false
        }
        return await refresh(from: url.trimmingCharacters(in: .whitespacesAndNewlines), adopting: true)
    }

    public func removeSubscription() async {
        if state != .disconnected { await disconnect() }
        preferences.subscriptionURL = nil
        preferences.cachedInfo = nil
        preferences.selectedNode = nil
        preferences.serverDescriptions = [:]
        preferences.lastRefresh = nil
        lastRefresh = nil
        issue = nil
        try? FileManager.default.removeItem(at: panelURL)
        nodes = []
        info = SubscriptionInfo()
        subscriptionSource = nil
        selectedNode = nil
        ruleTargets = []
        profileRules = []
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard let url = preferences.subscriptionURL else { return false }
        return await refresh(from: url, adopting: false)
    }

    /// The intervals offered, in hours; 0 is never.
    nonisolated public static let autoUpdateChoices = [0, 1, 6, 12, 24]

    /// The offered interval nearest to `hours`. The service may suggest any
    /// number; snapping it here means the switch always shows what will happen.
    nonisolated public static func autoUpdateChoice(nearest hours: Int) -> Int {
        autoUpdateChoices.min { abs($0 - hours) < abs($1 - hours) } ?? 24
    }

    /// The effective auto-update interval in hours, 0 for never: the user's
    /// choice, or else what the service suggests, or else a day.
    public var autoUpdateHours: Int {
        Self.autoUpdateChoice(nearest: preferences.autoUpdateHours ?? info.updateIntervalHours ?? 24)
    }

    /// Refreshes if the interval has passed since the last successful refresh.
    /// Called on a timer, at launch and on wake; cheap when nothing is due.
    public func refreshIfDue() async {
        let hours = autoUpdateHours
        guard hours > 0, hasSubscription, !isRefreshing else { return }
        let due = (lastRefresh ?? .distantPast).addingTimeInterval(TimeInterval(hours) * 3600)
        guard Date() >= due else { return }
        LogStore.shared.client("Auto-updating the subscription (every \(hours) h)")
        await refresh()
    }

    private func refresh(from url: String, adopting: Bool) async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let result = try await subscriptions.fetch(url)
            let replacing = adopting && url != preferences.subscriptionURL
            if adopting {
                preferences.subscriptionURL = url
            }
            if replacing {
                // Another subscription's choices mean nothing for this one.
                preferences.selectedNode = nil
                preferences.latencies = [:]
                preferences.serverDescriptions = [:]
                selectedNode = nil
            }
            try result.yaml.write(to: panelURL, atomically: true, encoding: .utf8)
            subscriptionSource = result.source

            // The `/info` endpoint carries the device count the headers do not,
            // but the headers are what every subscription server implements
            // consistently — so info first, headers layered on top.
            var merged = (await subscriptions.fetchInfo(url) ?? SubscriptionInfo())
                .merging(result.info)
            if !replacing { merged.title = merged.title ?? info.title }
            info = merged
            preferences.cachedInfo = merged
            lastRefresh = Date()
            preferences.lastRefresh = lastRefresh
            issue = nil
            await updateRedactions()
            await refreshRoutingInputs()

            // A core that is up, not merely running: reloading one that does
            // not answer fails, and failed the whole refresh with it.
            let coreUp = state.isConnected ? true : await coreAnswers()
            if coreUp {
                // Reload in place rather than reconnecting: a refresh should not
                // drop a working tunnel, and the idle core has to pick up the new
                // nodes too — otherwise the list falls back to the raw `proxies:`
                // and the config's own groups disappear from it.
                try await reloadRunningCore()
            } else {
                // No core yet: the raw proxy list is all there is to show until
                // one comes up and the selector can be read properly — but only
                // when there is nothing better on screen. Swapping a selector
                // list for the raw one and back made every refresh flicker
                // between two different lists and counts.
                if nodes.isEmpty { nodes = try await nodesFromPanelConfig() }
                // A rested core stays rested through a refresh nobody is
                // watching; it starts on the new subscription when someone is.
                if watched {
                    // A start already under way — the warm-up at launch, racing
                    // this — may have read the subscription before it was
                    // rewritten, and would go on offering the old servers.
                    let underWay = coreStartup != nil
                    if await ensureCoreRunning(), underWay { try await reloadRunningCore() }
                }
            }
            return true
        } catch {
            issue = TunnelIssue.classify(error)
            LogStore.shared.client("Subscription update failed: \(error.localizedDescription)",
                                   level: .warning)
            return false
        }
    }

    // MARK: - Connect

    public func toggle() async {
        state.isConnected ? await disconnect() : await connect()
    }

    /// Brings the core up **without routing anything through it**.
    ///
    /// The core running and the tunnel being on are separate facts, and keeping
    /// them separate is what makes a latency pass instant: the outbounds a probe
    /// needs already exist. Connecting then only has to point traffic at a core
    /// that is already warm — which is how FlClash and Clash Verge Rev behave,
    /// and why their ping is immediate.
    ///
    /// Nothing here touches system state: no proxy settings are written and no
    /// TUN block is in the config.
    @discardableResult
    public func ensureCoreRunning() async -> Bool {
        guard hasSubscription else { return false }
        // One start at a time. The checks and the start wait off the main
        // thread, so two callers — the warm-up at launch and a ping, say —
        // could otherwise both find no core and both start one, and the second
        // start stops the first.
        if let pending = coreStartup { return await pending.value }
        let startup = Task { await startIdleCore() }
        coreStartup = startup
        defer { coreStartup = nil }
        return await startup.value
    }

    private func startIdleCore() async -> Bool {
        guard !coreHandover, !quitting else { return false }
        if await coreAnswers() { return true }
        // Over a TUN tunnel the core is the helper's, and bringing that one
        // back is the tunnel's business (see `recoverCore`): an idle core
        // started here would take the ports it needs.
        guard activeMode != .tun else { return false }

        var failure: Error?
        for attempt in 1...Self.startAttempts {
            do {
                try await launchIdleCore()
                failure = nil
                break
            } catch let error as CoreUnresponsive {
                failure = error
                LogStore.shared.client(
                    "Core did not answer (attempt \(attempt) of \(Self.startAttempts))"
                        + (attempt < Self.startAttempts ? " — starting it again" : ""),
                    level: .warning)
            } catch {
                // The core refused the config, or is missing from the bundle:
                // starting it again would end the same way.
                failure = error
                break
            }
        }
        if let failure {
            issue = TunnelIssue.classify(failure)
            LogStore.shared.client("Core would not start: \(failure.localizedDescription)", level: .error)
            return false
        }

        // It is up, so whatever said it was not no longer applies.
        if issue == .coreFailed || issue == .coreStopped { issue = nil }
        try? await discoverSelector()
        restoreLatencies()
        LogStore.shared.followCore(api)
        LogStore.shared.client("Core ready — \(nodes.count) entries offered")
        parkWhenIdle()
        return true
    }

    /// How many times in a row the core is started before the app says it
    /// could not start it.
    private static let startAttempts = 3
    /// How many times a connect is tried before its failure is shown.
    private static let connectAttempts = 2

    /// Whether a core is up — which means answering, not merely running.
    ///
    /// "Running" used to be enough, and it is not the same thing. A core whose
    /// controller port was taken when it started keeps running without one;
    /// so does one that hung. Either passed for a working core, every call to
    /// it failed, and nothing restarted it until the app was.
    private func coreAnswers() async -> Bool {
        let helper = helper, core = core
        // The helper's core counts: in TUN mode it is the one answering, and
        // one left by a previous session is running whether or not this one
        // knows about it.
        let known = await offMain { core.isRunning || (try? helper.status().running) == true }
        guard known else { return false }
        return await api.answers()
    }

    /// The two loopback ports a core listens on.
    private struct Ports: Sendable {
        var controller: Int
        var mixed: Int
    }

    /// Ports the core can actually have, as near the wanted ones as possible.
    ///
    /// A core of this app's from a previous run is given a moment to leave —
    /// it was signalled at launch and takes a second or so to go. Anything
    /// still holding a port after that is somebody else's (another client's
    /// core, usually), and the app moves rather than fight over it.
    nonisolated private static func freePorts(wanted: Ports, support: URL) -> Ports {
        let free = { LocalPort.isFree(wanted.controller) && LocalPort.isFree(wanted.mixed) }
        if !free() {
            MihomoProcess.reapOrphans(dataDirectory: support)
            let deadline = Date().addingTimeInterval(3)
            while !free(), Date() < deadline { usleep(100_000) }
        }
        var ports = wanted
        if !LocalPort.isFree(ports.controller) {
            ports.controller = LocalPort.firstFree(from: wanted.controller + 1, avoiding: [wanted.mixed])
                ?? wanted.controller
        }
        if !LocalPort.isFree(ports.mixed) {
            ports.mixed = LocalPort.firstFree(from: wanted.mixed + 1, avoiding: [ports.controller])
                ?? wanted.mixed
        }
        return ports
    }

    /// Takes up the ports a core has just been started on.
    private func adopt(_ ports: Ports) {
        if ports.controller != preferences.controllerPort {
            LogStore.shared.client("The core's API port was taken — moved to \(ports.controller)",
                                   level: .warning)
            preferences.controllerPort = ports.controller
            api = MihomoAPI(port: ports.controller, secret: preferences.coreSecret)
        }
        if ports.mixed != preferences.mixedPort {
            LogStore.shared.client("The proxy port was taken — moved to \(ports.mixed)",
                                   level: .warning)
            preferences.mixedPort = ports.mixed
        }
    }

    /// What the core writes when it could not have its API port. It carries on
    /// running without one, so there is nothing to wait for.
    nonisolated private static let controllerRefused = "External controller listen error"

    /// One attempt at starting the unprivileged core and hearing from it.
    private func launchIdleCore() async throws {
        let helper = helper, core = core, configURL = configURL, panelURL = panelURL
        let support = support, base = overrides(mode: .systemProxy)
        let ports = try await offMain { () -> Ports in
            // Whatever is here is not answering, or it would not have come to
            // this — and it holds the ports the new one needs.
            core.stop()
            if (try? helper.status().running) == true { try? helper.stop() }
            let ports = Self.freePorts(
                wanted: Ports(controller: base.controllerPort, mixed: base.mixedPort),
                support: support)
            var overrides = base
            overrides.controllerPort = ports.controller
            overrides.mixedPort = ports.mixed
            let yaml = try MihomoConfig.build(
                panelYAML: try String(contentsOf: panelURL, encoding: .utf8),
                overrides: overrides
            )
            try yaml.write(to: configURL, atomically: true, encoding: .utf8)
            try core.validate(configPath: configURL)
            try core.start(configPath: configURL)
            return ports
        }
        adopt(ports)

        let alive: @Sendable () -> Bool = {
            core.isRunning && !core.recentLog.contains(Self.controllerRefused)
        }
        guard await api.waitUntilReady(while: alive) else {
            let log = core.recentLog.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
            await offMain { core.stop() }
            throw CoreUnresponsive(log: log)
        }
    }

    public func connect() async {
        guard !state.isBusy, !state.isConnected else { return }
        guard hasSubscription else {
            issue = .noSubscription
            return
        }
        state = .connecting
        issue = nil
        let mode = preferences.tunnelMode
        LogStore.shared.client("Connecting via \(mode == .tun ? "TUN" : "system proxy")")

        var attempt = 1
        while true {
            do {
                try await establish(mode)
                break
            } catch {
                await teardown()
                // A core that died on the way up, or stopped answering between
                // two steps, is worth one more go before anyone is told.
                if attempt < Self.connectAttempts, Self.worthAnotherTry(error) {
                    attempt += 1
                    issue = nil
                    LogStore.shared.client(
                        "Connect did not go through (\(error.localizedDescription)) — trying again",
                        level: .warning)
                    continue
                }
                // A step below may already have said something more specific —
                // "no usable servers" beats "the core would not start".
                if issue == nil { issue = TunnelIssue.classify(error) }
                LogStore.shared.client("Connect failed: \(error.localizedDescription)", level: .error)
                state = .failed(error.localizedDescription)
                await fallBackToIdleCore()
                return
            }
        }

        startedAt = Date()
        restartBudget = RestartBudget()
        beginMonitoring()
        startWatchdog()
        state = .connected
        LogStore.shared.client("Connected — \(selectedNode ?? "auto")")
    }

    /// The idle core again after a failure, so the server list and ping keep
    /// working — with what the failure said left on screen: a core that then
    /// starts would otherwise take the explanation away with it.
    private func fallBackToIdleCore() async {
        let shown = issue
        if await ensureCoreRunning() { issue = shown }
    }

    /// Everything a connect does up to the tunnel carrying traffic. Throws at
    /// the first step that fails; the caller undoes what was done.
    private func establish(_ mode: TunnelMode) async throws {
        switch mode {
        case .systemProxy:
            // The core is already up for probing; connecting is only a
            // matter of pointing the machine at it.
            guard await ensureCoreRunning() else {
                throw MihomoProcess.Failure.exited(0, "core unavailable")
            }
            // Recorded before anything is changed, so a crash between the
            // two still leaves something to restore at the next launch.
            let proxy = proxy
            if preferences.proxySnapshot == nil {
                preferences.proxySnapshot = await offMain { proxy.snapshot() }
            }
            let port = preferences.mixedPort
            await offMain { proxy.enable(port) }

        case .tun:
            await refreshHelperStatus()
            if !helperIsCurrent { try await updateHelper() }
            // An idle core still starting would come up after the stop
            // below and hold the ports the privileged one needs.
            if let pending = coreStartup { _ = await pending.value }
            try await launchTunCore()
        }
        activeMode = mode

        try await discoverSelector()
        await applySelection()
    }

    /// Hands the tunnel to the helper's core and waits until it is carrying it.
    private func launchTunCore() async throws {
        let core = core, helper = helper, panelURL = panelURL, support = support
        let base = overrides(mode: .tun)
        let ports = try await handingOver { () -> Ports in
            // TUN needs the core to run as root, so the idle one has to go —
            // and with it a privileged one left by an attempt before this.
            core.stop()
            try helper.version()
            _ = try? helper.stop()
            let ports = Self.freePorts(
                wanted: Ports(controller: base.controllerPort, mixed: base.mixedPort),
                support: support)
            var overrides = base
            overrides.controllerPort = ports.controller
            overrides.mixedPort = ports.mixed
            let yaml = try MihomoConfig.build(
                panelYAML: try String(contentsOf: panelURL, encoding: .utf8),
                overrides: overrides
            )
            try helper.start(config: yaml)
            return ports
        }
        // From here the helper's core is the one to read and to stop.
        // Set only after the checks below, `coreLog` read the idle
        // core's log, so a TUN that failed to come up — another VPN
        // holding the routes — passed for connected; and a failure
        // before then left the privileged core running.
        activeMode = .tun
        adopt(ports)

        // Longer than the default: a panel config with `rule-providers`
        // downloads them before the core binds its controller, and the
        // window where the app still says "connecting" while traffic is
        // already flowing is exactly what that timeout governs.
        LogStore.shared.followCore(api)
        let alive: @Sendable () -> Bool = {
            guard let status = try? helper.status() else { return false }
            return status.running && !status.log.contains(Self.controllerRefused)
        }
        guard await api.waitUntilReady(timeout: 90, while: alive) else {
            throw CoreUnresponsive(log: await readCoreLog())
        }
        // A TUN interface that fails to come up does not stop the core:
        // it keeps running and keeps answering its API, so without this
        // the app reports a healthy tunnel while nothing is routed.
        try await Task.sleep(nanoseconds: 700_000_000)
        let log = await readCoreLog()
        if let reason = MihomoProcess.tunFailure(in: log) {
            throw TunFailure(routesTaken: MihomoProcess.routesTaken(in: log),
                             reason: reason)
        }
    }

    /// Whether a failed step could go through on a second try: the core died
    /// or went quiet, as opposed to something another attempt cannot change —
    /// a config the core refuses, a missing helper, routes another VPN holds.
    nonisolated private static func worthAnotherTry(_ error: Error) -> Bool {
        // A database the network did not let through will not come through a
        // second later either, and each try can wait over a minute for it.
        if Geodata.blockedDownload(in: error.localizedDescription) != nil { return false }
        if error is CoreUnresponsive || error is URLError { return true }
        if case MihomoAPI.Failure.notRunning = error { return true }
        return false
    }

    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnecting
        LogStore.shared.client("Disconnecting")
        await teardown()
        state = .disconnected
        // Traffic stops; the core does not. Leaving it up is what keeps the next
        // latency pass instant.
        await ensureCoreRunning()
    }

    /// Everything down, for quitting: routing *and* the idle core.
    ///
    /// ``disconnect()`` deliberately leaves the core running, which is right
    /// while the app is open and wrong once it is leaving — a child outlives its
    /// parent, so the core went on holding the controller port (and, while
    /// connected, carrying traffic) until the next launch reaped it.
    public func shutdown() async {
        quitting = true
        parking?.cancel()
        if state != .disconnected {
            state = .disconnecting
            LogStore.shared.client("Quitting — bringing the tunnel down")
            await teardown()
            state = .disconnected
        }
        // Not waited for: the idle core holds no system state, and it exits on
        // the signal whether or not the app is still here to watch.
        core.stop(waitForExit: false)
        LogStore.shared.stopFollowingCore()
    }

    /// Stops routing. Teardown runs in the reverse order of ``connect()``: proxy
    /// settings go back before the core stops, so no window exists where the
    /// machine points at a listener that is already gone.
    private func teardown() async {
        watchdog?.cancel()
        watchdog = nil
        pauseMonitoring()
        let mode = activeMode
        let proxy = proxy

        // Only what this app changed goes back. With no snapshot this used to
        // switch *every* proxy off on every network service — TUN never sets
        // one, so each TUN disconnect turned off any other client's proxy (or a
        // company one), and cost three `networksetup` runs per service.
        if let snapshot = preferences.proxySnapshot {
            await offMain { proxy.restore(snapshot) }
            preferences.proxySnapshot = nil
        } else if mode == .systemProxy {
            let port = preferences.mixedPort
            await offMain { proxy.disable(port) }
        }

        // Both wait for the core to exit, for up to five seconds.
        let helper = helper, core = core
        coreHandover = true
        switch mode {
        case .tun: await offMain { _ = try? helper.stop() }
        case .systemProxy, .none: await offMain { core.stop() }
        }
        coreHandover = false
        activeMode = nil

        meter.stop()
        startedAt = nil
        parkWhenIdle()
    }

    // MARK: - Selection

    public func select(node: String) async {
        selectedNode = node
        autoSelect = false
        preferences.selectedNode = node
        preferences.autoSelect = false
        await applySelection()
    }

    /// "Авто" — hand the choice to the config's own latency group if it has one,
    /// and otherwise pick the fastest node this app has measured.
    public func selectAuto() async {
        autoSelect = true
        preferences.autoSelect = true
        await applySelection()
    }

    private func applySelection() async {
        guard let group = selectorGroup, state != .disconnected else { return }
        do {
            let target: String?
            if autoSelect {
                target = try await autoTarget(in: group)
            } else {
                // A node saved from a previous subscription may be gone; falling
                // back to the first one beats leaving the selector wherever the
                // core happened to put it.
                target = nodes.contains(where: { $0.name == selectedNode })
                    ? selectedNode
                    : nodes.first?.name
            }
            guard let target else { return }
            try await api.select(node: target, in: group)
            // Global mode sends everything through mihomo's own GLOBAL group,
            // which knows nothing of this selector unless pointed at it — the
            // user's choice would otherwise be ignored the moment they switch.
            try? await api.select(node: group, in: "GLOBAL")
            if !autoSelect { selectedNode = target }
        } catch {
            LogStore.shared.client("Could not switch server: \(error.localizedDescription)",
                                   level: .warning)
        }
    }

    /// The config's own `url-test`/`fallback` group if it has one — the panel
    /// keeps that measured and it re-picks on its own. Failing that, the fastest
    /// node from the last probe.
    private func autoTarget(in group: String) async throws -> String? {
        let groups = try await api.groups()
        if let selector = groups.first(where: { $0.name == group }) {
            let latencyGroup = groups.first {
                selector.options.contains($0.name) &&
                ["URLTest", "Fallback", "LoadBalance"].contains($0.type)
            }
            if let latencyGroup { return latencyGroup.name }
        }
        let measured = nodes.compactMap { node in node.latency.map { ($0, node.name) } }
        return measured.min(by: { $0.0 < $1.0 })?.1 ?? nodes.first?.name
    }

    /// How each node's transport reads, taken from the subscription.
    ///
    /// The RESTful API reports a bare type — `Vless`, `Hysteria2` — but the
    /// panel's own list distinguishes Reality from plain TLS, and that is the
    /// difference a user picks on. Only the config has it.
    nonisolated private static func protocolLabels(panelYAML yaml: String) -> [String: String] {
        guard let root = try? Yams.load(yaml: yaml) as? [String: Any],
              let proxies = root["proxies"] as? [[String: Any]] else { return [:] }

        var labels: [String: String] = [:]
        for proxy in proxies {
            guard let name = proxy["name"] as? String,
                  let type = (proxy["type"] as? String)?.lowercased() else { continue }
            switch type {
            case "vless", "vmess":
                let family = type == "vless" ? "VLESS" : "VMess"
                if proxy["reality-opts"] != nil { labels[name] = "\(family) Reality" }
                else if proxy["tls"] as? Bool == true { labels[name] = "\(family) TLS" }
                else { labels[name] = family }
            case "hysteria2":
                // hysteria2 is TLS by definition; the panel writes it out anyway.
                labels[name] = "Hysteria2 TLS"
            case "trojan": labels[name] = "Trojan"
            case "ss": labels[name] = "Shadowsocks"
            default: labels[name] = type.uppercased()
            }
        }
        return labels
    }

    /// The subscription's server descriptions, or the last ones it carried
    /// when this copy came without them.
    private func currentDescriptions(fresh: [String: String]) -> [String: String] {
        guard !fresh.isEmpty else { return preferences.serverDescriptions }
        preferences.serverDescriptions = fresh
        return fresh
    }

    /// What ``discoverSelector()`` needs from the YAML on disk.
    private struct SelectorInputs: Sendable {
        var rules: [String]?
        var labels: [String: String]
        var descriptions: [String: String]
    }

    private func discoverSelector() async throws {
        let groups = try await api.groups()
        let selectors = groups.filter { $0.type == "Selector" }

        // The config's rules are the authority on which group is *the* one; the
        // running core does not expose them, so the generated config is re-read.
        // Everything read from YAML is parsed off the main thread, and the
        // subscription only once.
        let panelURL = panelURL
        let rulesURL = activeMode == .tun ? panelURL : configURL
        let inputs = await offMain { () -> SelectorInputs in
            let panel = (try? String(contentsOf: panelURL, encoding: .utf8)) ?? ""
            let config = rulesURL == panelURL
                ? panel : (try? String(contentsOf: rulesURL, encoding: .utf8)) ?? ""
            return SelectorInputs(
                rules: (try? Yams.load(yaml: config) as? [String: Any])?["rules"] as? [String],
                labels: Self.protocolLabels(panelYAML: panel),
                descriptions: MihomoConfig.serverDescriptions(panelYAML: panel)
            )
        }
        if let rules = inputs.rules {
            let name = MihomoConfig.primarySelectorName(
                groups: selectors.map { ["name": $0.name, "type": "select"] },
                rules: rules
            )
            if selectors.contains(where: { $0.name == name }) {
                selectorGroup = name
            }
        }
        if selectorGroup == nil { selectorGroup = selectors.first?.name }
        guard let selectorGroup else {
            throw MihomoConfig.Failure.noProxies
        }
        var listed = try await api.nodes(in: selectorGroup)

        // A group has no transport of its own, so it borrows the one its members
        // share — which is what the panel's own list shows for it.
        let labels = inputs.labels
        let membership = Dictionary(groups.map { ($0.name, $0.options) }) { first, _ in first }
        for index in listed.indices {
            if let label = labels[listed[index].name] {
                listed[index].protocolLabel = label
            } else if let members = membership[listed[index].name] {
                listed[index].protocolLabel = members.lazy.compactMap { labels[$0] }.first
            }
        }
        let descriptions = currentDescriptions(fresh: inputs.descriptions)
        for index in listed.indices {
            listed[index].serverDescription = descriptions[listed[index].name]
        }
        nodes = listed
        restoreLatencies()

        // A server chosen under an earlier subscription may be gone from this
        // one. Left pointing at nothing, the picker read "Авто" with no row
        // picked; automatic is what would effectively happen, so it says so.
        if !autoSelect, let chosen = selectedNode, !listed.contains(where: { $0.name == chosen }) {
            autoSelect = true
            preferences.autoSelect = true
        }
    }

    private func reloadRunningCore() async throws {
        // An idle core routes nothing, so it never gets a TUN block — it runs as
        // the user and could not create a `utun` device anyway.
        let mode: TunnelMode = state.isConnected
            ? (activeMode ?? preferences.tunnelMode)
            : .systemProxy
        let panelURL = panelURL, overrides = overrides(mode: mode)
        let yaml = try await offMain {
            try MihomoConfig.build(
                panelYAML: try String(contentsOf: panelURL, encoding: .utf8),
                overrides: overrides
            )
        }
        switch mode {
        case .tun where state.isConnected:
            // The helper owns its config file, so a reload there is a restart of
            // the core it supervises — the tunnel blips, which is the cost of not
            // letting an unprivileged process write a root-read path.
            let helper = helper
            // Its API goes quiet while it restarts, which is not the core
            // having died — the watchdog is told so.
            restarting = true
            defer { restarting = false }
            try await offMain { try helper.start(config: yaml) }
            _ = await api.waitUntilReady()
            // A new process: the old one's log and traffic streams ended with
            // it, which froze the speed readout at its last value.
            LogStore.shared.followCore(api)
            if watched { startTrafficStream() }
        default:
            let core = core, configURL = configURL
            try await offMain {
                try yaml.write(to: configURL, atomically: true, encoding: .utf8)
                try core.validate(configPath: configURL)
            }
            try await api.reload(path: configURL.path)
        }
        try await discoverSelector()
        await applySelection()
    }

    // MARK: - Latency

    /// Measures every node the selector offers.
    ///
    /// Instant, because a core is always running — see ``ensureCoreRunning()``.
    /// The probes go through that core's own outbounds whether or not traffic is
    /// currently being routed through it.
    public func pingAll() async {
        guard !isPinging else { return }
        isPinging = true
        defer { isPinging = false }

        guard await ensureCoreRunning() else { return }
        if nodes.isEmpty { try? await discoverSelector() }
        guard !nodes.isEmpty else { return }

        // Existing numbers stay on screen until their replacement lands, so the
        // list does not flash to n/a on every pass.
        pendingProbes = Set(nodes.map(\.name))
        defer { pendingProbes = [] }

        let names = nodes.map(\.name)
        let measured = await api.delays(nodes: names) { name, delay in
            await Self.record(name: name, delay: delay, on: self)
        }
        // Timeouts are remembered too, as -1, so a node that was down still
        // reads `n/a` after a relaunch rather than looking never checked.
        var saved = measured
        for name in names where measured[name] == nil { saved[name] = -1 }
        preferences.latencies = saved
        if autoSelect { await applySelection() }
    }

    /// Measures one server, for the row's own ping button.
    public func ping(node name: String) async {
        guard !pendingProbes.contains(name), await ensureCoreRunning() else { return }
        pendingProbes.insert(name)
        let delay = await api.delay(node: name)
        await Self.record(name: name, delay: delay, on: self)
        var saved = preferences.latencies
        saved[name] = delay ?? -1
        preferences.latencies = saved
    }

    /// Applies one node's result as it lands, on the main actor.
    private static func record(name: String, delay: Int?, on controller: TunnelController) async {
        controller.pendingProbes.remove(name)
        guard let index = controller.nodes.firstIndex(where: { $0.name == name }) else { return }
        controller.nodes[index].latency = delay
        controller.nodes[index].unreachable = delay == nil
    }

    /// Puts the last measured numbers back after the node list is rebuilt, so a
    /// screen change or a reconnect does not blank the server list.
    private func restoreLatencies() {
        let saved = preferences.latencies
        guard !saved.isEmpty else { return }
        for index in nodes.indices
        where nodes[index].latency == nil && !nodes[index].unreachable {
            guard let value = saved[nodes[index].name] else { continue }
            if value > 0 { nodes[index].latency = value } else { nodes[index].unreachable = true }
        }
    }

    // MARK: - Connections

    /// Every connection the core currently has open.
    public func currentConnections() async -> [MihomoAPI.Connection] {
        (try? await api.connections()) ?? []
    }

    /// Closes a specific set — one process's connections, or a single one.
    ///
    /// The core reopens whatever the program still wants, so this reads as
    /// "move this app onto the node I just picked" rather than as cutting it
    /// off: existing connections would otherwise stay on the old node until
    /// they aged out on their own.
    public func close(connections ids: [String]) async {
        guard !ids.isEmpty else { return }
        var closed = 0
        for id in ids {
            do {
                try await api.close(connection: id)
                closed += 1
            } catch {
                // A connection that closed on its own between the poll and the
                // click is the common case here, not a failure worth surfacing.
                continue
            }
        }
        LogStore.shared.client("Closed \(closed) connection(s)")
    }

    /// Closes them all. The core reopens whatever is still wanted, which is how
    /// traffic is forced onto a node that was just selected instead of waiting
    /// for existing connections to age out.
    public func closeAllConnections() async {
        do {
            try await api.closeAllConnections()
            LogStore.shared.client("Closed all connections")
        } catch {
            LogStore.shared.client("Could not close connections: \(error.localizedDescription)",
                                   level: .warning)
        }
    }

    // MARK: - Settings that change the config

    /// Switches the running core at once; the next config it is built with
    /// carries the choice too.
    public func setRoutingMode(_ mode: RoutingMode) async {
        guard mode != routingMode else { return }
        routingMode = mode
        preferences.routingMode = mode
        guard state.isConnected || core.isRunning else { return }
        do {
            try await api.patchConfig(["mode": mode.rawValue])
            LogStore.shared.client("Routing mode: \(mode.rawValue)")
            // Connections already open keep the route they started on. Closed,
            // programs reopen them, and the new mode takes them.
            if state.isConnected { await closeAllConnections() }
        } catch {
            LogStore.shared.client("Could not switch routing mode: \(error.localizedDescription)",
                                   level: .warning)
        }
    }

    public func setTunnelMode(_ mode: TunnelMode) async {
        guard mode != preferences.tunnelMode else { return }
        preferences.tunnelMode = mode
        tunnelMode = mode
        // A mode change swaps which process owns the core, so it cannot be a
        // live patch — it is a reconnect, and only if one was up.
        if state.isConnected {
            await disconnect()
            await connect()
        }
    }

    // MARK: - The user's own rules

    /// The rules as last applied.
    public var routingRules: [RoutingRule] { preferences.routingRules }

    /// Why the user's rules were not applied.
    public enum RulesRefusal: Equatable, Sendable {
        /// The core would not load the config they make.
        case rejected
        /// They need a database the core downloads on first use, and the
        /// download did not go through — an IP-ASN rule where it is blocked.
        case downloadBlocked(asn: Bool)
    }

    /// Whether applying `rules` has the core download a database first: one
    /// of them is an IP-ASN rule, and the core's home has no AS numbers yet.
    public func downloadsDatabase(for rules: [RoutingRule]) -> Bool {
        let asn = support.appendingPathComponent("core").appendingPathComponent(Geodata.asnFileName)
        return rules.contains { $0.enabled && $0.kind.needsDownload }
            && !FileManager.default.fileExists(atPath: asn.path)
    }

    /// Checks `rules` against the core, then keeps them and applies them; nil
    /// once they are, and otherwise why not.
    ///
    /// Checked first because a rule the core refuses does not fail on its own:
    /// the whole config is refused, and a connected tunnel would stop carrying
    /// anything. The check is the core's own `-t`, on the config these rules
    /// would produce, so what passes here is what will load.
    public func applyRoutingRules(_ rules: [RoutingRule]) async -> RulesRefusal? {
        var proposed = overrides(mode: state.isConnected ? (activeMode ?? tunnelMode) : .systemProxy)
        proposed.routingRules = rules
        let overrides = proposed, core = core, panelURL = panelURL
        let probe = configURL.deletingLastPathComponent().appendingPathComponent("rules-check.yaml")
        do {
            try await offMain {
                defer { try? FileManager.default.removeItem(at: probe) }
                let yaml = try MihomoConfig.build(
                    panelYAML: try String(contentsOf: panelURL, encoding: .utf8),
                    overrides: overrides
                )
                try yaml.write(to: probe, atomically: true, encoding: .utf8)
                try core.validate(configPath: probe)
            }
        } catch {
            LogStore.shared.client("Rules not applied: \(error.localizedDescription)", level: .error)
            if let file = Geodata.blockedDownload(in: error.localizedDescription) {
                return .downloadBlocked(asn: file == Geodata.asnFileName)
            }
            return .rejected
        }
        preferences.routingRules = rules
        LogStore.shared.client("Applied \(rules.filter(\.enabled).count) rule(s) of the user's own")
        await reapplyRouting()
        return nil
    }

    /// Reads the subscription's groups and rules for the rules screen.
    private func refreshRoutingInputs() async {
        let panelURL = panelURL
        let inputs = await offMain { () -> RoutingInputs in
            let yaml = (try? String(contentsOf: panelURL, encoding: .utf8)) ?? ""
            let parsed = MihomoConfig.routingInputs(panelYAML: yaml)
            return RoutingInputs(groups: parsed.groups, rules: parsed.rules)
        }
        ruleTargets = inputs.groups
        profileRules = inputs.rules
    }

    private struct RoutingInputs: Sendable {
        var groups: [String]
        var rules: [String]
    }

    /// Carries over what was set on the apps screen of earlier versions — the
    /// app switches, the rules beside them and the split mode — into the
    /// user's own rules, once, then forgets it. See ``LegacySplitRule``.
    private func retireSplitTunnelling() {
        guard let legacy = preferences.legacySplit else { return }
        defer { preferences.forgetLegacySplit() }
        guard !legacy.rules.isEmpty else { return }

        var group = MihomoConfig.defaultSelector
        if legacy.mode == "only" {
            let root = (try? loadPanelRoot()) ?? [:]
            group = MihomoConfig.primarySelectorName(
                groups: root["proxy-groups"] as? [[String: Any]] ?? [],
                rules: root["rules"] as? [String] ?? []
            )
        }
        let existing = preferences.routingRules
        let moved = RoutingRule.carriedOver(from: legacy.rules, mode: legacy.mode, group: group)
            .filter { new in !existing.contains { $0.kind == new.kind && $0.value == new.value } }
        preferences.routingRules = existing + moved
        LogStore.shared.client("Moved \(moved.count) rule(s) from the apps screen to the rules page")
    }

    private func loadPanelRoot() throws -> [String: Any] {
        let yaml = try String(contentsOf: panelURL, encoding: .utf8)
        return try Yams.load(yaml: yaml) as? [String: Any] ?? [:]
    }

    private func reapplyRouting() async {
        guard state.isConnected else { return }
        do {
            try await reloadRunningCore()
        } catch {
            issue = TunnelIssue.classify(error)
            LogStore.shared.client("Could not apply routing: \(error.localizedDescription)",
                                   level: .error)
        }
    }

    // MARK: - Monitoring

    /// Tells the controller whether anything of the app is on screen — its
    /// window, or the tray.
    ///
    /// Most of what this object does every second is for the eye: the uptime
    /// clock, the speeds, a warm core so the next latency pass is instant.
    /// Closed to the menu bar, none of that is seen and all of it still woke
    /// the processor — a timer and a traffic sample every second for as long
    /// as the tunnel was up, and a whole core kept running beside an app with
    /// nothing connected. Unwatched, the clock and the speeds stop being fed,
    /// and an idle core is rested after a while (see ``parkWhenIdle()``). The
    /// tunnel itself, and the watch kept over its core, do not depend on it.
    public func setWatched(_ watched: Bool) {
        guard watched != self.watched else { return }
        self.watched = watched
        if watched {
            parking?.cancel()
            parking = nil
            if state.isConnected {
                beginMonitoring()
            } else if !state.isBusy {
                // Warm again by the time anyone reaches for the server list.
                Task { await ensureCoreRunning() }
            }
        } else {
            pauseMonitoring()
            parkWhenIdle()
        }
    }

    /// Starts feeding the clock and the speeds, if there is a session to read
    /// them from and anyone to read them.
    private func beginMonitoring() {
        guard watched, let startedAt else { return }
        uptimeTimer?.invalidate()
        meter.tick(Int(Date().timeIntervalSince(startedAt)))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.meter.tick(Int(Date().timeIntervalSince(startedAt)))
            }
        }
        // A clock read by a person: the system may fire it with its other
        // timers rather than wake for this one alone.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        uptimeTimer = timer

        startTrafficStream()
    }

    private func pauseMonitoring() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        trafficTask?.cancel()
        trafficTask = nil
        meter.rest()
    }

    private func startTrafficStream() {
        trafficTask?.cancel()
        trafficTask = Task { [api] in
            // mihomo's /traffic emits one sample a second for as long as
            // anyone is listening.
            for await sample in api.trafficStream() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.meter.record(up: sample.up, down: sample.down)
                }
            }
        }
    }

    /// Rests the idle core once nothing of the app has been on screen for a
    /// while and nothing is connected.
    ///
    /// The core is kept warm so that a latency pass is instant — which is
    /// worth a running process while someone may press the button, and not
    /// for the hours an app spends closed to the menu bar with the tunnel
    /// off. It starts again the moment the window or the tray opens.
    private func parkWhenIdle() {
        parking?.cancel()
        parking = nil
        guard !watched, !quitting, activeMode == nil else { return }
        let delay = environment.parkDelay
        parking = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.parkIdleCore()
        }
    }

    private func parkIdleCore() async {
        guard !watched, !state.isConnected, !state.isBusy, activeMode == nil,
              coreStartup == nil, !isPinging, !isRefreshing, core.isRunning else { return }
        LogStore.shared.client("Nothing connected and nothing on screen — resting the core")
        LogStore.shared.stopFollowingCore()
        let core = core
        await offMain { core.stop() }
    }

    // MARK: - Keeping the core up

    /// Asks a connected core, every so often, whether it is still there.
    ///
    /// The unprivileged core reports its own exit, but a core that hangs
    /// reports nothing, and the helper's core — the one carrying a TUN tunnel
    /// — is not this process's child at all: when it died the window went on
    /// saying "connected" over a tunnel that was gone. One request on loopback
    /// every quarter of a minute is what finding out costs.
    private func startWatchdog() {
        watchdog?.cancel()
        let interval = environment.watchdogInterval
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkCore()
            }
        }
    }

    /// Longer than a start waits for an answer: restarting a core that was only
    /// slow drops every connection it was carrying.
    private static let watchdogPatience: TimeInterval = 5

    private func checkCore() async {
        guard state.isConnected, !restarting else { return }
        if await api.answers(within: Self.watchdogPatience) { return }
        // Asked twice before acting on it: a core in the middle of a reload
        // can miss one question.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard state.isConnected, !restarting else { return }
        if await api.answers(within: Self.watchdogPatience) { return }
        await recoverCore("stopped answering")
    }

    private func handleCoreExit(_ status: Int32) {
        guard !quitting else { return }
        let detail = core.recentLog.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        LogStore.shared.client("Core stopped unexpectedly (status \(status))"
                               + (detail.isEmpty ? "" : "\n\(detail)"), level: .warning)
        // A start or a restart under way is watching this very process, and
        // deals with its going itself.
        guard coreStartup == nil, !restarting else { return }
        if state.isConnected {
            Task { await recoverCore("stopped (status \(status))") }
        } else if !state.isBusy, watched, restartBudget.spend() {
            // Nothing was riding on it; it is only the warm core for the
            // server list, brought back while there is someone to use it.
            Task { await ensureCoreRunning() }
        }
    }

    /// Brings the core back under a live tunnel, in place.
    ///
    /// A core that stopped used to end the session: the tunnel was torn down
    /// and the window said "the VPN stopped unexpectedly — connect again",
    /// leaving the user to do by hand the one thing there was to do. Now the
    /// core is started again where it was — the proxy settings still point at
    /// its port, the routes are re-made by the new TUN core — and the choice
    /// of server put back; the window reads "connecting" for the second or two
    /// that takes. Only a core that will not come back, or keeps going down,
    /// is reported.
    private func recoverCore(_ reason: String) async {
        guard state.isConnected, !restarting, !quitting, let mode = activeMode else { return }
        restarting = true
        defer { restarting = false }
        state = .connecting
        trafficTask?.cancel()
        trafficTask = nil

        var failure: Error?
        if restartBudget.spend() {
            LogStore.shared.client("Core \(reason) — restarting it", level: .warning)
            for attempt in 1...Self.connectAttempts {
                do {
                    try await revive(mode)
                    failure = nil
                    break
                } catch {
                    failure = error
                    guard attempt < Self.connectAttempts, Self.worthAnotherTry(error) else { break }
                }
            }
            // Quit, or told to disconnect, while it was coming back: a core
            // started for a tunnel nobody wants any more is taken down again.
            guard state == .connecting, !quitting else {
                if state == .disconnected, activeMode != nil { await teardown() }
                return
            }
            if failure == nil {
                LogStore.shared.followCore(api)
                beginMonitoring()
                state = .connected
                LogStore.shared.client("Core is back — the tunnel carries on")
                return
            }
        } else {
            LogStore.shared.client("Core \(reason) again — it has been restarted "
                                   + "\(restartBudget.limit) times already, giving up", level: .error)
        }

        // Whatever more specific there is to say, said; otherwise that it
        // stopped and would not come back.
        let specific = failure.map(TunnelIssue.classify)
        issue = specific == nil || specific == .coreFailed ? .coreStopped : specific
        if let failure {
            LogStore.shared.client("Core could not be restarted: \(failure.localizedDescription)",
                                   level: .error)
        }
        await teardown()
        state = .failed("Core stopped")
        await fallBackToIdleCore()
    }

    /// Starts the core again for a tunnel that is already set up around it.
    private func revive(_ mode: TunnelMode) async throws {
        switch mode {
        case .systemProxy:
            let port = preferences.mixedPort
            guard await ensureCoreRunning() else {
                throw MihomoProcess.Failure.exited(0, "core unavailable")
            }
            // The listener may have had to move, and the machine has to be
            // pointed at where it is now.
            let moved = preferences.mixedPort, proxy = proxy
            if moved != port { await offMain { proxy.enable(moved) } }
        case .tun:
            try await launchTunCore()
        }
        try await discoverSelector()
        await applySelection()
    }

    /// A force-quit while connected leaves the machine's proxy pointing at a
    /// core that no longer exists, which reads to the user as "the internet is
    /// broken". The snapshot outlives the process precisely so this can be
    /// undone on the next launch.
    private func recoverFromCrash() {
        if let snapshot = preferences.proxySnapshot {
            proxy.restore(snapshot)
            preferences.proxySnapshot = nil
        }

        // The same for the unprivileged core: a child is reparented to launchd
        // when its parent dies, so a crash, a force-quit or an in-app update
        // leaves one running and holding the controller port.
        let reaped = MihomoProcess.reapOrphans(dataDirectory: support)
        if !reaped.isEmpty {
            LogStore.shared.client("Stopped \(reaped.count) orphaned core(s) from a previous run")
        }

        // A privileged core outlives the app that started it — it is a root
        // daemon's child, not ours. Left running it holds the controller port,
        // so the core this session starts cannot bind it and every API call
        // silently addresses the *old* core instead: wrong nodes, wrong
        // connections, and a tunnel still carrying traffic while the window says
        // "Отключено".
        if (try? helper.status().running) == true {
            LogStore.shared.client("Found a privileged core from a previous session — stopping it")
            try? helper.stop()
        }
    }

    // MARK: -

    /// Tells the log what never to show: the subscription link, its host and
    /// its token, and every server address the subscription names. Core errors
    /// quote server addresses (`dial tcp …`), and the log is on screen.
    private func updateRedactions() async {
        let link = preferences.subscriptionURL, panelURL = panelURL
        let secrets = await offMain { () -> [String] in
            var secrets: [String] = []
            if let link, let url = SubscriptionClient.normalize(link) {
                secrets.append(link)
                secrets.append(url.absoluteString)
                if let host = url.host { secrets.append(host) }
                secrets += url.pathComponents.filter { $0.count >= 8 }
            }
            if let yaml = try? String(contentsOf: panelURL, encoding: .utf8),
               let root = try? Yams.load(yaml: yaml) as? [String: Any],
               let proxies = root["proxies"] as? [[String: Any]] {
                secrets += proxies.compactMap { $0["server"] as? String }
            }
            return secrets
        }
        LogStore.shared.setRedactions(secrets)
    }

    private func overrides(mode: TunnelMode) -> MihomoConfig.Overrides {
        MihomoConfig.Overrides(
            controllerPort: preferences.controllerPort,
            secret: preferences.coreSecret,
            mixedPort: preferences.mixedPort,
            mode: mode,
            routingMode: preferences.routingMode,
            routingRules: preferences.routingRules,
            dataDirectory: support.appendingPathComponent("core").path
        )
    }

    private func nodesFromPanelConfig() async throws -> [Node] {
        let panelURL = panelURL
        return try await offMain {
            let yaml = try String(contentsOf: panelURL, encoding: .utf8)
            guard let root = try Yams.load(yaml: yaml) as? [String: Any],
                  let proxies = root["proxies"] as? [[String: Any]] else { return [] }
            return proxies.compactMap { proxy in
                guard let name = proxy["name"] as? String else { return nil }
                return Node(name: name,
                            type: proxy["type"] as? String ?? "unknown",
                            server: proxy["server"] as? String)
            }
        }
    }

    /// "MacBook Pro" — what the design's device row shows, and what the panel's
    /// device list shows for this install.
    ///
    /// Splitting `hw.model` on capitals gets this wrong in the common case:
    /// `MacBookPro18,3` becomes "Mac Book Pro". Apple's product names are not
    /// derivable from the identifier, so the handful that exist are listed.
    nonisolated public static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let identifier = String(cString: bytes)

        // Longest prefix wins: MacBookPro must be tried before MacBook.
        let names = [
            ("MacBookPro", "MacBook Pro"),
            ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"),
            ("MacPro", "Mac Pro"),
            ("MacStudio", "Mac Studio"),
            ("Macmini", "Mac mini"),
            ("iMacPro", "iMac Pro"),
            ("iMac", "iMac"),
            ("Mac", "Mac"),
        ]
        for (prefix, name) in names where identifier.hasPrefix(prefix) {
            return name
        }
        // The generation suffix is dropped: this is a device name, not a spec.
        let letters = identifier.prefix { !$0.isNumber }
        return letters.isEmpty ? identifier : String(letters)
    }
}

public extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// The bundled core. Falls back to the repository layout so a `swift run`
    /// build outside an app bundle still finds it.
    var coreBinaryURL: URL {
        if let resource = url(forResource: "mihomo", withExtension: nil) {
            return resource
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/mihomo/mihomo")
    }

    /// The folder of bundled geo databases — see ``Geodata``. Falls back to
    /// the repository layout, like the core.
    var geodataURL: URL {
        if let resource = url(forResource: "geodata", withExtension: nil) {
            return resource
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/geodata")
    }

    var helperBinaryURL: URL {
        url(forResource: "moonlight-helper", withExtension: nil)
            ?? bundleURL.appendingPathComponent("Contents/Resources/moonlight-helper")
    }
}
