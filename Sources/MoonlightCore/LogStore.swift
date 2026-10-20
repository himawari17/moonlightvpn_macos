import Foundation
import Combine

/// One line in the log viewer.
public struct LogEntry: Identifiable, Hashable, Sendable {
    public enum Level: String, CaseIterable, Sendable {
        case debug, info, warning, error

        /// mihomo writes `warning`; most UIs and its own docs say `warn`.
        public init(core raw: String) {
            switch raw.lowercased() {
            case "debug": self = .debug
            case "warn", "warning": self = .warning
            case "err", "error": self = .error
            default: self = .info
            }
        }

        /// Warnings and errors — what explains a failure after the fact, and
        /// so what the log keeps longest.
        public var isProblem: Bool { self == .warning || self == .error }

        /// How long a line at this level stays in the log: two hours for the
        /// running account of debug and info, ten for warnings and errors.
        public var kept: TimeInterval { isProblem ? 10 * 3600 : 2 * 3600 }
    }

    public enum Source: String, CaseIterable, Sendable {
        /// The app's own steps — connecting, refreshing, applying settings.
        case client
        /// mihomo's log stream.
        case core
    }

    public let id = UUID()
    public let at: Date
    public let level: Level
    public let source: Source
    public let message: String

    public init(at: Date = Date(), level: Level, source: Source, message: String) {
        self.at = at
        self.level = level
        self.source = source
        self.message = message
    }
}

