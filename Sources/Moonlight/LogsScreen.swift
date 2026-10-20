import SwiftUI
import AppKit
import MoonlightDesign
import MoonlightCore

/// The log viewer.
///
/// Two sources on one timeline, and that pairing is the point: the core says
/// what happened to a connection, the client says what the app asked for. Read
/// apart, a failed connect is a core error with no cause; together it is "the
/// app switched to TUN, then the core could not take the route".
struct LogsScreen: View {
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var logs: LogStore
    @EnvironmentObject var activity: AppActivity
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    @Binding var page: Page

    @State private var source: LogEntry.Source?
    @State private var minimumLevel: LogEntry.Level = .info
    @State private var query = ""
    /// Whether the list keeps to the newest line as lines arrive. Off once
    /// the reader scrolls up to look at something, on again once they
    /// scroll back down to the end.
    @State private var follow = true
    /// The copy button's tick, for the moment after it is pressed.
    @State private var copied: UUID?

    private var filtered: [LogEntry] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return logs.entries.filter { entry in
            if let source, entry.source != source { return false }
            guard Self.rank(entry.level) >= Self.rank(minimumLevel) else { return false }
            return text.isEmpty || entry.message.lowercased().contains(text)
        }
    }

    /// What the filters are set to, as one value to watch.
    private var filterKey: String {
        "\(source?.rawValue ?? "all")|\(minimumLevel.rawValue)|\(query)"
    }

    /// Levels are a floor, not a set: picking WARN means warnings *and* errors,
    /// which is what someone looking for a problem wants.
    private static func rank(_ level: LogEntry.Level) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            controls
            // Filtered once per redraw; the table used to run the filter over
            // the whole log four times for every line that arrived.
            table(filtered)
        }
        // The core's line-per-connection is asked for only while this page
        // is on screen — see `LogStore.setDetailed`. Its warnings and
        // errors, and the app's own lines, are kept all the time.
        .onAppear {
            logs.setDetailed(activity.windowVisible)
            logs.prune()
        }
        .onDisappear { logs.setDetailed(false) }
        .onChange(of: activity.windowVisible) { logs.setDetailed($0) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            SegmentedPill(
                selection: Binding(
                    get: { source ?? .client },
                    set: { source = $0 }
                ),
                options: [(LogEntry.Source.client, L.t(.logClient, locale)),
                          (LogEntry.Source.core, L.t(.logCore, locale))],
                height: 30
            )
            .frame(width: 190)
            .opacity(source == nil ? 0.55 : 1)

            Button {
                source = nil
            } label: {
                Text(L.t(.logAll, locale))
                    .font(.ml(12.5, .heavy))
                    .foregroundStyle(source == nil ? palette.textOnAccent : palette.textMuted)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .mlGlass(.capsule, tint: source == nil ? palette.accent : nil, fallback: source == nil ? palette.accent : palette.surface2)
            }
            .pressButton()

            ForEach(LogEntry.Level.allCases, id: \.self) { level in
                Button {
                    minimumLevel = level
                } label: {
                    Text(level.label)
                        .font(.mlMono(11, .semibold))
                        .foregroundStyle(minimumLevel == level ? level.tint(palette) : palette.textMuted)
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(minimumLevel == level
                                    ? level.tint(palette).opacity(0.16) : .clear)
                        .clipShape(Capsule())
                }
                .pressButton()
            }

            HStack(spacing: 8) {
                IconView(.search, size: 14).foregroundStyle(palette.textMuted)
                TextField(L.t(.searchApps, locale), text: $query)
                    .textFieldStyle(.plain)
                    .font(.ml(12.5))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .mlGlass(.capsule, fallback: palette.surface2)

            Button {
                copy(filtered)
            } label: {
                IconView(copied == nil ? .copy : .check, size: 15)
                    .foregroundStyle(copied == nil ? palette.textMuted : palette.stUpInk)
                    .frame(width: 30, height: 30)
                    .mlGlass(.circle, fallback: palette.surface2)
            }
            .pressIcon()
            .help(L.t(copied == nil ? .logCopy : .logCopied, locale))
            .accessibilityLabel(L.t(copied == nil ? .logCopy : .logCopied, locale))
            .animation(Motion.paint, value: copied)

            Button {
                logs.clear()
                follow = true
            } label: {
                IconView(.trash2, size: 15)
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 30, height: 30)
                    .mlGlass(.circle, fallback: palette.surface2)
            }
            .pressIcon()
        }
    }

    private func table(_ rows: [LogEntry]) -> some View {
        Panel(radius: Radii.card, padding: 0) {
            VStack(spacing: 0) {
                header
                palette.hairlineSoft.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { entry in
                                LogRow(entry: entry).id(entry.id)
                                    .contextMenu {
                                        Button(L.t(.logCopyLine, locale)) { copy([entry]) }
                                        Button(L.t(.logCopy, locale)) { copy(rows) }
                                    }
                            }
                        }
                        .background(ScrollFollower { atEnd in
                            if follow != atEnd { follow = atEnd }
                        })
                    }
                    .mlScrollIndicators(hidden: false)
                    .onChange(of: rows.last?.id) { last in
                        // Follow the tail, the way a terminal does, unless the
                        // reader has scrolled away to look at something.
                        guard follow, let last else { return }
                        withAnimation(Motion.standard) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                    // Opened at the newest line, not the oldest — and so is
                    // every new view of it a filter or a search makes.
                    .onAppear {
                        guard let last = rows.last?.id else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                    .onChange(of: filterKey) { _ in
                        follow = true
                        guard let last = rows.last?.id else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                if rows.isEmpty {
                    Text(L.t(.logEmpty, locale))
                        .font(.ml(TypeScale.meta))
                        .foregroundStyle(palette.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Puts `entries` on the clipboard as text. Dragging across the rows
    /// selects within one message at most, and the window takes a drag that
    /// starts anywhere else for moving itself — so the log could be read but
    /// not handed to anyone.
    private func copy(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogStore.text(of: entries), forType: .string)
        let shown = UUID()
        copied = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copied == shown { copied = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ColumnHeading(text: L.t(.logTime, locale), width: 76)
            ColumnHeading(text: L.t(.logLevel, locale), width: 62)
            ColumnHeading(text: L.t(.logSource, locale), width: 74)
            ColumnHeading(text: L.t(.logMessage, locale))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct LogRow: View {
    @Environment(\.palette) private var palette
    let entry: LogEntry

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(Self.clock.string(from: entry.at))
                .foregroundStyle(palette.textMuted)
                .frame(width: 76, alignment: .leading)
            Text(entry.level.label)
                .foregroundStyle(entry.level.tint(palette))
                .frame(width: 62, alignment: .leading)
            Text(entry.source.rawValue.uppercased())
                .foregroundStyle(palette.text2)
                .frame(width: 74, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.mlMono(11.5, .regular))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

/// Says whether the reader is at the end of the log, each time they scroll it.
///
/// Only their own scrolling counts: a gesture, the scroller, the wheel. The
/// list's own scroll to each new line moves the same view and must not read
/// as the reader leaving the end — or arriving there.
private struct ScrollFollower: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var wheel: Any?
        /// The last wheel event's place in line, so only the last of a run
        /// reads the position.
        private var turn = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            self.scrollView = scrollView
            let center = NotificationCenter.default
            // A gesture or the scroller — posted only for the reader's own
            // scrolling, never for a scroll made in code. Taking hold of the
            // list stops it following at once, or each new line would pull
            // the scroller out from under the hand; letting go settles it.
            observers.append(center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in self?.changed?(false) })
            observers.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in self?.report() })
            // A mouse wheel scrolls without either. Its scroll is animated,
            // so the position is read once the run of turns has landed; a
            // turn towards older lines is leaving the end before it shows.
            wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scrollView = self.scrollView, event.window === scrollView.window,
                      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
                else { return event }
                if event.scrollingDeltaY > 0 { self.changed?(false) }
                self.turn += 1
                let turn = self.turn
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.turn == turn else { return }
                    self.report()
                }
                return event
            }
        }

        private func report() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.documentVisibleRect
            let slack: CGFloat = 16
            let atEnd = document.isFlipped
                ? visible.maxY >= document.bounds.maxY - slack
                : visible.minY <= document.bounds.minY + slack
            changed?(atEnd)
        }

        private func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let wheel { NSEvent.removeMonitor(wheel) }
            wheel = nil
        }

        deinit { stop() }
    }
}

extension LogEntry.Level {
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    func tint(_ palette: Palette) -> Color {
        switch self {
        case .debug: return palette.textMuted
        case .info: return palette.stUpInk
        case .warning: return palette.stDegradedInk
        case .error: return palette.stDownInk
        }
    }
}
