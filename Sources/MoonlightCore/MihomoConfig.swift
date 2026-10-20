import Foundation
import Yams

/// Builds the config mihomo actually runs, from the config the panel serves.
///
/// The panel's document is kept **verbatim** — its `proxies`, `proxy-groups`,
/// `rules` and `dns` are usually better tuned than anything generated here, and
/// a panel that ships a `url-test` balancer or a `geosite:category-ru` direct
/// rule means it. This type overrides only what the client must own:
///
/// - the RESTful API address and secret, which is how the app talks to the core
/// - the local listener port
/// - `allow-lan: false` and a loopback bind — this is a single-machine client,
///   and an unbound listener is an open proxy on the network
/// - the TUN block, when the tunnel runs in TUN mode
/// - the user's own rules, around the panel's (see ``placeOwnRules(_:around:targets:)``)
/// - a sniffer, when the panel has none switched on (see ``snifferBlock()``)
public struct MihomoConfig {

    public struct Overrides: Sendable {
        public var controllerPort: Int
        public var secret: String
        public var mixedPort: Int
        public var mode: TunnelMode
        /// The core's `mode`: rules, everything through the server, or nothing.
        public var routingMode: RoutingMode
        /// The user's own routing rules, kept by the app.
        public var routingRules: [RoutingRule]
        public var logLevel: String
        /// Where mihomo keeps its geo databases and cache.
        public var dataDirectory: String

        public init(
            controllerPort: Int = 9797,
            secret: String,
            mixedPort: Int = 7897,
            mode: TunnelMode = .systemProxy,
            routingMode: RoutingMode = .rule,
            routingRules: [RoutingRule] = [],
            logLevel: String = "warning",
            dataDirectory: String
        ) {
            self.controllerPort = controllerPort
            self.secret = secret
            self.mixedPort = mixedPort
            self.mode = mode
            self.routingMode = routingMode
            self.routingRules = routingRules
            self.logLevel = logLevel
            self.dataDirectory = dataDirectory
        }
    }

    public enum Failure: LocalizedError {
        case notAMapping
        case noProxies

        public var errorDescription: String? {
            switch self {
            case .notAMapping: return "Subscription is not a YAML mapping"
            case .noProxies: return "Subscription contains no proxies"
            }
        }
    }

    /// Grafts `overrides` onto the panel's YAML and returns the result.
    public static func build(panelYAML: String, overrides: Overrides) throws -> String {
        guard var root = try Yams.load(yaml: panelYAML) as? [String: Any] else {
            throw Failure.notAMapping
        }
        let proxies = root["proxies"] as? [[String: Any]] ?? []
        guard !proxies.isEmpty else { throw Failure.noProxies }

        // ── Client-owned general settings ───────────────────────────────────
        root["mixed-port"] = overrides.mixedPort
        root["external-controller"] = "127.0.0.1:\(overrides.controllerPort)"
        root["secret"] = overrides.secret
        root["log-level"] = overrides.logLevel
        // The user's choice, never the panel's: a panel's `global` would
        // ignore its own routing rules without anyone having asked for that.
        root["mode"] = overrides.routingMode.rawValue
        root["allow-lan"] = false
        root["bind-address"] = "127.0.0.1"
        // Ports the panel may have set are removed rather than left listening:
        // one mixed port is the whole surface this client needs.
        for key in ["port", "socks-port", "redir-port", "tproxy-port", "external-ui",
                    "external-controller-tls", "external-controller-unix"] {
            root.removeValue(forKey: key)
        }
        // Always on. It costs a `libproc` lookup per connection, which is cheap,
        // and two things depend on it: `PROCESS-*` rules, and the
        // connections screen — whose entire question is *which program* is going
        // where. Switching it off when no process rule happened to be configured
        // left that screen showing every connection as "—".
        root["find-process-mode"] = "always"

        // ── Groups ──────────────────────────────────────────────────────────
        // A config from the share-link fallback has no groups; one from a panel
        // template almost always does, and those are left exactly as they are.
        var groups = root["proxy-groups"] as? [[String: Any]] ?? []
        if groups.isEmpty {
            groups = defaultGroups(proxyNames: proxies.compactMap { $0["name"] as? String })
            root["proxy-groups"] = groups
        }

        // ── Routing ─────────────────────────────────────────────────────────
        var rules = root["rules"] as? [String] ?? []
        if rules.isEmpty {
            rules = ["MATCH,\(Self.defaultSelector)"]
        }
        let targets = Set([RoutingRule.direct, RoutingRule.reject])
            .union(groups.compactMap { $0["name"] as? String })
            .union(proxies.compactMap { $0["name"] as? String })
        let own = placeOwnRules(overrides.routingRules, around: rules, targets: targets)
        root["rules"] = own.before + own.rules

        // ── Sniffer ─────────────────────────────────────────────────────────
        // A panel that switched one on means it, and keeps it. One that has
        // none — or has one switched off, as mihomo's sample config ships it —
        // gets the app's, because without it the rules above go blind the
        // moment a browser resolves names itself.
        let panelSniffer = root["sniffer"] as? [String: Any]
        if panelSniffer?["enable"] as? Bool != true {
            root["sniffer"] = snifferBlock()
        }

        // ── TUN ─────────────────────────────────────────────────────────────
        if overrides.mode == .tun {
            root["tun"] = tunBlock()
            // TUN without DNS hijacking leaks every lookup to the resolver the
            // machine had before the interface came up.
            root["dns"] = dnsBlock(existing: root["dns"] as? [String: Any])
        } else {
            root.removeValue(forKey: "tun")
        }

        return try Yams.dump(object: root, sortKeys: true)
    }

