import SwiftUI
import MoonlightDesign
import MoonlightCore

struct ConnectScreen: View {
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    @Binding var page: Page

    /// Whether the server drawer is open.
    @State private var serversOpen = false
    /// The drawer's natural height, measured, so it opens to exactly its
    /// content rather than to a guess.
    @State private var drawerContent: CGFloat = 0
    /// Everything above the server list — the time, the button, the state,
    /// the notes under it — and the list's heading and picker, measured.
    /// Neither changes when the drawer opens, so the page's offset can be
    /// worked out from them in the same animation as the drawer — measuring
    /// the whole column instead re-read it mid-spring, and the page jumped at
    /// the end of it.
    @State private var heroHeight: CGFloat = 0
    @State private var headHeight: CGFloat = 0
    /// What the last refresh started here came to, while it is on screen.
    @State private var toast: RefreshToast?

    /// One curve for everything the drawer moves — the page's offset, the
    /// list's height and fade, the chevron. A spring damped to just short of
    /// settling on its own: it eases in and lands without the overshoot that
    /// makes a bounce read as a toy.
    static let drawer = Motion.standard
    private static let pickerHeight: CGFloat = 60
    private static let drawerGap: CGFloat = 10
    /// The space between the notes under the button and the server list.
    private static let listGap: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            // The window's centre, in this page's coordinates. The page starts
            // under the title bar and ends above a margin, so its own centre
            // sits lower than the window's — and the eye centres on the window.
            let frame = geometry.frame(in: .global)
            let centre = (frame.minY + height + RootView.pageBottomInset) / 2 - frame.minY
            // How far down the column the server list starts.
            let listTop = heroHeight + Self.listGap
            VStack(spacing: 0) {
                hero
                    .background(measure(HeroHeightKey.self))
                    // Gone before it reaches the top edge on the way out; back
                    // as the column comes down on the way in.
                    .opacity(serversOpen ? 0 : 1)
                    .animation(serversOpen ? .easeOut(duration: 0.16) : Self.drawer.delay(0.08),
                               value: serversOpen)
                    .allowsHitTesting(!serversOpen)
                    .accessibilityHidden(serversOpen)
                serverList
                    .frame(maxWidth: 560)
                    .background(measure(HeadHeightKey.self))
                    .padding(.top, Self.listGap)
                if !tunnel.nodes.isEmpty {
                    drawer(room: height - headHeight - Self.drawerGap)
                        .frame(maxWidth: 560)
                        .padding(.top, Self.drawerGap)
                }
            }
            // Closed, the button is the page, and the column it heads — time,
            // button, state, servers — sits in the middle of the window, as
            // much space above as below. Centring the button alone left the
            // column hanging low under a band of empty space.
            //
            // Open, the list is the page: the column goes up until the list's
            // heading is at the top, and the list takes everything under it.
            // The button used to shrink and stay, and with the service's
            // message and a note under it that left room for two servers.
            .offset(y: serversOpen ? -listTop : Self.centredOffset(
                page: height, centre: centre, column: listTop + headHeight))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onPreferenceChange(HeroHeightKey.self) { settle($heroHeight, $0) }
        .onPreferenceChange(HeadHeightKey.self) { settle($headHeight, $0) }
        // Over the page rather than in it, so its arrival moves nothing; at
        // the foot, where it covers neither the time nor the button. The
        // curve is scoped to the note: on the page it would also have
        // animated whatever else changed as the refresh finished.
        .overlay(alignment: .bottom) {
            ZStack {
                if let toast {
                    ToastView(toast: toast) { self.toast = nil }
                        .frame(maxWidth: 460)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(Motion.standard, value: toast?.id)
        }
    }

    /// Refreshes the subscription and says how it went. Refreshing used to
    /// turn the glyph and stop, and whether anything had happened — or why
    /// not — was left to the timestamp on another page.
    private func refreshAndReport() async {
        guard !tunnel.isRefreshing else { return }
        let outcome = await tunnel.refresh()
        let shown = RefreshToast(outcome: outcome, issue: outcome == .failed ? tunnel.issue : nil)
        toast = shown
        // Long enough to read; a failure carries a reason, so it stays longer.
        try? await Task.sleep(nanoseconds: outcome == .failed ? 6_000_000_000 : 3_200_000_000)
        if toast?.id == shown.id { toast = nil }
    }

    /// Takes a new measurement. The first is applied as is — there is nothing
    /// on screen to move yet — and every later one on the one curve: a line
    /// appearing under the button (an error, the service's message) used to
    /// re-centre the page in a single frame, which read as the page jumping
    /// every time a connect started or a refresh finished.
    ///
    /// Through a binding, not `inout`. An `inout` state is written back when
    /// the call returns — after `withAnimation` has already closed — so the
    /// curve wrapped nothing and the page went on jumping: folding the
    /// announcement moved everything above it at once while the banner itself
    /// was still closing.
    private func settle(_ value: Binding<CGFloat>, _ measured: CGFloat) {
        guard abs(value.wrappedValue - measured) > 0.5 else { return }
        if value.wrappedValue == 0 {
            value.wrappedValue = measured
        } else {
            withAnimation(Motion.standard) { value.wrappedValue = measured }
        }
    }

    /// How far down to start the column so its middle lands on `centre`,
    /// without pushing its end off the bottom of the page.
    static func centredOffset(page: CGFloat, centre: CGFloat, column: CGFloat) -> CGFloat {
        max(0, min(centre - column / 2, page - column))
    }

    private func measure<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }

