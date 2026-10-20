import Foundation

/// `moonlight-helper` — a root LaunchDaemon whose only job is to run the mihomo
/// core for TUN mode.
///
/// TUN needs root: creating a `utun` interface and installing the default route
/// through it are privileged operations, and no amount of entitlement work makes
/// them otherwise for an unsigned app. Everything else in Moonlight runs as the
/// user.
///
/// ## Trust boundary
///
/// A root daemon that takes instructions over a socket is a privilege
/// escalation waiting to happen, so it is deliberately narrow:
///
/// - **It never execs a path the client supplies.** The core binary is a
///   root-owned copy made at install time at ``corePath``; that path is
///   compiled in. A client that asks it to run something else has no way to say
///   so — there is no field for it.
/// - **It never reads a config path the client supplies.** The client sends
///   config *text*, which the helper writes into its own root-owned directory.
///   Otherwise a symlink into this directory would let any local user have root
///   read a file for them.
/// - **The socket is mode 0660, group `admin`**, so the callers are exactly the
///   accounts that can already run `sudo`. This is a convenience boundary — it
///   spares the user a password prompt per connect — not a security boundary
///   against an administrator.
///
/// The protocol is newline-delimited JSON, one request and one response per
/// connection.

let socketPath = "/var/run/moonlight-helper.sock"
let stateDirectory = "/Library/Application Support/Moonlight"
let corePath = "\(stateDirectory)/mihomo"
let configPath = "\(stateDirectory)/run/config.yaml"
let coreDataDirectory = "\(stateDirectory)/run"
let protocolVersion = 1

// MARK: - Core supervision

final class CoreSupervisor {
    private var process: Process?
    private let lock = NSLock()
    private var lastLog: [String] = []

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    var log: String {
        lock.lock(); defer { lock.unlock() }
        return lastLog.joined(separator: "\n")
    }

    func start(config: String) throws {
        stop()

        guard FileManager.default.isExecutableFile(atPath: corePath) else {
            throw HelperError("core binary missing at \(corePath)")
        }

        try FileManager.default.createDirectory(
            atPath: coreDataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Written by the helper, never by the client: a client-named path could
        // be a symlink pointing anywhere on the disk.
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configPath
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = ["-d", coreDataDirectory, "-f", configPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data is EOF: the core exited and closed its end. A handler
            // left installed at EOF fires again immediately and forever — one
            // core per thread spinning at 100% CPU, one more for every restart.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            lock.lock()
            lastLog.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
            if lastLog.count > 100 { lastLog.removeFirst(lastLog.count - 100) }
            lock.unlock()
        }

        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()

        guard let running, running.isRunning else { return }
        // SIGTERM so the core removes its own interface and routes. A SIGKILL
        // here strands a utun device and a default route pointing into nothing,
        // which takes the machine's networking with it.
        running.terminate()
        let deadline = Date().addingTimeInterval(5)
        while running.isRunning, Date() < deadline { usleep(50_000) }
        if running.isRunning { kill(running.processIdentifier, SIGKILL) }
    }
}

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let supervisor = CoreSupervisor()

// MARK: - Request handling

func handle(_ request: [String: Any]) -> [String: Any] {
    switch request["cmd"] as? String {
    case "version":
        return ["ok": true, "version": protocolVersion,
                "running": supervisor.isRunning]

    case "status":
        return ["ok": true, "running": supervisor.isRunning, "log": supervisor.log]

    case "start":
        guard let config = request["config"] as? String, !config.isEmpty else {
            return ["ok": false, "error": "missing config"]
        }
        do {
            try supervisor.start(config: config)
            return ["ok": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

    case "stop":
        supervisor.stop()
        return ["ok": true]

    default:
        return ["ok": false, "error": "unknown command"]
    }
}

// MARK: - Socket

func listen() -> Int32 {
    unlink(socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fatalError("socket() failed: \(errno)") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    precondition(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path),
                 "socket path too long")
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { fatalError("bind() failed: \(errno)") }

    // 0660 root:admin — the callers are the accounts that could already sudo.
    chmod(socketPath, 0o660)
    var adminGID: gid_t = 80              // `admin` is gid 80 on every macOS
    if let group = getgrnam("admin") { adminGID = group.pointee.gr_gid }
    chown(socketPath, 0, adminGID)

    guard Foundation.listen(fd, 8) == 0 else { fatalError("listen() failed: \(errno)") }
    return fd
}

func serve(_ client: Int32) {
    defer { close(client) }

    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var received = Data()
    // A config is up to a few hundred KB; anything past the buffer is a client
    // that is not one of ours.
    while true {
        let count = read(client, &buffer, buffer.count)
        if count <= 0 { break }
        received.append(contentsOf: buffer[0..<count])
        if received.last == UInt8(ascii: "\n") { break }
        if received.count > buffer.count { return }
    }
    guard !received.isEmpty else { return }

    let request = (try? JSONSerialization.jsonObject(with: received)) as? [String: Any] ?? [:]
    let response = handle(request)
    guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
    data.append(UInt8(ascii: "\n"))
    data.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
}

// Dying must not strand the interface: launchd sends SIGTERM on shutdown and on
// `launchctl bootout`, and the core has to come down with us.
//
// The handlers run on their own queue. They used to be on the main queue — but
// the main thread never returns from the `accept` loop below, so the main queue
// never ran, SIGTERM was ignored, and launchd SIGKILLed the helper five seconds
// later: the core it supervised was orphaned with the tunnel's interface and
// routes, and a reinstall in those five seconds failed with "Bootstrap failed:
// 5". The sources are kept in a global, since a released source stops firing.
let signalQueue = DispatchQueue(label: "vpn.moonlight.helper.signals")
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        supervisor.stop()
        unlink(socketPath)
        exit(0)
    }
    source.resume()
    return source
}
signal(SIGPIPE, SIG_IGN)

let listener = listen()
NSLog("moonlight-helper listening on \(socketPath)")

while true {
    let client = accept(listener, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        break
    }
    // One connection at a time is plenty — requests are a handful per session,
    // and serialising them means no locking around the supervisor's state.
    serve(client)
}
