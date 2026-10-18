import Foundation

/// Something the user needs to know went wrong — as a kind, not a sentence.
///
/// The app words each case itself, in the user's language. Errors used to
/// reach the screen as their own English descriptions, which named the service
/// behind the subscription ("Panel returned HTTP 502") and could carry a link
/// or a server address. Those descriptions still go to the log, with the
/// sensitive parts redacted (see `LogStore`); the screen only ever gets this.
public enum TunnelIssue: Equatable, Sendable {
    /// What was pasted is not a subscription link.
    case invalidLink
    /// Connecting with no subscription.
    case noSubscription
    /// This Mac is offline.
    case offline
    /// The subscription server did not answer properly — down, overloaded, or
    /// unreachable. The HTTP status, when there was one, is kept for support.
    case serverUnavailable(code: Int?)
    /// The link was refused: revoked, mistyped, or the plan was deleted.
    case linkRejected
    /// The subscription answered with nothing in it.
    case emptySubscription
    /// It has servers, but none this app can use.
    case noUsableServers
    /// The account is at its device limit, with the service's own explanation
    /// when it sent one.
    case deviceLimit(message: String?)
    /// The service wants a device identifier this request could not give.
    case deviceNotSupported
    /// The core would not start.
    case coreFailed
    /// The core stopped on its own while connected.
    case coreStopped
    /// Another VPN or proxy already owns the system routes TUN needs.
    case routesTaken
    /// The TUN interface could not be created for any other reason.
    case tunFailed
    /// TUN needs the helper and it is missing or not answering.
    case helperMissing
    /// The installed helper is from another version of the app.
    case helperOutdated
    /// The core needed a database it downloads on first use, and the download
    /// did not go through — for an IP-ASN rule, the one database the app does
    /// not ship. Nothing loads until it does.
    case databaseBlocked(asn: Bool)

    public static func classify(_ error: Error) -> TunnelIssue {
        // Said in the core's own output, which comes along in the error: not
        // the core failing, and not something the core will get past alone.
        if let file = Geodata.blockedDownload(in: error.localizedDescription) {
            return .databaseBlocked(asn: file == Geodata.asnFileName)
        }
        switch error {
        case let failure as SubscriptionClient.Failure:
            switch failure {
            case .badURL: return .invalidLink
            case .http(let code) where [401, 403, 404, 410].contains(code): return .linkRejected
            case .http(let code): return .serverUnavailable(code: code)
            case .empty: return .emptySubscription
            case .unusable: return .noUsableServers
            case .deviceLimit(let message): return .deviceLimit(message: message)
            case .deviceNotSupported: return .deviceNotSupported
            }
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff:
                return .offline
            default:
                return .serverUnavailable(code: nil)
            }
        case let failure as HelperClient.Failure:
            switch failure {
            case .notInstalled, .io: return .helperMissing
            case .versionMismatch: return .helperOutdated
            case .refused: return .coreFailed
            }
        case is HelperInstaller.Failure:
            // The helper needed its core updated and the prompt was refused.
            return .helperOutdated
        case let failure as TunFailure:
            return failure.routesTaken ? .routesTaken : .tunFailed
        case is MihomoConfig.Failure:
            return .noUsableServers
        default:
            return .coreFailed
        }
    }
}

/// TUN came up in the core but not in the system.
public struct TunFailure: LocalizedError {
    /// Another client's routes are in the way — the common case by far.
    public let routesTaken: Bool
    public let reason: String

    public init(routesTaken: Bool, reason: String) {
        self.routesTaken = routesTaken
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}