    /// What the service says each row is for, by name: a server's
    /// `serverDescription`, or a group's `description` — a balancer such as
    /// "🇵🇱 Poland LTE 1" is a row in the list like any server. Blank ones are
    /// left out.
    public static func serverDescriptions(panelYAML: String) -> [String: String] {
        guard let root = try? Yams.load(yaml: panelYAML) as? [String: Any] else { return [:] }
        var descriptions: [String: String] = [:]
        let entries = [("proxies", "serverDescription"), ("proxy-groups", "description")]
        for (section, key) in entries {
            for entry in root[section] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String,
                      let text = (entry[key] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                descriptions[name] = text
            }
        }
        return descriptions
    }

    /// The subscription's servers by name, in the order it lists them — which
    /// is the order the panel keeps its hosts in.
    public static func proxyOrder(panelYAML: String) -> [String] {
        guard let root = try? Yams.load(yaml: panelYAML) as? [String: Any] else { return [] }
        return (root["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// `names` — a group's members as the core reports them — with the
    /// servers put back in the subscription's order.
    ///
    /// A group that takes its servers with `include-all` gets them from the
    /// core sorted by name, so the panel's order — Russia, Estonia, Latvia… —
    /// reached the screen as Germany, Germany, Estonia 2… Only the servers
    /// move, and only among the places servers held: an entry the
    /// subscription does not list as a server, such as an auto-picker the
    /// group names first, stays where the group put it.
    public static func inPanelOrder(_ names: [String], order: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() where rank[name] == nil { rank[name] = index }
        var servers = names.filter { rank[$0] != nil }
            .sorted { rank[$0]! < rank[$1]! }
            .makeIterator()
        return names.map { rank[$0] == nil ? $0 : servers.next()! }
    }

    /// Whether a subscription entry is a stand-in rather than a server.
    ///
    /// When the panel has no server to give this client — none configured for
    /// this kind of subscription, or an account that is expired, over its
    /// traffic or switched off — it still answers with a list: entries whose
    /// names carry its message ("No hosts found", "Подписка истекла") and
    /// which point at `0.0.0.0`, port 1, with an all-zero UUID. Taken as a
    /// refresh, they replaced every working server with rows that connect to
    /// nothing.
    public static func isStandIn(_ proxy: [String: Any]) -> Bool {
        let server = (proxy["server"] as? String)?.trimmingCharacters(in: .whitespaces)
        if server == "0.0.0.0" || server == "::" { return true }
        let id = (proxy["uuid"] as? String) ?? (proxy["password"] as? String)
        return id == "00000000-0000-0000-0000-000000000000"
    }

    /// Whether the subscription has at least one real server — see
    /// ``isStandIn(_:)``.
    public static func hasServers(panelYAML: String) -> Bool {
        guard let root = try? Yams.load(yaml: panelYAML) as? [String: Any] else { return false }
        return (root["proxies"] as? [[String: Any]] ?? []).contains { !isStandIn($0) }
    }

    /// A minimal config that carries just a proxy list — the shape the
    /// share-link fallback produces before ``build(panelYAML:overrides:)`` runs.
    public static func yamlFromProxies(_ proxies: [[String: Any]]) -> String {
        let names = proxies.compactMap { $0["name"] as? String }
        let root: [String: Any] = [
            "proxies": proxies,
            "proxy-groups": defaultGroups(proxyNames: names),
            "rules": ["MATCH,\(defaultSelector)"],
        ]
        return (try? Yams.dump(object: root, sortKeys: true)) ?? ""
    }

    public static let defaultSelector = "MOONLIGHT"
    public static let defaultAutoGroup = "MOONLIGHT-AUTO"

    public static func defaultGroups(proxyNames: [String]) -> [[String: Any]] {
        [
            [
                "name": defaultSelector,
                "type": "select",
                "proxies": [defaultAutoGroup] + proxyNames,
            ],
            [
                "name": defaultAutoGroup,
                "type": "url-test",
                "proxies": proxyNames,
                "url": MihomoAPI.probeURL,
                "interval": 300,
                "tolerance": 50,
            ],
        ]
    }

    /// The group the app drives when the user picks a node.
    ///
    /// A panel names its groups whatever it likes, so the group is found the way
    /// the config itself points at it: the target of the catch-all `MATCH` rule,
    /// falling back to the first `select` group. Guessing by name would break on
    /// any panel that localises its group labels.
    public static func primarySelectorName(groups: [[String: Any]], rules: [String]) -> String {
        if let match = rules.last(where: { $0.uppercased().hasPrefix("MATCH,") }) {
            let target = match.dropFirst("MATCH,".count).trimmingCharacters(in: .whitespaces)
            if groups.contains(where: { $0["name"] as? String == target }) { return target }
        }
        if let selector = groups.first(where: { ($0["type"] as? String) == "select" }),
           let name = selector["name"] as? String {
            return name
        }
        return groups.first?["name"] as? String ?? defaultSelector
    }

    // MARK: - The user's own rules

    /// Places the user's own rules around the panel's.
    ///
    /// Overrides go before everything. Extensions go after the panel's rules
    /// but *before* its catch-all `MATCH`: appended after it, as the grammar
    /// would literally have it, they could never match anything.
    ///
    /// A rule is left out rather than written when it is switched off, when
    /// its value no longer validates, or when it points at a group the
    /// subscription no longer has — mihomo refuses a whole config over one
    /// rule naming a proxy it does not know, so a refresh that dropped a group
    /// would otherwise take the tunnel down with it.
    public static func placeOwnRules(
        _ own: [RoutingRule], around rules: [String], targets: Set<String>
    ) -> (before: [String], rules: [String]) {
        let usable = own.filter {
            $0.enabled && targets.contains($0.target)
                && RoutingRule.validate(kind: $0.kind, value: $0.value) == nil
        }
        let before = usable.filter { $0.priority == .override }.map(\.line)
        let after = usable.filter { $0.priority == .extend }.map(\.line)
        var rules = rules
        if let last = rules.last, last.uppercased().hasPrefix("MATCH,") {
            rules.insert(contentsOf: after, at: rules.count - 1)
        } else {
            rules += after
        }
        return (before, rules)
    }

    /// What the rules screen needs to offer targets and to show the
    /// subscription's own rules: its group names, in order, and its rules.
    public static func routingInputs(panelYAML: String) -> (groups: [String], rules: [String]) {
        guard let root = try? Yams.load(yaml: panelYAML) as? [String: Any] else { return ([], []) }
        var groups = (root["proxy-groups"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        // A config with no groups gets the app's own when it is built.
        if groups.isEmpty, root["proxies"] != nil { groups = [defaultSelector, defaultAutoGroup] }
        return (groups, root["rules"] as? [String] ?? [])
    }

    // MARK: - Sniffer

    /// Has the core read the hostname out of a connection that arrived as a
    /// bare address.
    ///
    /// A browser on secure DNS — Chrome's "Use secure DNS" with Google or
    /// Cloudflare — resolves names itself, over HTTPS, past the core's DNS. In
    /// TUN its connections then reach the core as bare addresses, with nothing
    /// for the fake-ip table to map back, so no `DOMAIN-SUFFIX` or `GEOSITE`
    /// rule can match them: everything fell through to the catch-all and went
    /// to the server as a bare address — a `.ru` site the panel sends `DIRECT`
    /// included, and IPv6 ones the core's own DNS (`ipv6: false`) never hands
    /// out — and the connections screen listed addresses where it had always
    /// listed hosts. The browser saw `ERR_CONNECTION_CLOSED` wherever the far
    /// end could not carry that.
    ///
    /// With the sniffer the core reads the name from the TLS ClientHello, the
    /// QUIC Initial, or the HTTP `Host` header, matches the rules on it, and —
    /// `override-destination` — dials the *name* rather than the address: the
    /// server resolves it the way it can reach it, and a `DIRECT` connection
    /// resolves it through the panel's DNS, Yandex for Russian names. Ports and
    /// skips are those of the example configs in mihomo's documentation; the
    /// three switches are the core's own defaults for a sniffer that is on,
    /// written out so the config says what it does.
    public static func snifferBlock() -> [String: Any] {
        [
            "enable": true,
            // Sniff connections that came in as a bare address — the browser
            // case — and those whose name the core could only recover from a
            // real (not fake) IP it had answered with.
            "parse-pure-ip": true,
            "force-dns-mapping": true,
            "override-destination": true,
            // Ports as strings: a range has to be one, and the core's parser
            // takes a list of them.
            "sniff": [
                "HTTP": ["ports": ["80", "8080-8880"]],
                "TLS": ["ports": ["443", "8443"]],
                "QUIC": ["ports": ["443", "8443"]],
            ] as [String: Any],
            // Apple's push service is left at the address the system chose for
            // it, as those examples leave it.
            "skip-domain": ["+.push.apple.com"],
        ]
    }

    // MARK: - TUN

    public static func tunBlock() -> [String: Any] {
        [
            "enable": true,
            // No `device`: macOS requires a `utun` name, and a hardcoded one
            // collides with whichever VPN client already holds it. Letting the
            // core pick the first free index is the only way to be sure.
            // `mixed` is the recommended stack: gvisor's userspace TCP with the
            // system stack's UDP, which avoids gvisor's UDP throughput cost.
            "stack": "mixed",
            "auto-route": true,
            "auto-detect-interface": true,
            "strict-route": false,
            "dns-hijack": ["any:53", "tcp://any:53"],
            "mtu": 1500,
        ]
    }

    /// DNS for TUN mode.
    ///
    /// A panel's own `dns` block is kept if it has one — it may point at a
    /// resolver inside the tunnel on purpose. Only the fields TUN needs are
    /// forced on: without `enable`, mihomo does not answer the queries
    /// `dns-hijack` redirects to it, and the tunnel resolves nothing.
    static func dnsBlock(existing: [String: Any]?) -> [String: Any] {
        var dns = existing ?? [:]
        dns["enable"] = true
        dns["ipv6"] = dns["ipv6"] ?? false
        dns["listen"] = dns["listen"] ?? "127.0.0.1:53535"
        // A fake-ip range keeps DNS out of the round trip for proxied hosts.
        dns["enhanced-mode"] = dns["enhanced-mode"] ?? "fake-ip"
        dns["fake-ip-range"] = dns["fake-ip-range"] ?? "198.18.0.1/16"
        if dns["nameserver"] == nil {
            dns["nameserver"] = ["https://1.1.1.1/dns-query", "https://dns.google/dns-query"]
        }
        return dns
    }
}
