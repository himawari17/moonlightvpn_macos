import Foundation
import Yams
import MoonlightCore

private func overrides(mode: TunnelMode = .systemProxy) -> MihomoConfig.Overrides {
    MihomoConfig.Overrides(
        controllerPort: 9797, secret: "s3cret", mixedPort: 7897,
        mode: mode, dataDirectory: "/tmp/moonlight-core"
    )
}

private let panelYAML = """
port: 7890
socks-port: 7891
allow-lan: true
external-controller: 0.0.0.0:9090
secret: ""
mode: global
dns:
  enable: true
  nameserver: ["223.5.5.5"]
proxies:
  - {name: "🇳🇱 Amsterdam", type: ss, server: 1.2.3.4, port: 443, cipher: aes-256-gcm, password: pw}
  - {name: "🇫🇮 Helsinki",  type: ss, server: 1.2.3.5, port: 443, cipher: aes-256-gcm, password: pw}
proxy-groups:
  - {name: "Панель", type: select, proxies: ["Быстрый", "🇳🇱 Amsterdam", "🇫🇮 Helsinki"]}
  - {name: "Быстрый", type: url-test, proxies: ["🇳🇱 Amsterdam", "🇫🇮 Helsinki"], url: "https://x/generate_204", interval: 300}
rules:
  - GEOSITE,category-ru,DIRECT
  - MATCH,Панель
"""

private func load(_ yaml: String) -> [String: Any] {
    (try? Yams.load(yaml: yaml) as? [String: Any]) ?? [:]
}