    // MARK: - Hero

    /// How long the tunnel has been up.
    private var timer: some View {
        UptimeLabel(meter: tunnel.meter, connected: tunnel.state.isConnected)
    }

    /// Everything above the server list.
    private var hero: some View {
        VStack(spacing: 0) {
            timer
                .padding(.bottom, 20)
            PowerButton(state: tunnel.state, enabled: tunnel.hasSubscription) {
                Task { await tunnel.toggle() }
            }
            .help("\(L.t(tunnel.state.isConnected ? .hintDisconnect : .hintConnect, locale)) · ⌘⇧C")
            notes
        }
    }

    /// The state in words, why it is not connected, and the service's message.
    private var notes: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusPill(
                    title: statusLabel,
                    connected: tunnel.state.isConnected
                ) {
                    page = .connections
                }
                .help(L.t(.titleConnections, locale))
                ModeSwitch(mode: tunnel.tunnelMode, enabled: !tunnel.state.isBusy) { mode in
                    choose(mode)
                }
            }
            .padding(.top, 18)

            // Why it is not connected, or why the list may be stale — a failed
            // connect used to leave only "Отключено", with the reason in the log.
            if let issue = tunnel.issue {
                IssueLine(issue: issue, centered: true)
                    .frame(maxWidth: 440)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            if let announce = tunnel.info.announce {
                AnnounceBanner(text: announce)
                    .frame(maxWidth: 560)
                    .padding(.top, 28)
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: tunnel.issue)
        .animation(Motion.standard, value: tunnel.info.announce)
    }

    /// Switches the transport. TUN without the helper cannot work, so asking
    /// for it goes to Settings, where the helper is installed — and TUN is
    /// switched on once it is.
    private func choose(_ mode: TunnelMode) {
        guard mode != tunnel.tunnelMode else { return }
        if mode == .tun, !tunnel.helperInstalled {
            settings.tunAwaitingHelper = true
            page = .settings
            return
        }
        Task { await tunnel.setTunnelMode(mode) }
    }

    private var statusLabel: String {
        switch tunnel.state {
        case .connected: return L.t(.bigConnected, locale)
        case .connecting: return L.t(.connecting, locale)
        case .disconnecting: return L.t(.disconnecting, locale)
        case .disconnected, .failed: return L.t(.disconnected, locale)
        }
    }

    // MARK: - Servers

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Overline(text: L.t(.servers, locale))
                if !tunnel.nodes.isEmpty {
                    Text(Format.nodes(tunnel.selectableNodes.count, locale: locale))
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                }
                Spacer()
                // Live whether or not the tunnel is up: with it down the probe
                // runs through the idle core. Picking a server is exactly when
                // the latencies matter.
                GlassIconButton(icon: .activity, blinking: tunnel.isPinging) {
                    Task { await tunnel.pingAll() }
                }
                .help(L.t(tunnel.isPinging ? .pinging : .ping, locale))
                .disabled(!tunnel.hasSubscription || tunnel.isPinging)
                .opacity(tunnel.hasSubscription ? 1 : 0.45)

                RefreshButton(refreshing: tunnel.isRefreshing, stoppable: tunnel.canStopRefresh) {
                    if tunnel.canStopRefresh {
                        tunnel.cancelRefresh()
                    } else {
                        Task { await refreshAndReport() }
                    }
                }
                .disabled(!tunnel.hasSubscription)
                .opacity(tunnel.hasSubscription ? 1 : 0.45)
            }
            .padding(.horizontal, 6)

            if tunnel.nodes.isEmpty {
                Panel(radius: Radii.card, padding: 8) { emptyState }
            } else {
                picker
            }
        }
    }

    // MARK: - Picker

    /// The server in use, and the way into the rest — as on the phone: one row
    /// until it is opened.
    private var picker: some View {
        Button {
            withAnimation(Self.drawer) { serversOpen.toggle() }
        } label: {
            HStack(spacing: 12) {
                pickedGlyph
                    .frame(width: 40, height: 40)
                    .mlGlass(.circle, fallback: palette.surface2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(picked.title)
                        .font(.ml(14.5, .heavy))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(picked.subtitle)
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                IconView(.chevronRight, size: 15, strokeWidth: 2.4)
                    .foregroundStyle(palette.text2)
                    .rotationEffect(.degrees(serversOpen ? -90 : 90))
            }
            .padding(.leading, 10)
            .padding(.trailing, 20)
            .frame(height: Self.pickerHeight)
            .mlGlass(.capsule, fallback: palette.surface)
            .contentShape(Capsule())
        }
        .pressCard()
    }

    @ViewBuilder
    private var pickedGlyph: some View {
        if let node = pickedNode, let flag = node.flag {
            Text(flag).font(.system(size: 20))
        } else {
            IconView(.zap, size: 18, strokeWidth: 2.2).foregroundStyle(palette.accentInk)
        }
    }

    /// The node the picker names: the chosen one, or none while "Авто" is.
    private var pickedNode: Node? {
        guard !tunnel.autoSelect, let name = tunnel.selectedNode else { return nil }
        return tunnel.nodes.first { $0.name == name }
    }

    private var picked: (title: String, subtitle: String) {
        if let node = pickedNode { return (node.title, node.subtitle(locale)) }
        return (L.t(.auto, locale), autoSubtitle)
    }

    // MARK: - Drawer

    /// Every server, under the picker. Always in the hierarchy — only its
    /// height moves, from nothing to its measured content, so opening is one
    /// continuous motion rather than a list popping in and a card resizing
    /// after it. It may use whatever height is left under the picker; past
    /// that it scrolls.
    private func drawer(room: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                autoRow.modifier(Cascade(index: 0, shown: serversOpen))
                ForEach(Array(tunnel.selectableNodes.enumerated()), id: \.element.id) { index, node in
                    NodeRow(
                        node: node,
                        selected: !tunnel.autoSelect && node.name == tunnel.selectedNode,
                        measuring: tunnel.pendingProbes.contains(node.name)
                    ) {
                        Task { await tunnel.select(node: node.name) }
                        withAnimation(Self.drawer) { serversOpen = false }
                    }
                    .modifier(Cascade(index: index + 1, shown: serversOpen))
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DrawerHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .mlScrollIndicators(hidden: true)
        .onPreferenceChange(DrawerHeightKey.self) { drawerContent = $0 }
        .padding(8)
        .frame(height: serversOpen ? max(0, min(drawerContent + 16, room)) : 0, alignment: .top)
        .mlGlass(.rounded(Radii.card), fallback: palette.surface)
        // Unfolds from the picker: a hair smaller and transparent while
        // closed, so the card grows out of the pill instead of sliding in.
        .scaleEffect(serversOpen ? 1 : 0.97, anchor: .top)
        .animation(Self.drawer, value: serversOpen)
        // Closing, the card fades faster than it folds, so an empty card is
        // never left shrinking after its rows have gone.
        .opacity(serversOpen ? 1 : 0)
        .animation(serversOpen ? Self.drawer : .easeOut(duration: 0.2), value: serversOpen)
        .allowsHitTesting(serversOpen)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconView(.globe, size: 30)
                .foregroundStyle(palette.textMuted)
            Text(L.t(.noSubscription, locale))
                .font(.ml(15, .heavy))
                .foregroundStyle(palette.text)
            Text(L.t(.noSubscriptionHint, locale))
                .font(.ml(TypeScale.meta))
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
            Button {
                page = .importSubscription
            } label: {
                Text(L.t(.addSubscription, locale))
                    .font(.ml(13, .heavy))
                    .foregroundStyle(palette.textOnAccent)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
            }
            .pressButton()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 26)
    }

    /// The one automatic row.
    ///
    /// When the panel's selector carries its own `url-test` group, this row *is*
    /// that group — choosing it hands the decision to the panel's picker, which
    /// is what its operator built. Showing the app's own "Авто" beside it gave
    /// two rows doing the same job with different answers.
    private var autoRow: some View {
        Button {
            Task { await tunnel.selectAuto() }
            withAnimation(Self.drawer) { serversOpen = false }
        } label: {
            HStack(spacing: 12) {
                IconView(.zap, size: 18, strokeWidth: 2.2)
                    .foregroundStyle(tunnel.autoSelect ? palette.textOnAccent : palette.accentInk)
                    .frame(width: 36, height: 36)
                    .background(tunnel.autoSelect ? palette.accent : palette.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.t(.auto, locale))
                        .font(.ml(14, .heavy))
                        .foregroundStyle(palette.text)
                    Text(autoSubtitle)
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let auto = tunnel.panelAutoNode {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(latencyTone(auto, palette))
                            .frame(width: 6, height: 6)
                        Text(tunnel.pendingProbes.contains(auto.name)
                             ? "…" : Format.latency(auto.latency, unreachable: auto.unreachable))
                            .font(.mlMono(12.5))
                            .foregroundStyle(palette.text2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background {
                if tunnel.autoSelect {
                    Color.clear.mlGlass(.rounded(14), fallback: palette.surface2)
                }
            }
            .contentShape(Rectangle())
        }
        .pressCard()
        .animation(Motion.paint, value: tunnel.autoSelect)
    }

    private var autoSubtitle: String {
        // While it is the active choice, say which node it landed on — that is
        // the thing the row cannot otherwise tell you.
        if tunnel.autoSelect, let name = tunnel.selectedNode,
           let node = tunnel.nodes.first(where: { $0.name == name }), !node.isAutoPicker {
            return "\(L.t(.autoPicked, locale)) \(node.title) · "
                + Format.latency(node.latency, unreachable: node.unreachable)
        }
        if let auto = tunnel.panelAutoNode, let label = auto.protocolLabel {
            return label
        }
        return L.t(.autoSubtitle, locale)
    }
}

// MARK: - Power button

/// The connect control is the moon from the logo.
///
/// Disconnected it is the logo's crescent, dim, with its two stars; connected
/// the shadow slides off and it is a full moon, lit in the logo's own colour in
/// both themes, and the stars fade as the sky brightens. Changing state is the
/// moon changing phase — the one moment in the interface allowed to be
/// expressive, and the brand doing the explaining.
/// While the tunnel is changing state a thin orbit turns round it.
private struct PowerButton: View {
    @Environment(\.palette) private var palette
    let state: ConnectionState
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    private let side: CGFloat = 184
    private var moon: CGFloat { side * 0.5 }
    private var full: Bool { state.isConnected }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(ring, lineWidth: 1)
                if state.isBusy {
                    Orbit()
                        .padding(side * 0.06)
                }
                MoonPhase(full: full, lit: full ? palette.brand : palette.text2)
                    .frame(width: moon, height: moon)
                    .shadow(color: palette.brand.opacity(full ? 0.55 : 0), radius: moon * 0.35)
                stars
            }
            .frame(width: side, height: side)
            .mlGlass(.circle, fallback: palette.surface)
            .contentShape(Circle())
        }
        .buttonStyle(PressScale(scale: Motion.pressButton))
        .disabled(!enabled || state.isBusy)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(Motion.standard, value: full)
        .animation(Motion.paint, value: hovering)
    }

    /// The rim: the moon's colour while it is lit, a quiet line on hover.
    private var ring: Color {
        full ? palette.brand.opacity(0.75) : palette.text.opacity(hovering ? 0.45 : 0)
    }

    /// The logo's two stars, up and to the right of the moon. They belong to
    /// the night, so they go as the moon fills.
    private var stars: some View {
        ZStack {
            Circle().frame(width: moon * 0.1, height: moon * 0.1)
                .offset(x: moon * 0.5, y: -moon * 0.5)
            Circle().frame(width: moon * 0.065, height: moon * 0.065)
                .offset(x: moon * 0.24, y: -moon * 0.72)
        }
        .foregroundStyle(palette.text2)
        .opacity(full ? 0 : 1)
    }
}

