import Foundation
import MoonlightCore

/// A socket on loopback this process owns, at a port the kernel chose.
///
/// A listening socket and a client connected to it — the kernel finishes the
/// handshake into the backlog, so nothing has to accept — or one bound UDP
/// socket. `idle` is a TCP socket bound to no address in particular and left
/// there, neither listening nor connected.
final class LoopbackSocket {
    private(set) var descriptors: [Int32] = []
    /// The client's local port for TCP, the bound port for UDP or an idle socket.
    private(set) var port: UInt16 = 0
    /// Where a TCP client connected to: the listener.
    private(set) var listenerPort: UInt16 = 0

    init?(udp: Bool = false, connectTo target: UInt16? = nil, idle: Bool = false) {
        func address(_ port: UInt16, _ host: String) -> sockaddr_in {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr(host)
            return a
        }
        func bound(_ fd: Int32) -> UInt16 {
            var a = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return UInt16(bigEndian: a.sin_port)
        }
        func call(_ fd: Int32, _ port: UInt16, at host: String = "127.0.0.1",
                  _ body: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Bool {
            var a = address(port, host)
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        if udp || idle {
            let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
            guard fd >= 0, call(fd, 0, at: udp ? "127.0.0.1" : "0.0.0.0", Darwin.bind) else { return nil }
            descriptors = [fd]
            port = bound(fd)
            return
        }
        var target = target
        if target == nil {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0, call(listener, 0, Darwin.bind), listen(listener, 4) == 0 else { return nil }
            descriptors.append(listener)
            target = bound(listener)
        }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0, let target, call(client, target, Darwin.connect) else { return nil }
        descriptors.append(client)
        listenerPort = target
        port = bound(client)
    }

    /// Writes to the client and reads what comes back, for a proxy's CONNECT.
    func exchange(_ request: String) -> String {
        guard let fd = descriptors.last else { return "" }
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    }

    func close() {
        descriptors.forEach { _ = Darwin.close($0) }
        descriptors = []
    }

    deinit { close() }
}

/// This executable, as the system names it.
let ownExecutable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath().path

private func resolved(_ path: String?) -> String? {
    path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}

/// The app's own answer to "which program is this", for a core that cannot say.
func socketOwnerTests() async {
    Check.currentSuite = "Connections · who owns a socket"

    guard let tcp = LoopbackSocket(), let udp = LoopbackSocket(udp: true),
          let idle = LoopbackSocket(idle: true) else {
        Check.isTrue(false, "loopback sockets open")
        return
    }
    let here = SocketOwner.Endpoint(udp: false, address: "127.0.0.1", port: tcp.port)
    let datagram = SocketOwner.Endpoint(udp: true, address: "127.0.0.1", port: udp.port)
    let elsewhere = SocketOwner.Endpoint(udp: false, address: "10.9.8.7", port: tcp.port)
    let unaddressed = SocketOwner.Endpoint(udp: false, address: "", port: tcp.port)
    let otherProtocol = SocketOwner.Endpoint(udp: false, address: "127.0.0.1", port: udp.port)
    let listening = SocketOwner.Endpoint(udp: false, address: "127.0.0.1", port: tcp.listenerPort)
    let listeningUnaddressed = SocketOwner.Endpoint(udp: false, address: "", port: tcp.listenerPort)
    let unconnected = SocketOwner.Endpoint(udp: false, address: "127.0.0.1", port: idle.port)

    let started = Date()
    let found = SocketOwner.scan([here, datagram, elsewhere, unaddressed, otherProtocol,
                                  listening, listeningUnaddressed, unconnected])
    let took = Date().timeIntervalSince(started)
    idle.close()
    Check.equal(resolved(found[here]), ownExecutable, "a TCP connection is traced to the program that opened it")
    Check.equal(resolved(found[datagram]), ownExecutable, "and a UDP socket to the one that bound it")
    // Two programs can hold the same port number on different addresses; the
    // address is what tells them apart.
    Check.isNil(found[elsewhere], "the same port on another address is not this socket")
    Check.equal(resolved(found[unaddressed]), ownExecutable, "with no address to go by, the port decides")
    Check.isNil(found[otherProtocol], "a UDP port is not a TCP one")
    // A TCP connection has an address and a port of its own. A server waiting
    // on a port, or a socket bound to no address that never connected, is not
    // where one came from: naming it would put another user's connection,
    // whose socket cannot be read, under this program.
    Check.isNil(found[listening], "a listening socket is not where a connection came from")
    Check.isNil(found[listeningUnaddressed], "not even with no address to go by")
    Check.isNil(found[unconnected], "nor is a TCP socket bound to no address")
    // How long a pass takes depends on the machine, and the lookup spaces its
    // passes to match; this only catches one so slow the page would name
    // nothing at all.
    Check.isTrue(took < 5, "one pass over every socket finishes (took \(Int(took * 1000)) ms)")

    // Each pass is followed by a rest a hundred times its length. A
    // connection that comes during it waits for the next pass, rather than
    // being written off as having no owner.
    let paced = SocketOwner()
    _ = await paced.executables(for: ["a": here], at: 0)
    let resting = await paced.executables(for: ["a": here, "c": datagram], at: 0)
    Check.equal(resolved(resting["a"]), ownExecutable, "a connection named before a rest keeps its name")
    Check.isNil(resting["c"], "one that comes during the rest waits")
    let rested = await paced.executables(for: ["a": here, "c": datagram], at: 1_000)
    Check.equal(resolved(rested["c"]), ownExecutable, "and is named by the next pass")

    // Looked up once per connection: its owner does not change, and a
    // connection whose owner could not be found is not looked for again.
    // The times are far apart, so no pass is held back by the rest.
    let owners = SocketOwner()
    let first = await owners.executables(for: ["a": here], at: 0)
    Check.equal(resolved(first["a"]), ownExecutable, "a connection is given its owner")
    tcp.close()
    let afterClose = await owners.executables(for: ["a": here, "b": here], at: 1_000)
    Check.equal(resolved(afterClose["a"]), ownExecutable, "which it keeps once the socket is gone")
    Check.isNil(afterClose["b"], "a socket that is gone has no owner")
    _ = await owners.executables(for: [:], at: 2_000)
    let forgotten = await owners.executables(for: ["a": here], at: 3_000)
    Check.isNil(forgotten["a"], "a connection that ended is forgotten, not remembered for the next to reuse its name")
    udp.close()
}
