import Darwin
import Foundation

/// Which program owns a local socket — asked of the system directly, for a
/// connection the core could not name.
///
/// mihomo finds the process behind a connection in the kernel's socket table
/// (`net.inet.tcp.pcblist_n`). macOS 27 hands that table to an ordinary process
/// empty: the header still counts the sockets, the entries are not there. A
/// core running as the user — system-proxy mode — then returns every
/// connection with no process, and the connections page, which exists to say
/// what each *program* is doing, had one row, "—".
///
/// This asks the other way round: for each of the user's processes, which
/// sockets it holds (`proc_pidfdinfo`), until one is bound to the address and
/// port the connection came from. That reaches every program the user runs. A
/// process of another user — a root daemon — does not let its descriptors be
/// listed, and stays unnamed.
public actor SocketOwner {

    public static let shared = SocketOwner()

    /// Where a connection came from, as the core reports it.
    public struct Endpoint: Hashable, Sendable {
        public var udp: Bool
        /// The source address in text, or empty when the core gave none — the
        /// port alone then decides.
        public var address: String
        public var port: UInt16

        public init(udp: Bool, address: String, port: UInt16) {
            self.udp = udp
            self.address = address
            self.port = port
        }
    }

    /// Connection id → its executable, or nil once looked for and not found.
    /// A connection's owner does not change, and one that could not be found
    /// — another user's, or already gone — will not be found on the next
    /// poll either, so each is looked for once.
    private var known: [String: String?] = [:]

    /// When the next pass may run, in seconds of the system's uptime.
    ///
    /// A pass reads every socket on the machine, so what it costs grows with
    /// the machine, not with how many connections are asked about — and in
    /// system-proxy mode nearly every poll brings a new one. Each pass is
    /// followed by a rest a hundred times as long as it took, which keeps the
    /// lookup under a hundredth of the time on any machine: a pass of a few
    /// milliseconds still runs on every poll, one of 50 ms every five seconds.
    /// A connection that comes in between waits, unnamed, for the next pass.
    private var nextPass: TimeInterval = -.infinity

    public init() {}

    /// The executable behind each connection that has one, by id. Connections
    /// no longer asked about are forgotten. `now` is the system's uptime.
    public func executables(
        for wanted: [String: Endpoint],
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [String: String] {
        known = known.filter { wanted[$0.key] != nil }
        let unseen = wanted.filter { known[$0.key] == nil }
        if !unseen.isEmpty, now >= nextPass {
            let started = ProcessInfo.processInfo.systemUptime
            let found = Self.scan(Set(unseen.values))
            nextPass = now + (ProcessInfo.processInfo.systemUptime - started) * 100
            for (id, endpoint) in unseen { known[id] = .some(found[endpoint]) }
        }
        return known.compactMapValues { $0 }
    }

    /// One pass over the sockets of every process that lets itself be asked.
    public nonisolated static func scan(_ endpoints: Set<Endpoint>) -> [Endpoint: String] {
        guard !endpoints.isEmpty else { return [:] }
        // By port first: nearly every socket met is of no interest.
        var wanted: [UInt16: [(endpoint: Endpoint, address: [UInt8]?)]] = [:]
        for endpoint in endpoints {
            wanted[endpoint.port, default: []].append((endpoint, bytes(of: endpoint.address)))
        }
        /// How sure each answer is: 2 for the very address, 1 for a socket
        /// bound to no address in particular.
        var best: [Endpoint: (pid: pid_t, score: Int)] = [:]

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let entry = MemoryLayout<proc_fdinfo>.size
        var descriptors: [proc_fdinfo] = []

        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            let capacity = Int(size) / entry + 16     // it may open more while being asked
            if descriptors.count < capacity {
                descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            }
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(capacity * entry))
            guard got > 0 else { continue }

            for descriptor in descriptors.prefix(Int(got) / entry)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                          Int32(MemoryLayout<socket_fdinfo>.size))
                guard read == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }

                let udp: Bool
                let inet: in_sockinfo
                switch info.psi.soi_kind {
                case Int32(SOCKINFO_TCP):
                    // A server waiting on a port is never where a connection
                    // came from, even one bound to the very address.
                    guard info.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN else { continue }
                    udp = false
                    inet = info.psi.soi_proto.pri_tcp.tcpsi_ini
                case Int32(SOCKINFO_IN) where info.psi.soi_protocol == IPPROTO_UDP:
                    udp = true
                    inet = info.psi.soi_proto.pri_in
                default:
                    continue
                }
                // Kept in network byte order, in the low half of an int.
                let port = UInt16(truncatingIfNeeded: inet.insi_lport).bigEndian
                guard let candidates = wanted[port] else { continue }
                let local = withUnsafeBytes(of: inet.insi_laddr) { Array($0.prefix(16)) }

                for candidate in candidates where candidate.endpoint.udp == udp {
                    let score = match(candidate.address, local, udp: udp)
                    if score > (best[candidate.endpoint]?.score ?? 0) {
                        best[candidate.endpoint] = (pid, score)
                    }
                }
            }
        }

        var result: [Endpoint: String] = [:]
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for (endpoint, owner) in best where proc_pidpath(owner.pid, &buffer, UInt32(buffer.count)) > 0 {
            result[endpoint] = String(cString: buffer)
        }
        return result
    }

    /// An address as the sixteen or four bytes the kernel keeps; nil for text
    /// that is not one.
    private static func bytes(of address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    /// Whether a socket bound to `local` is where a connection from `wanted`
    /// came from: 2 for that address, 1 for a UDP socket bound to none — or
    /// when there is no address to compare — and 0 for another address, which
    /// is another program's socket that happens to share the port number.
    ///
    /// A TCP socket bound to no address has not connected anywhere, so it is
    /// never the one: counting it would hand a root daemon's connection, whose
    /// own socket cannot be read, to whichever of the user's programs holds
    /// that port on every address.
    private static func match(_ wanted: [UInt8]?, _ local: [UInt8], udp: Bool) -> Int {
        if local.allSatisfy({ $0 == 0 }) { return udp ? 1 : 0 }
        guard let wanted, local.count == 16 else { return 1 }
        // An IPv4 address sits in the last four bytes, whether the socket is
        // an IPv4 one or an IPv6 one talking IPv4.
        let bound = wanted.count == 4 ? Array(local[12...]) : local
        return bound == wanted ? 2 : 0
    }
}
