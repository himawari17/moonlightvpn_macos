import Foundation

/// Supervises the bundled mihomo core as a child process.
///
/// In system-proxy mode the core runs as the user, which needs no privileges at
/// all. TUN mode needs root to create the `utun` interface and to install
/// routes, so there the core is started by the privileged helper instead — see
/// ``HelperClient``. Both paths produce the same running core reachable on the
/// same loopback controller, which is why everything above this type is
/// indifferent to which one started it.
public final class MihomoProcess: @unchecked Sendable {

    public enum Failure: LocalizedError {
        case binaryMissing
        case exited(Int32, String)

        public var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The mihomo core is missing from the app bundle"
            case .exited(let code, let output):
                let detail = output.isEmpty ? "" : "\n\(output)"
                return "Core exited with status \(code)\(detail)"
            }
        }
    }

    private let binary: URL
    private let dataDirectory: URL
    /// Where this build's geo databases are, if it has them — see ``Geodata``.
    private let geodata: URL?
    private var process: Process?
    private let lock = NSLock()

    /// The tail of the core's own log, kept so a failed start can say why.
    /// Bounded, because a core in a crash loop would otherwise grow it without
    /// limit for the lifetime of the app.
    private var logLines: [String] = []
    private static let logLimit = 200

    public var onLog: (@Sendable (String) -> Void)?
    /// Fired when the core exits without being asked to.
    public var onUnexpectedExit: (@Sendable (Int32) -> Void)?

    public init(binary: URL, dataDirectory: URL, geodata: URL? = nil) {
        self.binary = binary
        self.dataDirectory = dataDirectory
        self.geodata = geodata
    }

    /// The release number in `mihomo -v`'s first line — "1.19.31" — or nil for
    /// a build that has none.
    public static func version(fromOutput output: String) -> String? {
        guard let first = output.split(whereSeparator: \.isNewline).first,
              let match = first.range(of: #"\bv(\d+\.\d+\.\d+)\b"#, options: .regularExpression)
        else { return nil }
        return String(first[match].dropFirst())
    }

    /// The release number of the core at `binary`, asked of the binary itself.
    ///
    /// Launches it and waits, which spins the calling thread's run loop — so
    /// never from the main thread, and never from a view (see
    /// ``TunnelController/refreshHelperStatus()``).
    public static func version(of binary: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return version(fromOutput: String(decoding: data, as: UTF8.self))
    }

    /// Where the config this core runs is kept: inside its home, not beside it.
    /// mihomo reloads only from a path under its home directory, and a config
    /// kept one level up started fine and then failed every subscription
    /// refresh with "path is not subpath of home directory".
    public var configURL: URL {
        dataDirectory.appendingPathComponent("config.yaml")
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// The reason TUN failed to come up, if it did.
    ///
    /// This has to be asked for explicitly, because the failure is **not** a
    /// crash: the core keeps running and keeps answering its API with the
    /// interface never established, so every other signal says "connected"
    /// while no traffic moves.
    /// Whether the TUN failure in `log` is another client holding the routes.
    public static func routesTaken(in log: String) -> Bool {
        guard let line = log.split(whereSeparator: \.isNewline)
            .last(where: { $0.contains("Start TUN listening error") }) else { return false }
        return line.contains("file exists") || line.contains("add route")
    }

    public static func tunFailure(in log: String) -> String? {
        guard let line = log
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.contains("Start TUN listening error") })
        else { return nil }

        // `add route: …: file exists` means another VPN client already owns the
        // routes auto-route wants. That is the common case by far, and the raw
        // message sends people looking for a bug in this app.
        if line.contains("file exists") || line.contains("add route") {
            return "Another VPN or proxy client already owns the system routes. "
                + "Quit it and connect again, or use system-proxy mode."
        }
        if let range = line.range(of: "Start TUN listening error: ") {
            // The core logs `msg="…"`, so the closing quote comes along with the
            // reason and would be shown to the user.
            return String(line[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return "The TUN interface could not be created"
    }

    public var recentLog: String {
        lock.lock(); defer { lock.unlock() }
        return logLines.joined(separator: "\n")
    }

    /// Kills cores this app started that outlived the app itself.
    ///
    /// A child process is **not** killed when its parent dies — it is reparented
    /// to launchd and carries on. So a force-quit, a crash, or an in-app update
    /// leaves a core running, and because it still holds the controller port the
    /// next launch's core cannot bind it. Every API call then addresses the old
    /// core instead: stale nodes, stale connections, and traffic still flowing
    /// while the window says it is disconnected.
    ///
    /// Identified by the **data directory** on its command line, not by the
    /// executable path: the app moves — an update replaces the bundle, and a
    /// build run from a checkout lives elsewhere than `/Applications` — while
    /// `~/Library/Application Support/Moonlight` is the same for every install.
    /// It also cannot match another client's mihomo, which has its own.
    @discardableResult
    public static func reapOrphans(dataDirectory: URL) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "mihomo.*\(dataDirectory.path)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()

        guard (try? pgrep.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()

        let mine = ProcessInfo.processInfo.processIdentifier
        let found = (String(data: output, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != mine && parent(of: $0) != mine }

        for pid in found {
            // SIGTERM so the core tears down its own interface and routes; a
            // SIGKILL would strand them.
            kill(pid, SIGTERM)
        }
        return found
    }

    /// The parent of a pid, so cores this very process started are left alone.
    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }

    /// Validates a config without starting anything.
    ///
    /// Worth doing before every start: `mihomo -t` reports the offending key and
    /// line, whereas a core that fails at startup exits with a status and a log
    /// line the user never sees.
    public func validate(configPath: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.binaryMissing
        }
        // Before the core looks: it opens these to parse GEOSITE and GEOIP
        // rules, and a `-t` that finds none downloads them like a start does.
        Geodata.seed(home: dataDirectory, from: geodata)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", dataDirectory.path, "-t", "-f", configPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.exited(
                process.terminationStatus,
                String(data: output, encoding: .utf8)?
                    .split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n") ?? ""
            )
        }
    }

    public func start(configPath: URL) throws {
        stop()

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.binaryMissing
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        Geodata.seed(home: dataDirectory, from: geodata)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", dataDirectory.path, "-f", configPath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data is EOF; leaving the handler installed spins a thread.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }

        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // Unexpected only while it is still the core in charge. `stop()`
            // lets go of a process before signalling it, so one that was asked
            // to leave — or replaced by the next start — is no longer that.
            // This used to be one `stopping` flag for every process, which the
            // next start cleared: a core stopped and replaced at once could
            // report its own requested exit as a crash of the new one.
            lock.lock()
            let inCharge = self.process === finished
            if inCharge { self.process = nil }
            lock.unlock()
            if inCharge { onUnexpectedExit?(finished.terminationStatus) }
        }

        lock.lock()
        logLines.removeAll()
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
            throw error
        }
    }

    /// Stops the core.
    ///
    /// - Parameter waitForExit: Block until it has gone, escalating to SIGKILL
    ///   after five seconds. Only a core with system state to tear down needs
    ///   that; an idle core owns nothing but its ports, and waiting for it at
    ///   quit only makes quitting slow — it exits on the signal regardless.
    public func stop(waitForExit: Bool = true) {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()

        guard let running, running.isRunning else { return }
        // SIGTERM first: mihomo tears down its interface and restores routes on
        // it. A SIGKILL here would leave a `utun` device and its routes behind.
        running.terminate()
        guard waitForExit else { return }

        let deadline = Date().addingTimeInterval(5)
        while running.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if running.isRunning {
            kill(running.processIdentifier, SIGKILL)
        }
    }

    private func append(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lock.lock()
        logLines.append(contentsOf: lines)
        if logLines.count > Self.logLimit {
            logLines.removeFirst(logLines.count - Self.logLimit)
        }
        lock.unlock()
        for line in lines { onLog?(line) }
    }

    deinit { stop() }
}
