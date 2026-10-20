import Foundation

/// Fetches a Remnawave subscription and returns a mihomo config plus whatever
/// the panel reports about the plan.
///
/// ## Why the mihomo endpoint is tried first
///
/// Remnawave serves a subscription in six shapes, selected by a path suffix:
/// `mihomo`, `clash`, `singbox`, `stash`, `json` (xray) and `v2ray-json`. The
/// order here is not a preference:
///
/// 1. **`/mihomo`** — a Clash.Meta YAML written by the panel operator. It can
///    carry proxy groups, a `url-test` balancer across a dozen nodes, its own
///    DNS and routing rules. This client keeps that config *verbatim* and
///    overrides only the parts it must own (controller, ports, TUN, split
///    rules), because the panel's tuning is usually better than anything
///    generated here.
/// 2. **`/clash`** — the same idea for stock Clash. Slightly fewer features,
///    still a real config with groups intact.
/// 3. **The bare URL** — base64 or plain share links, one URI per node. Every
///    group, balancer and routing rule is flattened away by that format, so a
///    node whose panel entry was a balancer arrives as a single unusable
///    placeholder. This is the last resort, not a peer of the other two.
///
/// A panel with no MIHOMO template configured 404s the first two, which is
/// exactly when the third earns its place.
public struct SubscriptionClient: Sendable {