/// A lit disc with a second disc cut out of it. The cut's offset is the phase:
/// close in, a crescent lit to the lower left as the logo draws it; slid off,
/// a full moon. The cut is transparent rather than painted, so the glass under
/// the moon shows through the dark part as it does round it.
private struct MoonPhase: View {
    let full: Bool
    let lit: Color

    var body: some View {
        GeometryReader { geometry in
            let d = geometry.size.width
            ZStack {
                Circle().fill(lit)
                Circle()
                    .offset(x: full ? d * 1.15 : d * 0.3, y: full ? -d * 0.9 : -d * 0.24)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

/// A thin arc circling the moon while the tunnel connects or disconnects.
///
/// Driven by the clock rather than by a repeating animation. A
/// `repeatForever` animation claims every change made in its transaction and
/// every change to the view's layout while it runs — so when the page
/// re-centred on connect, or the button grew, the spinner looped those too and
/// the whole control wobbled. A timeline only turns the arc.
private struct Orbit: View {
    @Environment(\.palette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(palette.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .transition(.opacity)
    }
}

/// The state, in words, as a way into the connections screen. Tinted with the
/// accent while the tunnel is up.
private struct StatusPill: View {
    @Environment(\.palette) private var palette
    let title: String
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.ml(13.5, .bold))
                IconView(.chevronRight, size: 14, strokeWidth: 2.4)
            }
            .foregroundStyle(connected ? palette.accentInkStrong : palette.text2)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 34)
            .mlGlass(.capsule,
                     tint: connected ? palette.accent.opacity(0.22) : nil,
                     fallback: connected ? palette.accentQuiet : palette.surface)
            .contentShape(Capsule())
        }
        .pressButton()
        .animation(Motion.paint, value: connected)
    }
}

