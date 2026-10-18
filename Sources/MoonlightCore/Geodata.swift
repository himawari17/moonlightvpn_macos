import Foundation

/// The geo databases mihomo reads for `GEOSITE` and `GEOIP` rules.
///
/// The core downloads them into its home the first time a config has such a
/// rule, and every subscription's does. It needs them to *parse* the config, so
/// that download comes before any tunnel exists. Where it is blocked — which is
/// where someone needs the tunnel — `mihomo -t` and the core itself wait about
/// 75 seconds and exit with "can't download GeoSite.dat", and the tunnel can
/// never start, because it is what would have made the download possible.
///
/// So the app ships them (`scripts/fetch-geodata.sh`) and puts them in the
/// core's home itself, before the core looks.
public enum Geodata {

    /// What mihomo 1.19.31 opens in its home with the default `geodata-mode`:
    /// `GeoSite.dat` for GEOSITE and `geoip.metadb` for GEOIP, found by
    /// running the core on an empty home. Check again when the core moves — a
    /// file it stops reading is megabytes shipped for nothing, and one it
    /// starts reading is the download back.
    public static let fileNames = ["GeoSite.dat", "geoip.metadb"]

    /// What the core opens for IP-ASN rules, and downloads the first time a
    /// config has one. Not shipped: it is MaxMind's GeoLite2 ASN database as
    /// MaxMind publishes it, whose licence has every copy replaced within 30
    /// days of an update and binds whoever is handed one to the same — and a
    /// file in the core's home is never replaced. So the core fetches it, and
    /// the rule editor says so before anyone adds such a rule.
    public static let asnFileName = "ASN.mmdb"

    /// The database the core could not download, read from its own output —
    /// `can't download ASN.mmdb: Get "…": …`. Nil when it says no such thing.
    ///
    /// A config that needs one does not load without it, and the core says only
    /// that it exited; this is what tells a blocked download apart from a
    /// config it refused.
    public static func blockedDownload(in output: String) -> String? {
        guard let range = output.range(of: "can't download ") else { return nil }
        let name = output[range.upperBound...].prefix { !$0.isWhitespace && $0 != ":" }
        return name.isEmpty ? nil : String(name)
    }

    /// The bundled files that are there. A build run from a checkout that
    /// never fetched them has none, and its core downloads as it always did.
    public static func files(in directory: URL?) -> [URL] {
        guard let directory else { return [] }
        return fileNames
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Copies the bundled files into the core's `home`, each only where the
    /// home has none. Returns the names it copied.
    ///
    /// A file already there is never replaced: the core downloaded it, or
    /// keeps it fresh under the config's `geo-auto-update`, and either way it
    /// is newer than what this build carries.
    @discardableResult
    public static func seed(home: URL, from directory: URL?) -> [String] {
        let bundled = files(in: directory)
        guard !bundled.isEmpty else { return [] }

        let manager = FileManager.default
        try? manager.createDirectory(at: home, withIntermediateDirectories: true)
        // Names are compared without regard to case: on a case-sensitive
        // volume a `geosite.dat` someone put there is still the home's own.
        let present = Set(((try? manager.contentsOfDirectory(atPath: home.path)) ?? [])
            .map { $0.lowercased() })

        var seeded: [String] = []
        for source in bundled {
            let name = source.lastPathComponent
            guard !present.contains(name.lowercased()) else { continue }
            // Copied beside its place and renamed into it, so a core starting
            // meanwhile never opens half a database — and `moveItem` refuses
            // to replace, so one the core put there in that moment stays.
            let partial = home.appendingPathComponent(".\(name).\(UUID().uuidString)")
            do {
                try manager.copyItem(at: source, to: partial)
                try manager.moveItem(at: partial, to: home.appendingPathComponent(name))
                seeded.append(name)
            } catch {
                try? manager.removeItem(at: partial)
            }
        }
        return seeded
    }
}
