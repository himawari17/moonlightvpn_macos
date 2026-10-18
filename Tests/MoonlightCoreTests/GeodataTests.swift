import Foundation
import MoonlightCore

/// Seeding decides whether a first launch needs the network, and whether an
/// update tramples data the core fetched for itself. Neither shows when it is
/// wrong: the first only where the download is blocked, the second never.
///
/// These are the file moves alone, on stand-in files. That the real databases
/// are what the core wants is for `coreIntegrationTests` to say.
func geodataTests() {
    let manager = FileManager.default
    let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("moonlight-geodata-\(UUID().uuidString)")
    let bundled = workspace.appendingPathComponent("bundled", isDirectory: true)
    try? manager.createDirectory(at: bundled, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: workspace) }

    func write(_ text: String, _ url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
    for name in Geodata.fileNames {
        write("bundled \(name)", bundled.appendingPathComponent(name))
    }

    Check.suite("Geodata · seeding the core's home") {
        // Not created first: the home may not exist before the core's first run.
        let home = workspace.appendingPathComponent("core", isDirectory: true)
        Check.equal(Geodata.seed(home: home, from: bundled), Geodata.fileNames,
                    "an empty home gets every bundled file")
        for name in Geodata.fileNames {
            Check.equal(read(home.appendingPathComponent(name)), "bundled \(name)",
                        "\(name) arrives whole")
        }
        Check.equal(Geodata.seed(home: home, from: bundled), [],
                    "a home that has them is left alone")

        // One the core fetched for itself, and one gone missing.
        let own = home.appendingPathComponent("geoip.metadb")
        write("the core's own", own)
        try manager.removeItem(at: home.appendingPathComponent("GeoSite.dat"))
        Check.equal(Geodata.seed(home: home, from: bundled), ["GeoSite.dat"],
                    "only the missing file is copied")
        Check.equal(read(own), "the core's own",
                    "a file the core downloaded is never replaced")
        Check.equal(try manager.contentsOfDirectory(atPath: home.path).sorted(),
                    Geodata.fileNames.sorted(),
                    "nothing is left behind beside them")
    }

    Check.suite("Geodata · a download the network blocked") {
        Check.equal(Geodata.blockedDownload(
            in: #"msg="can't initial ASN: can't download ASN.mmdb: Get "http://127.0.0.1:9/asn.mmdb": refused""#),
                    "ASN.mmdb", "the database is named from the core's own line")
        Check.equal(Geodata.blockedDownload(in: "can't download GeoSite.dat: EOF"), "GeoSite.dat",
                    "whichever one it was")
        Check.isNil(Geodata.blockedDownload(in: "configuration file test failed"),
                    "a failure that is not a download names none")
        Check.isNil(Geodata.blockedDownload(in: "can't download "), "nor does a line cut short")
        // The one kind whose database the app does not ship, and so the one
        // the rule editor warns about.
        Check.equal(RoutingRule.Kind.allCases.filter(\.needsDownload), [.ipASN],
                    "only IP-ASN has the core download a database")
        Check.isTrue(!Geodata.fileNames.contains(Geodata.asnFileName), "which is not among the shipped ones")
    }

    Check.suite("Geodata · what counts as there") {
        let home = workspace.appendingPathComponent("lowercase", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        write("someone's own", home.appendingPathComponent("geosite.dat"))
        Check.equal(Geodata.seed(home: home, from: bundled), ["geoip.metadb"],
                    "a file under another case of the name is the home's own")
        Check.equal(read(home.appendingPathComponent("geosite.dat")), "someone's own",
                    "and is not replaced")

        // A checkout that never ran scripts/fetch-geodata.sh.
        let bare = workspace.appendingPathComponent("bare", isDirectory: true)
        Check.equal(Geodata.seed(home: bare, from: workspace.appendingPathComponent("absent")), [],
                    "a build without the files seeds nothing")
        Check.equal(Geodata.seed(home: bare, from: nil), [], "nor does one with nowhere to look")
        Check.isTrue(!manager.fileExists(atPath: bare.path),
                     "and does not make a home it has nothing to put in")
    }
}
