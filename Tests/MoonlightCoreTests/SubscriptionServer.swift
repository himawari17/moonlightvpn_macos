import Foundation

/// A subscription server on loopback, for the refreshes the controller tests
/// make: it answers `GET <anything>/mihomo` with ``body`` after ``delay``
/// seconds, and every other path with a 404.
///
/// Bound to 127.0.0.1 only, like ``Squatter`` — a listener on every interface
/// would ask the person running the suite to let it through the firewall.
final class SubscriptionServer: @unchecked Sendable {
    private let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var _body = ""
    private var _delay: TimeInterval = 0

    var url: String { "http://127.0.0.1:\(port)/token" }

    /// What the next `/mihomo` request gets.
    var body: String {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); _body = newValue; lock.unlock() }
    }

    /// How long the server sits on a `/mihomo` request before answering.
    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        self.fd = fd
        port = Int(in_port_t(bigEndian: actual.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() { close(fd) }

    private func acceptLoop() {
        while true {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            Thread.detachNewThread { [self] in answer(connection) }
        }
    }

    private func answer(_ connection: Int32) {
        defer { close(connection) }
        // A refresh stopped while the server sits on its request has hung up
        // by the time the answer goes out; writing to it must not raise the
        // SIGPIPE that would end the whole suite.
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { return }
            request.append(buffer, count: count)
        }
        let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        let reply: (status: String, body: String)
        if path.hasSuffix("/mihomo") {
            Thread.sleep(forTimeInterval: delay)
            reply = ("200 OK", body)
        } else {
            reply = ("404 Not Found", "")
        }
        let payload = Data(reply.body.utf8)
        let head = "HTTP/1.1 \(reply.status)\r\nContent-Type: text/yaml; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + payload
        response.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = write(connection, bytes.baseAddress! + sent, bytes.count - sent)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
