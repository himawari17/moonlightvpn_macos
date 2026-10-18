import Foundation

/// A routing rule of the user's own: what to match, and where to send it —
/// around the tunnel, nowhere, or through one of the subscription's groups.
///
/// Kept apart from the subscription and stored by the app, so a refresh never
/// touches it. Each rule sits either before the subscription's rules
/// (``Priority/override``) or after them (``Priority/extend``); mihomo takes
/// the first rule that matches, so that choice is the whole of its priority.
/// This is how Flowvy's "Мои правила" work, and the grammar is mihomo's own.
public struct RoutingRule: Identifiable, Hashable, Codable, Sendable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case domain = "DOMAIN"
        case domainSuffix = "DOMAIN-SUFFIX"
        case domainKeyword = "DOMAIN-KEYWORD"
        case domainRegex = "DOMAIN-REGEX"
        case geosite = "GEOSITE"
        case ipCIDR = "IP-CIDR"
        case ipCIDR6 = "IP-CIDR6"
        case ipASN = "IP-ASN"
        case geoip = "GEOIP"
        case srcIPCIDR = "SRC-IP-CIDR"
        case dstPort = "DST-PORT"
        case srcPort = "SRC-PORT"
        case processName = "PROCESS-NAME"
        case processNameRegex = "PROCESS-NAME-REGEX"
        case processPath = "PROCESS-PATH"
        case processPathRegex = "PROCESS-PATH-REGEX"
        case network = "NETWORK"

        /// The headings the type picker groups kinds under.
        public enum Family: String, CaseIterable, Sendable {
            case domain, ip, port, process, other
        }

        public var family: Family {
            switch self {
            case .domain, .domainSuffix, .domainKeyword, .domainRegex, .geosite: return .domain
            case .ipCIDR, .ipCIDR6, .ipASN, .geoip, .srcIPCIDR: return .ip
            case .dstPort, .srcPort: return .port
            case .processName, .processNameRegex, .processPath, .processPathRegex: return .process
            case .network: return .other
            }
        }

        /// Whether the core has to know the process behind a connection to
        /// evaluate this, which only TUN gives it.
        public var needsProcessMatching: Bool { family == .process }

        /// Whether the core has to download a database before it can load a
        /// rule of this kind: the AS numbers IP-ASN matches, which the app does
        /// not ship (see ``Geodata/asnFileName``). Where that download is
        /// blocked, no config with such a rule loads.
        public var needsDownload: Bool { self == .ipASN }

        /// Address rules carry `no-resolve`, so a domain is not looked up just
        /// to be tested against an address — a DNS query per connection.
        var wantsNoResolve: Bool {
            [.ipCIDR, .ipCIDR6, .ipASN, .geoip].contains(self)
        }

        public var placeholder: String {
            switch self {
            case .domain: return "example.com"
            case .domainSuffix: return "google.com"
            case .domainKeyword: return "google"
            case .domainRegex: return #"^.*\.discord\.(com|gg)$"#
            case .geosite: return "youtube"
            case .ipCIDR: return "192.168.1.0/24"
            case .ipCIDR6: return "2001:db8::/32"
            case .ipASN: return "13335"
            case .geoip: return "ru"
            case .srcIPCIDR: return "192.168.1.0/24"
            case .dstPort: return "443"
            case .srcPort: return "7777"
            case .processName: return "Telegram"
            case .processNameRegex: return "(?i).*chrome.*"
            case .processPath: return "/Applications/Safari.app/Contents/MacOS/Safari"
            case .processPathRegex: return "(?i).*/steam.*"
            case .network: return "udp"
            }
        }
    }

    public enum Priority: String, Codable, CaseIterable, Sendable {
        /// Before the subscription's rules: wins over them.
        case override
        /// After the subscription's rules, before its catch-all: only what they
        /// leave unmatched reaches it.
        case extend
    }

    /// The two targets every config has, besides the subscription's groups.
    public static let direct = "DIRECT"
    public static let reject = "REJECT"

    public var id: UUID
    public var kind: Kind
    public var value: String
    public var target: String
    public var priority: Priority
    public var enabled: Bool

    public init(
        id: UUID = UUID(), kind: Kind, value: String, target: String,
        priority: Priority = .override, enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.target = target
        self.priority = priority
        self.enabled = enabled
    }

    /// The rule as mihomo's rule grammar writes it.
    public var line: String {
        let suffix = kind.wantsNoResolve ? ",no-resolve" : ""
        return "\(kind.rawValue),\(value.trimmingCharacters(in: .whitespaces)),\(target)\(suffix)"
    }

    // MARK: Validation

    public enum Invalid: Error, Equatable, Sendable {
        case empty
        case containsComma
        case badRegex
        case badPort
        case badCIDR
        case badASN
        case badNetwork
    }

    /// Checked before a rule is kept, because a bad one does not fail on its
    /// own: mihomo refuses the whole config, and the tunnel stops working
    /// rather than the rule being skipped.
    public static func validate(kind: Kind, value: String) -> Invalid? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }
        // mihomo splits a rule on commas, so one in the value silently turns
        // it into a different rule.
        guard !value.contains(",") else { return .containsComma }

        switch kind {
        case .domainRegex, .processNameRegex, .processPathRegex:
            guard (try? NSRegularExpression(pattern: value)) != nil else { return .badRegex }
        case .dstPort, .srcPort:
            // "443", a range "1000-2000", or several joined by "/".
            let ranges = value.split(separator: "/", omittingEmptySubsequences: false)
            for range in ranges {
                let ends = range.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count),
                      ends.allSatisfy({ Int($0).map { (0...65535).contains($0) } ?? false })
                else { return .badPort }
                if ends.count == 2, let low = Int(ends[0]), let high = Int(ends[1]), low > high {
                    return .badPort
                }
            }
        case .ipCIDR, .srcIPCIDR:
            guard isCIDR(value, v6: false) else { return .badCIDR }
        case .ipCIDR6:
            guard isCIDR(value, v6: true) else { return .badCIDR }
        case .ipASN:
            guard let asn = UInt32(value), asn > 0 else { return .badASN }
        case .network:
            guard ["tcp", "udp"].contains(value.lowercased()) else { return .badNetwork }
        default:
            break
        }
        return nil
    }

    private static func isCIDR(_ value: String, v6: Bool) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let address = String(parts[0])
        if address.contains(":") {
            guard (0...128).contains(bits) else { return false }
            var raw = in6_addr()
            return inet_pton(AF_INET6, address, &raw) == 1
        }
        guard !v6, (0...32).contains(bits) else { return false }
        var raw = in_addr()
        return inet_pton(AF_INET, address, &raw) == 1
    }
}

/// One of the subscription's own rules, split into what a table shows.
///
/// Parsed rather than split on commas: a logical rule —
/// `AND,((DOMAIN,x),(NETWORK,udp)),Group` — carries commas inside its
/// parentheses, and a trailing `no-resolve` is a parameter, not the target.
public struct ProfileRule: Hashable, Sendable {
    public var kind: String
    public var value: String
    public var target: String

    public init(line: String) {
        var fields: [String] = []
        var current = ""
        var depth = 0
        for character in line {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth -= 1; current.append(character)
            case "," where depth == 0:
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))

        // Parameters the core accepts after the target.
        while fields.count > 2, ["no-resolve", "src"].contains(fields.last?.lowercased() ?? "") {
            fields.removeLast()
        }
        kind = fields.first?.uppercased() ?? ""
        if fields.count >= 3 {
            value = fields[1..<(fields.count - 1)].joined(separator: ",")
            target = fields[fields.count - 1]
        } else {
            // `MATCH,Group` — nothing to match on.
            value = ""
            target = fields.count == 2 ? fields[1] : ""
        }
    }
}