func configTests() {
    Check.suite("MihomoConfig · routing mode") {
        for mode in RoutingMode.allCases {
            var override = overrides()
            override.routingMode = mode
            let root = load(try! MihomoConfig.build(panelYAML: panelYAML, overrides: override))
            Check.equal(root["mode"] as? String, mode.rawValue,
                        "\(mode) is the mode the core starts in, whatever the panel wrote")
        }
    }

    Check.suite("MihomoConfig · server descriptions") {
        let described = """
        proxies:
          - {name: "🇸🇪 Sweden", type: ss, server: 1.2.3.4, port: 443, cipher: aes-256-gcm, password: pw, serverDescription: "Для онлайн игр 🎮"}
          - {name: "🇫🇮 Helsinki", type: ss, server: 1.2.3.5, port: 443, cipher: aes-256-gcm, password: pw}
          - {name: "🇺🇸 United States", type: ss, server: 1.2.3.6, port: 443, cipher: aes-256-gcm, password: pw, serverDescription: "  "}
        """
        Check.equal(MihomoConfig.serverDescriptions(panelYAML: described),
                    ["🇸🇪 Sweden": "Для онлайн игр 🎮"],
                    "each described server, by name; blank ones are left out")
        Check.equal(MihomoConfig.serverDescriptions(panelYAML: panelYAML), [:],
                    "a panel that sends none gives none")

        // A group can be a row too — a balancer the service built and named.
        let grouped = """
        proxies:
          - {name: "🇳🇱 Netherlands LTE 1", type: ss, server: 1.2.3.4, port: 443, cipher: aes-256-gcm, password: pw}
        proxy-groups:
          - {name: "🇵🇱 Poland LTE 1", type: load-balance, proxies: ["🇳🇱 Netherlands LTE 1"], description: "Доступность во время БС 🌟"}
          - {name: "Панель", type: select, proxies: ["🇵🇱 Poland LTE 1"]}
        """
        Check.equal(MihomoConfig.serverDescriptions(panelYAML: grouped),
                    ["🇵🇱 Poland LTE 1": "Доступность во время БС 🌟"],
                    "a group's description is read as well")
    }

    Check.suite("MihomoConfig · client-owned settings") {
        let built = try! MihomoConfig.build(panelYAML: panelYAML, overrides: overrides())
        let root = load(built)

        Check.equal(root["external-controller"] as? String, "127.0.0.1:9797",
                    "the controller is bound to loopback, not the panel's 0.0.0.0")
        Check.equal(root["secret"] as? String, "s3cret", "the client's own API secret wins")
        Check.equal(root["mixed-port"] as? Int, 7897, "mixed port")
        Check.equal(root["allow-lan"] as? Bool, false,
                    "allow-lan is forced off — an unbound listener is an open proxy")
        Check.equal(root["bind-address"] as? String, "127.0.0.1", "bound to loopback")
        // Both the split rules and the connections screen need the core to know
        // which process opened a connection.
        Check.equal(root["find-process-mode"] as? String, "always",
                    "process lookup is always on")
        Check.equal(root["mode"] as? String, "rule",
                    "the panel's global mode would ignore its own routing rules")
        // One mixed port is the whole surface this client needs.
        Check.isNil(root["port"], "the panel's http port is removed")
        Check.isNil(root["socks-port"], "the panel's socks port is removed")

        // The panel's own content is kept verbatim.
        Check.equal((root["proxies"] as? [[String: Any]])?.count, 2, "proxies are kept")
        Check.equal((root["proxy-groups"] as? [[String: Any]])?.count, 2, "the panel's groups are kept")
        Check.equal((root["rules"] as? [String])?.count, 2, "the panel's rules are kept")
        Check.equal((root["dns"] as? [String: Any])?["nameserver"] as? [String], ["223.5.5.5"],
                    "the panel's DNS is left alone in proxy mode")
        Check.isNil(root["tun"], "no tun block in system-proxy mode")
    }

    Check.suite("MihomoConfig · selector discovery") {
        // A panel names its groups whatever it likes, so the group is found the
        // way the config points at it, not by matching a name.
        let groups: [[String: Any]] = [
            ["name": "Быстрый", "type": "url-test"],
            ["name": "Панель", "type": "select"],
        ]
        Check.equal(
            MihomoConfig.primarySelectorName(groups: groups, rules: ["GEOSITE,x,DIRECT", "MATCH,Панель"]),
            "Панель", "the MATCH target is the primary selector"
        )
        Check.equal(
            MihomoConfig.primarySelectorName(groups: groups, rules: ["MATCH,DIRECT"]),
            "Панель", "a MATCH that names no group falls back to the first select"
        )
        Check.equal(
            MihomoConfig.primarySelectorName(groups: [], rules: []),
            MihomoConfig.defaultSelector, "with nothing to go on, the injected selector"
        )
    }

    Check.suite("MihomoConfig · probe target") {
        Check.equal(MihomoAPI.probeURL, "http://cp.cloudflare.com/generate_204",
                    "the probe target is Cloudflare's captive-portal endpoint")
        // http, not https: a TLS handshake to the *target* adds a round trip
        // that says nothing about the path to the node.
        Check.isTrue(MihomoAPI.probeURL.hasPrefix("http://"),
                     "the probe does not pay for TLS to the target")

        let bare = MihomoConfig.yamlFromProxies([
            ["name": "A", "type": "ss", "server": "1.2.3.4", "port": 443,
             "cipher": "aes-256-gcm", "password": "pw"],
        ])
        let auto = MihomoConfig.defaultGroups(proxyNames: ["A"])
            .first { $0["name"] as? String == MihomoConfig.defaultAutoGroup }
        Check.equal(auto?["url"] as? String, MihomoAPI.probeURL,
                    "the injected url-test group measures against the same target")
        Check.isTrue(bare.contains("cp.cloudflare.com"),
                     "and it survives into the generated YAML")
    }

    Check.suite("MihomoConfig · groupless config") {
        // The share-link fallback produces a bare proxy list.
        let bare = MihomoConfig.yamlFromProxies([
            ["name": "A", "type": "ss", "server": "1.2.3.4", "port": 443,
             "cipher": "aes-256-gcm", "password": "pw"],
        ])
        let built = try! MihomoConfig.build(panelYAML: bare, overrides: overrides())
        let root = load(built)
        let names = (root["proxy-groups"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        Check.equal(names?.contains(MihomoConfig.defaultSelector), true, "a selector is injected")
        Check.equal(names?.contains(MihomoConfig.defaultAutoGroup), true, "a url-test group is injected")
        Check.equal((root["rules"] as? [String])?.last, "MATCH,\(MihomoConfig.defaultSelector)",
                    "a catch-all rule is injected")
    }

    Check.suite("MihomoConfig · TUN") {
        let built = try! MihomoConfig.build(panelYAML: panelYAML, overrides: overrides(mode: .tun))
        let root = load(built)
        let tun = root["tun"] as? [String: Any]
        Check.equal(tun?["enable"] as? Bool, true, "tun enabled")
        // No device name: a hardcoded utun index collides with whichever VPN
        // client already holds it, so the core picks the first free one.
        Check.isNil(tun?["device"], "the core chooses the interface name")
        Check.equal(tun?["stack"] as? String, "mixed", "mixed stack")
        Check.equal(tun?["auto-route"] as? Bool, true, "auto-route")
        Check.notNil(tun?["dns-hijack"], "dns-hijack is set")

        let dns = root["dns"] as? [String: Any]
        // Without this, mihomo does not answer the queries dns-hijack redirects
        // to it and the tunnel resolves nothing.
        Check.equal(dns?["enable"] as? Bool, true, "DNS is forced on for TUN")
        // The panel may point at a resolver inside the tunnel on purpose.
        Check.equal(dns?["nameserver"] as? [String], ["223.5.5.5"], "the panel's resolvers are kept")
    }

    Check.suite("MihomoConfig · sniffer") {
        // A browser on secure DNS reaches the core with bare addresses, and
        // without a sniffer no domain rule can match them.
        for mode in [TunnelMode.systemProxy, .tun] {
            let root = load(try! MihomoConfig.build(panelYAML: panelYAML, overrides: overrides(mode: mode)))
            let sniffer = root["sniffer"] as? [String: Any]
            Check.equal(sniffer?["enable"] as? Bool, true, "a panel with no sniffer gets the app's in \(mode)")
            Check.equal(sniffer?["parse-pure-ip"] as? Bool, true,
                        "a connection to a bare address is sniffed")
            Check.equal(sniffer?["override-destination"] as? Bool, true,
                        "and dialled by the name found, not the address the browser resolved")
            let sniff = sniffer?["sniff"] as? [String: Any]
            Check.equal((sniff?["TLS"] as? [String: Any])?["ports"] as? [String], ["443", "8443"],
                        "TLS is read on the HTTPS ports")
            Check.equal((sniff?["QUIC"] as? [String: Any])?["ports"] as? [String], ["443", "8443"],
                        "and so is QUIC, which a browser uses where a site offers it")
            Check.equal((sniff?["HTTP"] as? [String: Any])?["ports"] as? [String], ["80", "8080-8880"],
                        "a range survives as a string")
        }

        // One the panel switched on is its decision, kept as it wrote it.
        let tuned = panelYAML + """

        sniffer:
          enable: true
          override-destination: false
          sniff:
            TLS: {ports: [443]}
        """
        let kept = load(try! MihomoConfig.build(panelYAML: tuned, overrides: overrides()))["sniffer"] as? [String: Any]
        Check.equal(kept?["override-destination"] as? Bool, false, "a panel's own sniffer is kept")
        Check.isNil((kept?["sniff"] as? [String: Any])?["QUIC"], "and not merged with the app's")

        // One switched off — mihomo's sample config ships it so — is not a
        // reason to leave the rules blind.
        let off = panelYAML + """

        sniffer:
          enable: false
        """
        let replaced = load(try! MihomoConfig.build(panelYAML: off, overrides: overrides()))["sniffer"] as? [String: Any]
        Check.equal(replaced?["enable"] as? Bool, true, "a switched-off sniffer is replaced by the app's")
    }

    Check.suite("MihomoConfig · the panel's order") {
        let subscription = """
        proxies:
          - {name: "🇷🇺 Russia", type: ss, server: 10.0.0.1, port: 1, cipher: aes-256-gcm, password: pw}
          - {name: "🇪🇪 Estonia", type: ss, server: 10.0.0.2, port: 1, cipher: aes-256-gcm, password: pw}
          - {name: "🇩🇪 Germany", type: ss, server: 10.0.0.3, port: 1, cipher: aes-256-gcm, password: pw}
        """
        let order = MihomoConfig.proxyOrder(panelYAML: subscription)
        Check.equal(order, ["🇷🇺 Russia", "🇪🇪 Estonia", "🇩🇪 Germany"], "the servers, as the subscription lists them")
        // What the core reports for a group with `include-all`: its own
        // entries first, then every server sorted by name.
        Check.equal(MihomoConfig.inPanelOrder(["Auto", "🇩🇪 Germany", "🇪🇪 Estonia", "🇷🇺 Russia"], order: order),
                    ["Auto", "🇷🇺 Russia", "🇪🇪 Estonia", "🇩🇪 Germany"],
                    "servers go back into the subscription's order, the auto-picker stays first")
        Check.equal(MihomoConfig.inPanelOrder(["🇩🇪 Germany", "Balancer", "🇷🇺 Russia"], order: order),
                    ["🇷🇺 Russia", "Balancer", "🇩🇪 Germany"],
                    "a group between servers keeps its place")
        Check.equal(MihomoConfig.inPanelOrder(["DIRECT", "Elsewhere"], order: order), ["DIRECT", "Elsewhere"],
                    "names the subscription does not list are left alone")
    }

    Check.suite("MihomoConfig · stand-ins") {
        // What the panel sends when it has no server for this client: its
        // message as the names, pointing at nothing.
        let standIns = """
        proxies:
          - {name: "→ No hosts found", type: vless, server: 0.0.0.0, port: 1, uuid: 00000000-0000-0000-0000-000000000000}
          - {name: "→ Check Hosts tab", type: vless, server: 0.0.0.0, port: 1, uuid: 00000000-0000-0000-0000-000000000000}
        """
        Check.isTrue(!MihomoConfig.hasServers(panelYAML: standIns), "a list of stand-ins has no servers")
        Check.isTrue(MihomoConfig.hasServers(panelYAML: panelYAML), "a real subscription has")
        Check.isTrue(MihomoConfig.isStandIn(["server": "1.2.3.4", "uuid": "00000000-0000-0000-0000-000000000000"]),
                     "the all-zero id alone gives one away")
        Check.isTrue(!MihomoConfig.isStandIn(["server": "127.0.0.1", "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811"]),
                     "a server on loopback is still a server")
        Check.isTrue(!MihomoConfig.hasServers(panelYAML: "proxies: []"), "nor does an empty list")
    }

    Check.suite("MihomoConfig · failure modes") {
        var threw = false
        do { _ = try MihomoConfig.build(panelYAML: "just a string", overrides: overrides()) }
        catch { threw = true }
        Check.isTrue(threw, "a non-mapping document is rejected")

        threw = false
        do { _ = try MihomoConfig.build(panelYAML: "rules: [MATCH,DIRECT]", overrides: overrides()) }
        catch { threw = true }
        Check.isTrue(threw, "a config with no proxies is rejected")
    }
}