// MARK: - Node row

private struct NodeRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let node: Node
    let selected: Bool
    let measuring: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // A balancer named for a country is still that country as far as
                // the user is concerned, so it gets the flag its name carries.
                // The accent mark is only for entries with no flag at all — an
                // auto-picker spanning several places.
                if let flag = node.flag {
                    Text(flag).font(.system(size: 20))
                } else {
                    IconView(.zap, size: 16, strokeWidth: 2.2)
                        .foregroundStyle(palette.accentInk)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .font(.ml(14, .bold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    // What the service says the row is for, when it says —
                    // "Poland LTE 1" means little until "Доступность во время
                    // БС" is under it; the flag already gives the country.
                    Text(node.serverDescription ?? node.subtitle(locale))
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Circle()
                        .fill(latencyTone(node, palette))
                        .frame(width: 6, height: 6)
                    Text(measuring ? "…" : Format.latency(node.latency, unreachable: node.unreachable))
                        .font(.mlMono(12.5))
                        .foregroundStyle(palette.text2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if selected {
                    Color.clear.mlGlass(.rounded(14), fallback: palette.surface2)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.text.opacity(hovering ? 0.05 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .pressCard()
        .onHover { hovering = $0 }
        .animation(Motion.paint, value: selected)
        .animation(Motion.paint, value: hovering)
    }
}

/// The dot beside a latency: the ping colour when measured, the danger colour
/// when the probe timed out, muted when not measured yet.
func latencyTone(_ node: Node, _ palette: Palette) -> Color {
    if let latency = node.latency { return palette.pingColor(latency) }
    return node.unreachable ? palette.danger : palette.textMuted
}

/// The drawer's content height, reported from inside its scroll view.
private struct DrawerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A drawer row's arrival: each fades up a few points a beat after the one
/// above, as the card opens. Only the first few are staggered, so a long list
/// is not still arriving after the card has settled; closing drops them all at
/// once and quickly, since nobody watches a list leave.
private struct Cascade: ViewModifier {
    let index: Int
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .animation(
                shown
                    ? ConnectScreen.drawer.delay(0.05 + 0.025 * Double(min(index, 8)))
                    : .easeOut(duration: 0.14),
                value: shown
            )
    }
}

/// The height of everything above the server list.
private struct HeroHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The height of the server list's heading and picker.
private struct HeadHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Uptime

/// The connection time — the page's one figure that changes every second, so
/// the one part of it that observes the meter. The rest of the page, server
/// list included, no longer re-renders with each tick.
private struct UptimeLabel: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    @ObservedObject var meter: TrafficMeter
    let connected: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(L.t(.connectionTime, locale))
                .font(.ml(12, .medium))
                .foregroundStyle(palette.textMuted)
            Text(Format.duration(meter.uptime))
                // A hero number, so the display face — tabular, so the time
                // ticks without the digits shifting under it.
                .font(.mlDisplay(24, .semibold).monospacedDigit())
                .foregroundStyle(connected ? palette.text : palette.textMuted)
                .padding(.top, 2)
                .animation(Motion.paint, value: connected)
        }
    }
}

