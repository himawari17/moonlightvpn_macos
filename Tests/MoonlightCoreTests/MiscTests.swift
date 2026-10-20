import Foundation
import MoonlightCore

func tunFailureTests() {
    Check.suite("TUN failure detection") {
        let conflict = """
        time="..." level=info msg="Initial configuration complete, total time: 2994ms"
        time="..." level=warning msg="[TUN] default interface changed by monitor, => en0"
        time="..." level=error msg="Start TUN listening error: configure tun interface: add route: 1.0.0.0/8: file exists"
        """
        let reason = MihomoProcess.tunFailure(in: conflict)
        Check.notNil(reason, "a route conflict is detected")
        Check.isTrue(reason?.contains("Another VPN") == true,
                     "a route conflict names the cause rather than quoting the core")

        let other = #"""
        time="..." level=error msg="Start TUN listening error: operation not permitted"
        """#
        Check.equal(MihomoProcess.tunFailure(in: other), "operation not permitted",
                    "any other reason is passed through as the core stated it")

        let healthy = """
        time="..." level=info msg="Initial configuration complete, total time: 120ms"
        time="..." level=info msg="[TUN] Tun adapter listening at: utun5"
        """
        Check.isNil(MihomoProcess.tunFailure(in: healthy), "a healthy start reports nothing")
        Check.isNil(MihomoProcess.tunFailure(in: ""), "an empty log reports nothing")
    }
}

/// The server list is the panel's own list, so a row has to read the way the
/// panel writes it — flag, country, transport — whether the entry is a node or
/// one of the operator's balancer groups.
func nodePresentationTests() {
    Check.suite("Node · flag and country") {
        let sweden = Node(name: "🇸🇪 Sweden", type: "Vless", protocolLabel: "VLESS Reality")
        Check.equal(sweden.flag, "🇸🇪", "the flag is split off the name")
        Check.equal(sweden.title, "Sweden", "the title has the flag removed")
        // The ISO code falls out of the regional indicators, so Foundation can
        // localise the name and there is no table to keep up to date.
        Check.equal(sweden.country(.ru), "Швеция", "the country is localised from the flag")
        Check.equal(sweden.country(.en), "Sweden", "…in either language")
        Check.equal(sweden.subtitle(.ru), "Швеция · VLESS Reality", "the row's second line")

        // A balancer named for a country is that country to the user.
        let balancer = Node(name: "🇩🇪 Russia -> Germany ⚡️", type: "LoadBalance",
                            isGroup: true, protocolLabel: "VLESS Reality")
        Check.equal(balancer.flag, "🇩🇪", "a group keeps the flag its name carries")
        Check.equal(balancer.title, "Russia -> Germany ⚡️", "and its full name")
        Check.equal(balancer.subtitle(.ru), "Германия · VLESS Reality",
                    "a group reads exactly like a node")

        // An auto-picker spans several places, so it claims none.
        let auto = Node(name: "Auto ⚡", type: "URLTest", isGroup: true,
                        protocolLabel: "VLESS Reality")
        Check.isNil(auto.flag, "no flag is invented for a cross-country group")
        Check.isNil(auto.country(.ru), "and no country either")
        Check.equal(auto.subtitle(.ru), "VLESS Reality", "it shows just its transport")

        let bare = Node(name: "Node", type: "Vless")
        Check.equal(bare.subtitle(.ru), "", "nothing known means nothing shown")
    }
}

/// A panel that ships its own `url-test` group is offering the same thing the
/// app's "Авто" row does. Showing both gave two rows for one job.
func autoPickerTests() {
    Check.suite("Node · auto-picker") {
        Check.isTrue(Node(name: "Auto ⚡", type: "URLTest", isGroup: true).isAutoPicker,
                     "a url-test group picks by latency")
        Check.isTrue(Node(name: "Backup", type: "Fallback", isGroup: true).isAutoPicker,
                     "so does a fallback group")
        // A balancer spreads load across a country; it is a place, not a picker.
        Check.isTrue(!Node(name: "🇩🇪 Russia -> Germany ⚡️", type: "LoadBalance",
                           isGroup: true).isAutoPicker,
                     "a load-balance group is a place, not a picker")
        Check.isTrue(!Node(name: "🇸🇪 Sweden", type: "Vless").isAutoPicker,
                     "a plain node is not a picker")
        // Type alone is not enough: the entry has to be a group.
        Check.isTrue(!Node(name: "x", type: "URLTest", isGroup: false).isAutoPicker,
                     "the entry has to be a group")
    }
}

/// Version comparison decides whether the app offers to replace itself, so the
/// case a string comparison gets backwards is worth pinning.
func updaterTests() {
    Check.suite("Updater · version ordering") {
        Check.isTrue(Updater.isNewer("1.0.9", than: "1.0.8"), "a later patch is newer")
        // "1.0.10" < "1.0.9" as strings; numerically it is not.
        Check.isTrue(Updater.isNewer("1.0.10", than: "1.0.9"), "ten beats nine")
        Check.isTrue(Updater.isNewer("1.1.0", than: "1.0.99"), "a later minor beats any patch")
        Check.isTrue(Updater.isNewer("2.0", than: "1.9.9"), "a shorter version still compares")
        Check.isTrue(!Updater.isNewer("1.0.8", than: "1.0.8"), "the same version is not newer")
        Check.isTrue(!Updater.isNewer("1.0.7", than: "1.0.8"), "an older one is not newer")
        Check.isTrue(!Updater.isNewer("1.0", than: "1.0.0"), "trailing zeros are equal")
    }

    Check.suite("HelperInstaller · scripts") {
        let install = HelperInstaller.installScript(
            helper: URL(fileURLWithPath: "/tmp/moonlight-helper"),
            core: URL(fileURLWithPath: "/tmp/mihomo"),
            geodata: Geodata.fileNames.map { URL(fileURLWithPath: "/tmp/geodata/\($0)") }
        )
        // They run as root through osascript and cannot run here — but they can
        // at least be proved to parse.
        for (name, script) in [("install", install), ("uninstall", HelperInstaller.uninstallScript)] {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("moonlight-\(name)-\(UUID().uuidString).sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-n", file.path]
            try shell.run()
            shell.waitUntilExit()
            Check.equal(shell.terminationStatus, 0, "the \(name) script is valid shell")
        }
        // The old helper must be gone before its files are replaced or a new one
        // loaded: a bootstrap while launchd was still removing it failed with
        // "Bootstrap failed: 5".
        func position(_ text: String) -> Int {
            install.range(of: text).map { install.distance(from: install.startIndex, to: $0.lowerBound) } ?? -1
        }
        Check.isTrue(position("launchctl print") >= 0 && position("launchctl print") < position("cp -f"),
                     "install waits for the old helper to be gone before copying")
        Check.isTrue(!install.contains("cp -f '/tmp/mihomo' '/Library/Application Support/Moonlight/mihomo'"),
                     "the core is replaced by rename, never written into in place")
        Check.isTrue(position("launchctl bootstrap") > position("mv -f"),
                     "and loaded only once its files are in place")
        Check.isTrue(position("\(HelperInstaller.coreHome)/GeoSite.dat") > 0
                     && position("\(HelperInstaller.coreHome)/GeoSite.dat") < position("launchctl bootstrap"),
                     "the helper's core has its geodata before it can be started")
        Check.isTrue(position("chown -R root:wheel") > position("\(HelperInstaller.coreHome)/geoip.metadb"),
                     "and root owns it like everything else there")
    }

    // The one part of the install that can run here: it only copies, and the
    // home it copies into is a parameter. As root it is what stands between a
    // first TUN connect and the download the core would otherwise attempt.
    Check.suite("HelperInstaller · geodata for the helper's core") {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("moonlight-seed-\(UUID().uuidString)")
        let bundled = workspace.appendingPathComponent("bundled")
        let home = workspace.appendingPathComponent("run")
        try manager.createDirectory(at: bundled, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }
        for name in Geodata.fileNames {
            try "bundled \(name)".write(to: bundled.appendingPathComponent(name),
                                        atomically: true, encoding: .utf8)
        }

        func seed() throws -> Int32 {
            let script = "set -e\n" + HelperInstaller.seedScript(
                geodata: Geodata.files(in: bundled), home: home.path)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", script]
            try shell.run()
            shell.waitUntilExit()
            return shell.terminationStatus
        }
        func read(_ name: String) -> String? {
            try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
        }

        Check.equal(try seed(), 0, "the copy runs before the helper has made its core a home")
        Check.equal(Geodata.fileNames.map(read), Geodata.fileNames.map { "bundled \($0)" },
                    "and puts every bundled file in it")
        Check.equal(try manager.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int, 0o700,
                    "in a directory as closed as the helper would have made it")

        // The helper's core fetched its own since, and a later install —
        // every helper update is one — must not put the old data back.
        try "the core's own".write(to: home.appendingPathComponent("GeoSite.dat"),
                                   atomically: true, encoding: .utf8)
        try manager.removeItem(at: home.appendingPathComponent("geoip.metadb"))
        Check.equal(try seed(), 0, "a second install runs over the first")
        Check.equal(read("GeoSite.dat"), "the core's own", "a file the core downloaded is never replaced")
        Check.equal(read("geoip.metadb"), "bundled geoip.metadb", "a missing one is put back")
        Check.equal(try manager.contentsOfDirectory(atPath: home.path).sorted(),
                    Geodata.fileNames.sorted(), "nothing is left behind beside them")

        Check.equal(HelperInstaller.seedScript(geodata: [], home: home.path), "",
                    "a build without the files adds nothing to the install")
    }

    Check.suite("MihomoProcess · core version") {
        Check.equal(MihomoProcess.version(fromOutput: "Mihomo Meta v1.19.31 darwin arm64 with go1.26.8 Mon Sep 14 13:24:49 UTC 2026\nUse tags: with_gvisor\n"),
                    "1.19.31", "the version from `mihomo -v`")
        Check.equal(MihomoProcess.version(fromOutput: "Mihomo Meta alpha-1a2b3c darwin arm64"), nil,
                    "a build with no release number has none")
        Check.equal(MihomoProcess.version(fromOutput: ""), nil, "nor does nothing")
    }

    Check.suite("Updater · release checksum") {
        let hash = String(repeating: "ab", count: 32)
        // `shasum -a 256` output, which is what the release attaches.
        Check.equal(Updater.checksum(fromSHA256File: "\(hash)  Moonlight-universal.dmg\n"), hash,
                    "the hash is the first field of shasum's line")
        Check.equal(Updater.checksum(fromSHA256File: hash.uppercased()), hash,
                    "a bare upper-case hash is read too")
        Check.isNil(Updater.checksum(fromSHA256File: "Not Found"), "anything that is not a hash is refused")
        Check.isNil(Updater.checksum(fromSHA256File: ""), "and so is nothing")
    }

    Check.suite("Format · download progress") {
        Check.equal(Format.transfer(12_897_485, of: 38_405_734, locale: .ru), "12,3\u{00A0}МБ из 36,6\u{00A0}МБ",
                    "received and total, in the design's units")
        Check.equal(Format.transfer(12_897_485, of: 38_405_734, locale: .en), "12.3\u{00A0}MB of 36.6\u{00A0}MB",
                    "and in English")
        Check.equal(Format.transfer(12_897_485, of: nil, locale: .ru), "12,3\u{00A0}МБ",
                    "with no size from the server, just what has arrived")
    }

    Check.suite("LogEntry · core levels") {
        // mihomo writes `warning`; its own docs and most UIs say `warn`.
        Check.equal(LogEntry.Level(core: "warn"), .warning, "warn maps to warning")
        Check.equal(LogEntry.Level(core: "warning"), .warning, "and so does warning")
        Check.equal(LogEntry.Level(core: "err"), .error, "err maps to error")
        Check.equal(LogEntry.Level(core: "ERROR"), .error, "case does not matter")
        Check.equal(LogEntry.Level(core: "debug"), .debug, "debug")
        Check.equal(LogEntry.Level(core: "something else"), .info, "anything unknown is info")
    }
}

@MainActor
func logStoreTests() {
    Check.suite("LogStore · how long lines are kept") {
        let store = LogStore()
        let now = Date()
        store.append(.info, .client, "info, three hours old", at: now.addingTimeInterval(-3 * 3600))
        store.append(.error, .core, "error, three hours old", at: now.addingTimeInterval(-3 * 3600))
        store.append(.debug, .core, "debug, two and a half hours old", at: now.addingTimeInterval(-2.5 * 3600))
        store.append(.warning, .client, "warning, eleven hours old", at: now.addingTimeInterval(-11 * 3600))
        store.append(.info, .client, "info, an hour old", at: now.addingTimeInterval(-3600))
        store.prune(now: now)
        Check.equal(store.entries.map(\.message), ["error, three hours old", "info, an hour old"],
                    "debug and info for two hours, warnings and errors for ten")
    }

    Check.suite("LogStore · caps") {
        let store = LogStore(routineLimit: 3, problemLimit: 2)
        store.client("why it dropped", level: .error)
        for index in 1...10 { store.client("connection \(index)") }
        Check.equal(store.entries.map(\.message),
                    ["why it dropped", "connection 8", "connection 9", "connection 10"],
                    "a burst of info lines does not push out an error")
        for index in 1...3 { store.client("warning \(index)", level: .warning) }
        Check.equal(store.entries.filter(\.level.isProblem).map(\.message), ["warning 2", "warning 3"],
                    "and problems keep to a cap of their own")
    }

    Check.suite("LogStore · shutdown noise") {
        Check.isTrue(LogStore.isShutdownNoise("batch read packet: bad file descriptor"),
                     "the TUN reader finding its device closed is not logged")
        Check.isTrue(LogStore.isShutdownNoise("read packet: file already closed"), "in either wording")
        Check.isTrue(!LogStore.isShutdownNoise("dial tcp 1.2.3.4:443: bad file descriptor"),
                     "the same errno elsewhere still is")
        Check.isTrue(!LogStore.isShutdownNoise("[TCP] dial Панель error: read packet timeout"),
                     "and so is a read that failed for another reason")
    }

    Check.suite("LogStore · as text") {
        let entries = [
            LogEntry(level: .warning, source: .core, message: "first"),
            LogEntry(level: .info, source: .client, message: "second"),
        ]
        let lines = LogStore.text(of: entries).components(separatedBy: "\n")
        Check.equal(lines.count, 2, "one line per entry")
        Check.isTrue(lines[0].hasSuffix("  WARN  CORE  first"), "level, source and message, as on screen")
        Check.isTrue(lines[1].hasSuffix("  INFO  CLIENT  second"), "for every level")
        Check.isTrue(lines[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil,
                     "with the date, since a log is kept for hours")
    }
}