    /// What went wrong, worded for a log line — the app shows its own
    /// localised text for each case (`TunnelIssue`), never these.
    ///
    /// Nothing here names the service behind the link or repeats the link: the
    /// log is on screen, and the link is a credential.
    public enum Failure: LocalizedError, Equatable {
        case badURL
        case http(Int)
        case empty
        case unusable(String)
        /// The account is at its device limit. Remnawave answers this with a
        /// *200* and an empty body, so without the header it read as an empty
        /// subscription. Carries the service's own explanation, if it sent one.
        case deviceLimit(announce: String?)
        /// The service requires a device identifier this request did not pass.
        case deviceNotSupported
        /// The service answered with stand-ins instead of servers — see
        /// ``MihomoConfig/isStandIn(_:)``. Carries what the response said about
        /// the plan, which is still true: an expired account is the common
        /// reason, and its days and traffic should show as they are.
        case noServers(info: SubscriptionInfo)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "Subscription link is not a valid http(s) URL"
            case .http(let code): return "Subscription server returned HTTP \(code)"
            case .empty: return "Subscription is empty"
            case .unusable(let why): return why
            case .deviceLimit: return "Device limit reached for this subscription"
            case .deviceNotSupported: return "Subscription requires a device identifier"
            case .noServers: return "Subscription came with placeholder entries and no servers"
            }
        }
    }

    public struct Result: Sendable {
        /// Raw mihomo/Clash YAML, ready for `MihomoConfig` to graft onto.
        public var yaml: String
        public var info: SubscriptionInfo
        /// Which endpoint answered — surfaced in the UI so a base64 fallback
        /// (with its lost groups) is visible rather than silent.
        public var source: Source
    }

    public enum Source: String, Sendable {
        case mihomo
        case clash
        case shareLinks
    }

    private let session: URLSession
    private let device: DeviceIdentity

    public init(session: URLSession? = nil, device: DeviceIdentity) {
        self.session = session ?? Self.makeSession()
        self.device = device
    }

    /// A session that **ignores the machine's proxy settings**.
    ///
    /// This is the macOS counterpart of the Android client excluding itself from
    /// its own tunnel, and it matters for two reasons. While connected in
    /// system-proxy mode the app has pointed the whole machine at its own core,
    /// so a shared session would send the panel request back through the tunnel
    /// it is trying to manage — and a refresh during a half-open tunnel then
    /// hangs instead of failing. It also means a *stale* proxy left by any other
    /// client on the machine cannot swallow this app's requests, which is a
    /// silent hang with no timeout, because the connection is established and
    /// simply never answered.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func fetch(_ subscriptionURL: String) async throws -> Result {
        guard let base = Self.normalize(subscriptionURL) else { throw Failure.badURL }

        var lastError: Error = Failure.empty

        for suffix in ["mihomo", "clash"] {
            do {
                let (body, info) = try await get(base.appendingPathComponent(suffix))
                guard Self.looksLikeClashConfig(body) else {
                    throw Failure.unusable("\(suffix) endpoint did not return a Clash config")
                }
                guard MihomoConfig.hasServers(panelYAML: body) else {
                    throw Failure.noServers(info: info)
                }
                return Result(yaml: body, info: info,
                              source: suffix == "mihomo" ? .mihomo : .clash)
            } catch let failure as Failure where failure.isAboutTheAccount {
                // Every endpoint would say the same; trying the next one only
                // turns a clear answer into a vague one.
                throw failure
            } catch {
                // Stopped on purpose: the next endpoint would only be
                // cancelled in turn.
                try Task.checkCancellation()
                lastError = error
            }
        }

        // Last resort: share links, with every group and routing rule already
        // flattened out of them by the format itself.
        do {
            let (body, info) = try await get(base)
            if Self.looksLikeClashConfig(body) {
                guard MihomoConfig.hasServers(panelYAML: body) else {
                    throw Failure.noServers(info: info)
                }
                return Result(yaml: body, info: info, source: .clash)
            }
            let links = ShareLink.decodeList(body)
            guard !links.isEmpty else { throw Failure.unusable("No nodes found in subscription") }
            let proxies = links.compactMap(ShareLink.mihomoProxy)
            guard !proxies.isEmpty else {
                throw Failure.unusable("Subscription has \(links.count) nodes, none of a type mihomo supports")
            }
            guard proxies.contains(where: { !MihomoConfig.isStandIn($0) }) else {
                throw Failure.noServers(info: info)
            }
            return Result(yaml: MihomoConfig.yamlFromProxies(proxies),
                          info: info, source: .shareLinks)
        } catch {
            lastError = error
        }

        throw lastError
    }

    /// `GET <sub>/info` — Remnawave's own JSON, which carries the device count
    /// the response headers do not.
    public func fetchInfo(_ subscriptionURL: String) async -> SubscriptionInfo? {
        guard let base = Self.normalize(subscriptionURL) else { return nil }
        guard let (data, response) = try? await send(base.appendingPathComponent("info")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? SubscriptionInfo.fromRemnawaveInfo(data)
    }

    // MARK: -

    private func get(_ url: URL) async throws -> (String, SubscriptionInfo) {
        let (data, response) = try await send(url)
        guard let http = response as? HTTPURLResponse else { throw Failure.empty }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        let info = SubscriptionInfo.fromHeaders(http)
        // Checked before the body: at the limit the body is empty, or is a
        // placeholder "node" whose name is the explanation.
        if Self.flag(http, "x-hwid-max-devices-reached") {
            throw Failure.deviceLimit(announce: info.announce)
        }
        if Self.flag(http, "x-hwid-not-supported") {
            throw Failure.deviceNotSupported
        }
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw Failure.empty
        }
        return (body, info)
    }

    private static func flag(_ response: HTTPURLResponse, _ name: String) -> Bool {
        response.value(forHTTPHeaderField: name)?.lowercased() == "true"
    }

    private func send(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Remnawave's device headers. The panel uses these for its device limit
        // and for picking a template when no suffix is given.
        request.setValue(device.hwid, forHTTPHeaderField: "x-hwid")
        request.setValue("macOS", forHTTPHeaderField: "x-device-os")
        request.setValue(device.osVersion, forHTTPHeaderField: "x-ver-os")
        request.setValue(device.model, forHTTPHeaderField: "x-device-model")
        // Panels that route on User-Agent rather than on the suffix still need
        // to see a mihomo client here.
        request.setValue("mihomo/1.19 moonlight/\(device.appVersion)",
                         forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }

    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A scheme that is already present must be http(s) — prepending
        // `https://` to `file:///etc/passwd` or to a `vless://` node link would
        // turn a rejection into a plausible-looking URL, and a deep link must
        // not be able to point the import flow at either.
        let scheme = text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#, options: .regularExpression)
        if let scheme {
            let name = text[..<scheme.upperBound].lowercased()
            guard name == "http://" || name == "https://" else { return nil }
        } else {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        // A trailing slash would make appendingPathComponent produce `//mihomo`.
        let trimmed = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString
        return URL(string: trimmed)
    }

    /// Detected by content, not by `Content-Type` — panels mislabel it, and a
    /// base64 body served as `text/yaml` would otherwise be fed to the parser.
    public static func looksLikeClashConfig(_ body: String) -> Bool {
        body.range(of: #"(?m)^\s*proxies\s*:"#, options: .regularExpression) != nil
    }
}

/// The identity this install presents to the panel.
public struct DeviceIdentity: Sendable {
    /// This Mac's identity for the device limit — derived from the hardware,
    /// so a reinstall is the same device, and hashed, so the hardware's own
    /// identifier stays on the machine. See ``MachineIdentity``.
    public var hwid: String
    public var osVersion: String
    public var model: String
    public var appVersion: String

    public init(hwid: String, osVersion: String, model: String, appVersion: String) {
        self.hwid = hwid
        self.osVersion = osVersion
        self.model = model
        self.appVersion = appVersion
    }
}

public extension SubscriptionInfo {

    /// Parses the headers a Remnawave subscription response carries.
    ///
    /// `subscription-userinfo: upload=0; download=0; total=0; expire=0`
    /// `profile-title`, `announce` — text, plain or `base64:<payload>`
    /// `profile-web-page-url`, `support-url` — links
    /// `profile-update-interval` — hours
    /// `subscription-refill-date` — unix seconds of the next traffic reset
    ///
    /// A zero `total` or `expire` means *unlimited* in this format, not zero, so
    /// both map to nil rather than to 0. `content-disposition` names the account
    /// and `routing` is a routing profile for another client; neither is read.
    /// An expiry date, or nil for Remnawave's "never expires" — which it
    /// writes as a date in 2099 or 2100 rather than leaving the field out, in
    /// the `/info` JSON and in the header alike.
    static func expiry(_ date: Date) -> Date? {
        Calendar(identifier: .gregorian).component(.year, from: date) >= 2099 ? nil : date
    }

    static func fromHeaders(_ response: HTTPURLResponse) -> SubscriptionInfo {
        var info = SubscriptionInfo()

        if let raw = response.value(forHTTPHeaderField: "subscription-userinfo") {
            for field in raw.split(separator: ";") {
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = Int64(parts[1].trimmingCharacters(in: .whitespaces))
                switch key {
                case "upload": info.upload = value
                case "download": info.download = value
                case "total": info.total = (value ?? 0) > 0 ? value : nil
                case "expire":
                    if let value, value > 0 {
                        info.expire = Self.expiry(Date(timeIntervalSince1970: TimeInterval(value)))
                    }
                default: break
                }
            }
        }

        if let title = response.value(forHTTPHeaderField: "profile-title") {
            info.title = Self.text(title)
        }
        if let announce = response.value(forHTTPHeaderField: "announce") {
            info.announce = Self.text(announce)
        }
        if let raw = response.value(forHTTPHeaderField: "profile-web-page-url") {
            info.webPageURL = Self.link(raw, schemes: ["https", "http"])
        }
        if let raw = response.value(forHTTPHeaderField: "support-url") {
            info.supportURL = Self.link(raw, schemes: ["https", "http", "tg", "mailto"])
        }
        if let raw = response.value(forHTTPHeaderField: "profile-update-interval"),
           let hours = Int(raw.trimmingCharacters(in: .whitespaces)), hours > 0 {
            info.updateIntervalHours = hours
        }
        if let raw = response.value(forHTTPHeaderField: "subscription-refill-date"),
           let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            info.refillDate = Date(timeIntervalSince1970: seconds)
        }
        return info
    }

    /// Remnawave's `/info` JSON. Only the fields the design shows are read; the
    /// rest of the document is left alone so a schema addition cannot break it.
    static func fromRemnawaveInfo(_ data: Data) throws -> SubscriptionInfo {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let response = (root?["response"] as? [String: Any]) ?? root ?? [:]
        let user = (response["user"] as? [String: Any]) ?? response

        // The account's username is deliberately not read: it is the service's
        // handle for the user, not a plan name, and has no place on screen.
        var info = SubscriptionInfo()
        info.download = (user["trafficUsed"] as? NSNumber)?.int64Value
            ?? (user["usedTrafficBytes"] as? NSNumber)?.int64Value
        if let limit = (user["trafficLimit"] as? NSNumber)?.int64Value
            ?? (user["trafficLimitBytes"] as? NSNumber)?.int64Value, limit > 0 {
            info.total = limit
        }
        if let raw = user["expiresAt"] as? String,
           let expire = ISO8601DateFormatter.remnawave.date(from: raw)
            ?? ISO8601DateFormatter.remnawaveWhole.date(from: raw) {
            // Read literally, "never expires" showed a plan with 26 892 days
            // left.
            info.expire = SubscriptionInfo.expiry(expire)
        }
        if let limit = (user["hwidDeviceLimit"] as? NSNumber)?.intValue, limit > 0 {
            info.deviceLimit = limit
        }
        if let used = (response["devicesUsed"] as? NSNumber)?.intValue
            ?? (user["devicesUsed"] as? NSNumber)?.intValue {
            info.devicesUsed = used
        }
        return info
    }

    /// Fields present in `other` win, field by field — the header values are the
    /// authoritative ones, and a nil there must not erase a good value.
    func merging(_ other: SubscriptionInfo) -> SubscriptionInfo {
        SubscriptionInfo(
            title: other.title ?? title,
            upload: other.upload ?? upload,
            download: other.download ?? download,
            total: other.total ?? total,
            expire: other.expire ?? expire,
            deviceLimit: other.deviceLimit ?? deviceLimit,
            devicesUsed: other.devicesUsed ?? devicesUsed,
            webPageURL: other.webPageURL ?? webPageURL,
            supportURL: other.supportURL ?? supportURL,
            updateIntervalHours: other.updateIntervalHours ?? updateIntervalHours,
            announce: other.announce ?? announce,
            refillDate: other.refillDate ?? refillDate
        )
    }

    /// A text header, plain or `base64:<payload>` — which is how Remnawave
    /// renders any value its operator wrapped in `rwEncodeBase64:`. Tolerates
    /// URL-safe alphabet and missing padding. Empty reads as absent.
    static func text(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("base64:") {
            var payload = String(value.dropFirst("base64:".count))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload),
               let decoded = String(data: data, encoding: .utf8) {
                value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.isEmpty ? nil : value
    }

    /// A link header, accepted only with one of the expected schemes — the app
    /// opens these on a click, so a `file:` or custom-scheme value is dropped.
    static func link(_ raw: String, schemes: Set<String>) -> URL? {
        guard let text = text(raw), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        return url
    }
}

extension SubscriptionClient.Failure {
    /// Failures that are an answer about the account rather than about one
    /// endpoint.
    var isAboutTheAccount: Bool {
        switch self {
        case .deviceLimit, .deviceNotSupported, .noServers: return true
        default: return false
        }
    }
}

extension ISO8601DateFormatter {
    static let remnawave: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The same without fractional seconds, which the fractional formatter
    /// rejects outright rather than treating as `.000`.
    static let remnawaveWhole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