/// The log the viewer reads.
///
/// Bounded twice. By age — see ``LogEntry/Level/kept`` — so the log is the
/// last hours rather than everything since launch. And by count, since a core
/// at info level writes a line per connection and two hours of a browser is a
/// great many of them; the cap is on entries rather than bytes because that is
/// what the list has to render. Warnings and errors have a cap of their own:
/// under one shared cap, an evening of connection lines pushed out the one
/// error that said why the tunnel had dropped.
@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []

    private let routineLimit: Int
    private let problemLimit: Int
    /// When lines were last dropped for their age. That needs a pass over the
    /// whole log, so it runs once a minute rather than with every line.
    private var lastPrune = Date.distantPast
    private var coreStream: Task<Void, Never>?
    /// The core being followed, so the stream can be reopened at another level.
    private var followed: MihomoAPI?
    /// Whether the core's `info` lines are wanted — see ``setDetailed(_:)``.
    private var detailed = false
    /// Longest first, so a link is masked whole before its host is.
    private var redactions: [String] = []

    public init(routineLimit: Int = 3_000, problemLimit: Int = 1_000) {
        self.routineLimit = routineLimit
        self.problemLimit = problemLimit
    }

    /// Strings that must never reach the screen — the subscription link, its
    /// host and token, server addresses. Masked in every entry, including the
    /// ones already kept, since they may predate the list.
    public func setRedactions(_ secrets: [String]) {
        let cleaned = Set(secrets.map { $0.trimmingCharacters(in: .whitespaces) })
            .filter { $0.count >= 4 }
            .sorted { $0.count > $1.count }
        guard cleaned != redactions else { return }
        redactions = cleaned
        entries = entries.map { entry in
            let masked = redact(entry.message)
            return masked == entry.message ? entry
                : LogEntry(at: entry.at, level: entry.level, source: entry.source, message: masked)
        }
    }

    private func redact(_ message: String) -> String {
        redactions.reduce(message) { text, secret in
            text.replacingOccurrences(of: secret, with: "•••", options: .caseInsensitive)
        }
    }

    public func append(_ level: LogEntry.Level, _ source: LogEntry.Source, _ message: String,
                       at date: Date = Date()) {
        entries.append(LogEntry(at: date, level: level, source: source, message: redact(message)))
        trim(now: date)
    }

    /// Several of the core's lines at once: one change to the list, and so one
    /// redraw of whatever is showing it, however many arrived together.
    private func append(core lines: [MihomoAPI.LogLine], at date: Date = Date()) {
        let kept = lines.filter { !Self.isShutdownNoise($0.payload) }
        guard !kept.isEmpty else { return }
        entries.append(contentsOf: kept.map {
            LogEntry(at: date, level: LogEntry.Level(core: $0.type), source: .core,
                     message: redact($0.payload))
        })
        trim(now: date)
    }

    /// The core's TUN reader saying its device was closed under it — which is
    /// what stopping a TUN core does, on every disconnect, every switch to the
    /// system proxy and every reload under TUN. It arrived as an ERROR line
    /// ("batch read packet: bad file descriptor") each time, and read as a
    /// fault when it is the shutdown working.
    nonisolated public static func isShutdownNoise(_ payload: String) -> Bool {
        let text = payload.lowercased()
        guard text.contains("read packet") else { return false }
        return text.contains("bad file descriptor") || text.contains("file already closed")
            || text.contains("use of closed file")
    }

    /// Drops lines past their age — see ``LogEntry/Level/kept``. Run on its
    /// own as well as with new lines, so a log nobody wrote to for an hour is
    /// still the right age when it is opened.
    public func prune(now: Date = Date()) {
        trim(now: now, force: true)
    }

    /// Keeps the log inside its age and its two caps.
    private func trim(now: Date, force: Bool = false) {
        let due = force || now.timeIntervalSince(lastPrune) >= 60
        let problems = entries.lazy.filter(\.level.isProblem).count
        var routineExcess = entries.count - problems - routineLimit
        var problemExcess = problems - problemLimit
        guard due || routineExcess > 0 || problemExcess > 0 else { return }
        if due { lastPrune = now }
        // Oldest first, so the lines a cap drops are the oldest of their kind.
        entries.removeAll { entry in
            let problem = entry.level.isProblem
            let stale = due && now.timeIntervalSince(entry.at) > entry.level.kept
            guard stale || (problem ? problemExcess : routineExcess) > 0 else { return false }
            if problem { problemExcess -= 1 } else { routineExcess -= 1 }
            return true
        }
    }

    /// `entries` as text, one line each, for the clipboard — already redacted,
    /// like everything the log holds.
    nonisolated public static func text(of entries: [LogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { entry in
            let level = entry.level == .warning ? "WARN" : entry.level.rawValue.uppercased()
            return "\(formatter.string(from: entry.at))  \(level)  "
                + "\(entry.source.rawValue.uppercased())  \(entry.message)"
        }.joined(separator: "\n")
    }

    /// The app's own narration of what it is doing, which is the half of the log
    /// that explains *why* the core did something.
    public func client(_ message: String, level: LogEntry.Level = .info) {
        append(level, .client, message)
    }

    public func clear() { entries.removeAll() }

    /// Follows the core's own log stream.
    ///
    /// Restartable: the stream dies with the core, and the core is swapped when
    /// the tunnel moves between system-proxy and TUN.
    public func followCore(_ api: MihomoAPI) {
        followed = api
        openStream()
    }

    public func stopFollowingCore() {
        followed = nil
        coreStream?.cancel()
        coreStream = nil
    }

    /// Whether to take the core's `info` lines as well as its warnings.
    ///
    /// At `info` the core writes a line for every connection it opens — dozens
    /// a second under a browser — and each one used to be parsed, redacted and
    /// published on the main thread for the whole time the tunnel was up,
    /// whether or not anyone had the log open. Warnings and errors are what
    /// explain a failure after the fact, so those are always kept; the
    /// per-connection lines are taken only while the log is on screen.
    public func setDetailed(_ detailed: Bool) {
        guard detailed != self.detailed else { return }
        self.detailed = detailed
        if followed != nil { openStream() }
    }

    private func openStream() {
        coreStream?.cancel()
        guard let api = followed else { return }
        let level = detailed ? "info" : "warning"
        let pending = PendingLines()
        coreStream = Task { [weak self] in
            for await line in api.logStream(level: level) {
                guard !Task.isCancelled else { break }
                // The first line of a burst schedules one delivery for all of
                // it, a quarter of a second on.
                guard pending.add(line) else { continue }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self?.append(core: pending.drain())
                }
            }
        }
    }
}

/// The core's lines between one delivery to the log and the next.
private final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [MihomoAPI.LogLine] = []

    /// Whether this is the first line since the last ``drain()``.
    func add(_ line: MihomoAPI.LogLine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        return lines.count == 1
    }

    func drain() -> [MihomoAPI.LogLine] {
        lock.lock(); defer { lock.unlock() }
        defer { lines = [] }
        return lines
    }
}