// MARK: - Mode

/// How traffic reaches the tunnel, beside the state it is in — the system
/// proxy or TUN — and the way to change it without going to Settings.
private struct ModeSwitch: View {
    @Environment(\.appLocale) private var locale
    let mode: TunnelMode
    let enabled: Bool
    let choose: (TunnelMode) -> Void

    var body: some View {
        // The binding never writes the mode itself: choosing TUN with no
        // helper leaves it where it is and goes to Settings instead.
        SegmentedPill(
            selection: Binding(get: { mode }, set: { choose($0) }),
            options: [(TunnelMode.systemProxy, L.t(.modeProxyShort, locale)),
                      (TunnelMode.tun, L.t(.modeTun, locale))],
            height: 28
        )
        .frame(width: 148)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(L.t(mode == .tun ? .modeTunSub : .modeSystemProxySub, locale))
    }
}

// MARK: - Refresh result

/// How a refresh started from this page went.
private struct RefreshToast: Equatable {
    let id = UUID()
    let outcome: TunnelController.RefreshOutcome
    /// Why not, when it failed.
    let issue: TunnelIssue?
}

/// A short note at the foot of the page: updated, stopped, or not and why.
/// Clicking it puts it away; otherwise it goes on its own.
private struct ToastView: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let toast: RefreshToast
    let dismiss: () -> Void

    private var tone: Color {
        switch toast.outcome {
        case .updated: return palette.stUpInk
        case .cancelled: return palette.text2
        case .failed: return palette.danger
        }
    }

    private var icon: Icon {
        switch toast.outcome {
        case .updated: return .check
        case .cancelled: return .x
        case .failed: return .circleAlert
        }
    }

    private var title: L.Key {
        switch toast.outcome {
        case .updated: return .refreshDone
        case .cancelled: return .refreshStopped
        case .failed: return .refreshFailed
        }
    }

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 12) {
                IconView(icon, size: 15, strokeWidth: toast.outcome == .updated ? 2.6 : 2.2)
                    .foregroundStyle(tone)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tone.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.t(title, locale))
                        .font(.ml(13.5, .heavy))
                        .foregroundStyle(palette.text)
                    Text(detail)
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 20)
            .padding(.vertical, 9)
            .mlGlass(.rounded(24), fallback: palette.surface)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .pressCard()
    }

    private var detail: String {
        switch toast.outcome {
        case .updated: return L.t(.refreshDoneDetail, locale)
        case .cancelled: return L.t(.refreshStoppedDetail, locale)
        case .failed: return toast.issue.map { L.issue($0, locale) } ?? L.t(.issueTryLater, locale)
        }
    }
}

// MARK: - Refresh button

/// Refreshes the subscription, and stops a refresh that is taking too long.
///
/// While a refresh runs the glyph turns. Once it has run long enough to be
/// worth stopping — see `TunnelController.canStopRefresh` — pointing at the
/// button turns the glyph into a cross, and a press stops it: the browser's
/// reload button, which is a stop button while a page loads.
private struct RefreshButton: View {
    @Environment(\.appLocale) private var locale
    let refreshing: Bool
    let stoppable: Bool
    let action: () -> Void

    @State private var hovering = false

    private var showsStop: Bool { stoppable && hovering }

    var body: some View {
        GlassIconButton(icon: showsStop ? .x : .refreshCW,
                        spinning: refreshing && !showsStop, action: action)
            .onHover { hovering = $0 }
            .help(L.t(stoppable ? .stopRefresh : refreshing ? .refreshing : .refresh, locale))
            // A glyph alone says nothing to VoiceOver.
            .accessibilityLabel(L.t(stoppable ? .stopRefresh : .refresh, locale))
    }
}
