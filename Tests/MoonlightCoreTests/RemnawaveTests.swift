import Foundation
import MoonlightCore

private func response(_ headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://sub.example/abc")!,
        statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
    )!
}

/// Answers every request with one canned response and counts them.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Runs an async body to completion from the synchronous harness.
private func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

func remnawaveTests() {
    Check.suite("Remnawave headers") {
        let base64 = { (text: String) in "base64:" + Data(text.utf8).base64EncodedString() }
        let info = SubscriptionInfo.fromHeaders(response([
            "profile-title": base64("Луна 🌙"),
            "announce": base64("Плановые работы в 03:00"),
            "profile-web-page-url": "https://sub.example/abc",
            "support-url": "https://t.me/luna_support",
            "profile-update-interval": "12",
            "subscription-refill-date": "1767225600",
            "content-disposition": "attachment; filename=tg_12345",
        ]))
        Check.equal(info.title, "Луна 🌙", "profile-title, rwEncodeBase64")
        Check.equal(info.announce, "Плановые работы в 03:00", "announce, rwEncodeBase64")
        Check.equal(info.webPageURL?.absoluteString, "https://sub.example/abc", "profile-web-page-url")
        Check.equal(info.supportURL?.absoluteString, "https://t.me/luna_support", "support-url")
        Check.equal(info.updateIntervalHours, 12, "profile-update-interval in hours")
        Check.equal(info.refillDate, Date(timeIntervalSince1970: 1_767_225_600), "subscription-refill-date")
        Check.isNil(info.title == "tg_12345" ? info.title : nil,
                    "content-disposition's account name is not used as a title")

        // URL-safe alphabet, no padding — both seen in the wild.
        let urlSafe = "base64:" + Data("ok?>".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        Check.equal(SubscriptionInfo.fromHeaders(response(["announce": urlSafe])).announce, "ok?>",
                    "url-safe base64 without padding decodes")

        let hostile = SubscriptionInfo.fromHeaders(response([
            "profile-web-page-url": "file:///etc/passwd",
            "support-url": "javascript:alert(1)",
            "profile-update-interval": "0",
            "announce": "   ",
        ]))
        Check.isNil(hostile.webPageURL, "a file: page link is dropped")
        Check.isNil(hostile.supportURL, "a script: support link is dropped")
        Check.isNil(hostile.updateIntervalHours, "a zero interval is no suggestion")
        Check.isNil(hostile.announce, "a blank announcement is none")

        Check.equal(SubscriptionInfo.fromHeaders(response(["support-url": "tg://resolve?domain=x"]))
                        .supportURL?.scheme, "tg", "a Telegram deep link is a valid support link")

        let merged = SubscriptionInfo(announce: "old", refillDate: Date(timeIntervalSince1970: 1))
            .merging(SubscriptionInfo(updateIntervalHours: 6))
        Check.equal(merged.announce, "old", "new fields survive a merge")
        Check.equal(merged.updateIntervalHours, 6, "and take the newer value")
    }

    Check.suite("Remnawave never-expiring plan") {
        let forever = """
        {"response":{"user":{"expiresAt":"2099-05-14T00:00:00.000Z"}}}
        """
        Check.isNil(try! SubscriptionInfo.fromRemnawaveInfo(Data(forever.utf8)).expire,
                    "2099 is Remnawave for no expiry, not 26 892 days")
        let whole = """
        {"response":{"user":{"expiresAt":"2027-01-01T00:00:00Z"}}}
        """
        Check.notNil(try! SubscriptionInfo.fromRemnawaveInfo(Data(whole.utf8)).expire,
                     "a date without fractional seconds still parses")
    }

    Check.suite("Issues shown to the user") {
        Check.equal(TunnelIssue.classify(SubscriptionClient.Failure.http(502)),
                    .serverUnavailable(code: 502), "a 5xx is the server being unavailable")
        Check.equal(TunnelIssue.classify(SubscriptionClient.Failure.http(404)),
                    .linkRejected, "a 404 is a link that no longer works")
        Check.equal(TunnelIssue.classify(URLError(.notConnectedToInternet)),
                    .offline, "no network is offline, not a server fault")
        Check.equal(TunnelIssue.classify(URLError(.timedOut)),
                    .serverUnavailable(code: nil), "a timeout is the server")
        Check.equal(TunnelIssue.classify(SubscriptionClient.Failure.deviceLimit(announce: "x")),
                    .deviceLimit(message: "x"), "the device limit keeps the service's message")
        Check.equal(TunnelIssue.classify(TunFailure(routesTaken: true, reason: "")),
                    .routesTaken, "another VPN's routes")
        // The core's own words, carried in the error: a database it could not
        // download is not the core failing.
        let blocked = """
            level=error msg="rules[13] [IP-ASN,13335,REJECT,no-resolve] error: can't download ASN.mmdb: \
            Get \"https://example.org/GeoLite2-ASN.mmdb\": dns resolve failed: couldn't find ip"
            configuration file /tmp/own-rules.yaml test failed
            """
        Check.equal(TunnelIssue.classify(MihomoProcess.Failure.exited(1, blocked)),
                    .databaseBlocked(asn: true), "a blocked IP-ASN download, from the core's check")
        Check.equal(TunnelIssue.classify(CoreUnresponsive(log: "can't download GeoSite.dat: EOF")),
                    .databaseBlocked(asn: false), "and another database, from a core that never answered")
        Check.equal(TunnelIssue.classify(MihomoProcess.Failure.exited(1, "rules[0] error: unsupported rule type")),
                    .coreFailed, "a config the core refuses is still the core failing")
        for failure in [SubscriptionClient.Failure.http(502), .empty, .badURL, .deviceLimit(announce: nil)] {
            let text = (failure.errorDescription ?? "").lowercased()
            Check.isTrue(!text.contains("panel"), "log text does not name the panel: \(text)")
        }
    }

    Check.suite("Auto-update interval") {
        Check.equal(TunnelController.autoUpdateChoice(nearest: 0), 0, "off stays off")
        Check.equal(TunnelController.autoUpdateChoice(nearest: 3), 1, "3 h snaps to the nearest offer")
        Check.equal(TunnelController.autoUpdateChoice(nearest: 10), 12, "10 h snaps to 12")
        Check.equal(TunnelController.autoUpdateChoice(nearest: 168), 24, "a week caps at a day")
    }

    Check.suite("Device limit") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = SubscriptionClient(
            session: URLSession(configuration: configuration),
            device: DeviceIdentity(hwid: "h", osVersion: "o", model: "m", appVersion: "1")
        )
        StubProtocol.headers = [
            "x-hwid-max-devices-reached": "true",
            "announce": "base64:" + Data("Лимит: 3 устройства".utf8).base64EncodedString(),
        ]
        StubProtocol.body = Data()
        StubProtocol.requests = 0
        let outcome: String = blocking {
            do {
                _ = try await client.fetch("https://sub.example/abc")
                return "fetched"
            } catch let failure as SubscriptionClient.Failure {
                if case .deviceLimit(let announce) = failure { return "limit:\(announce ?? "")" }
                return "other:\(failure)"
            } catch {
                return "error:\(error)"
            }
        }
        Check.equal(outcome, "limit:Лимит: 3 устройства",
                    "a 200 with the limit header is the device limit, not an empty subscription")
        Check.equal(StubProtocol.requests, 1, "and the other endpoints are not tried after it")
    }

    Check.suite("Stand-ins instead of servers") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = SubscriptionClient(
            session: URLSession(configuration: configuration),
            device: DeviceIdentity(hwid: "h", osVersion: "o", model: "m", appVersion: "1")
        )
        StubProtocol.headers = ["subscription-userinfo": "upload=0; download=5; total=10; expire=0"]
        StubProtocol.body = Data("""
        proxies:
          - {name: "→ Подписка истекла", type: vless, server: 0.0.0.0, port: 1, uuid: 00000000-0000-0000-0000-000000000000}
        """.utf8)
        StubProtocol.requests = 0
        let outcome: String = blocking {
            do {
                _ = try await client.fetch("https://sub.example/abc")
                return "fetched"
            } catch let failure as SubscriptionClient.Failure {
                if case .noServers(let info) = failure { return "none:\(info.total ?? 0)" }
                return "other:\(failure)"
            } catch {
                return "error:\(error)"
            }
        }
        Check.equal(outcome, "none:10", "a list of stand-ins is no servers, with the plan's figures kept")
        Check.equal(StubProtocol.requests, 1,
                    "and the share-link fallback is not tried — it would bring the same stand-ins")
    }
}
