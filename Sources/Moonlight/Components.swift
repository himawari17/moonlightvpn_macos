import SwiftUI
import MoonlightDesign
import MoonlightCore

// MARK: - Press

/// The system's only three press scales. Presses shrink; hovers change colour
/// or border, never scale up.
struct PressScale: ButtonStyle {
    var scale: CGFloat = Motion.pressButton

    func makeBody(configuration: Configuration) -> some View {
        PressScaleBody(configuration: configuration, scale: scale)
    }
}

/// A view rather than the style's body directly, so it can read whether the
/// button is enabled: a disabled control showing the pointing hand promises a
/// click that does nothing.
private struct PressScaleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.paint, value: configuration.isPressed)
            .pointerCursor(isEnabled)
    }
}

extension View {
    /// `scrollIndicators` is macOS 13+. On 12 the scroller keeps its default
    /// behaviour, which is the same overlay style — the modifier only exists to
    /// hide it, and a visible scroller is a far smaller cost than dropping
    /// Monterey.
    @ViewBuilder
    func mlScrollIndicators(hidden: Bool) -> some View {
        if #available(macOS 13.0, *) {
            scrollIndicators(hidden ? .never : .visible)
        } else {
            self
        }
    }

    /// No rubber-banding while the content fits: a page that only sometimes
    /// overflows should not bounce the rest of the time.
    @ViewBuilder
    func mlScrollBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }

    /// The pointing hand on hover.
    ///
    /// AppKit does not infer this from a SwiftUI `Button` the way the web does
    /// from an `<a>`, so every clickable surface has to ask. It lives in the
    /// shared button style, which is what most of the app goes through.
    ///
    /// On 15 SwiftUI owns the cursor itself (`pointerStyle`). Before that the
    /// cursor has to be set by hand, and a `push`/`pop` pair on hover — what
    /// this used to be everywhere — drifts: a view re-rendered or removed while
    /// hovered never pops, the stack unbalances, and the hand goes missing on
    /// some controls and sticks on others. Setting it on every move inside the
    /// view re-asserts it instead.
    @ViewBuilder
    func pointerCursor(_ enabled: Bool = true) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? .link : nil)
        } else if #available(macOS 13.0, *) {
            onContinuousHover { phase in
                guard enabled else { return }
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        } else {
            onHover { inside in
                guard enabled else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

extension View {
    func pressCard() -> some View { buttonStyle(PressScale(scale: Motion.pressCard)) }
    func pressButton() -> some View { buttonStyle(PressScale(scale: Motion.pressButton)) }
    func pressIcon() -> some View { buttonStyle(PressScale(scale: Motion.pressIcon)) }
}

/// How every page arrives: it fades in as it settles the last few points into
/// place, on the one curve.
///
/// The curve is scoped to the fade and the offset where the system allows it
/// (macOS 14). `.animation(_:value:)` on a whole page animates everything else
/// that changes in the same update too — a page that measures itself and
/// centres its content on arrival would slide into place instead of starting
/// there.
struct PageEntrance: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 14.0, *) {
                content.animation(Motion.standard) {
                    $0.opacity(shown ? 1 : 0).offset(y: shown ? 0 : Motion.riseDistance)
                }
            } else {
                content
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : Motion.riseDistance)
                    .animation(Motion.standard, value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

// MARK: - Containers

/// A card at one of the system radii: glass on 26 and later, `--ml-surface`
/// before it.
///
/// No outline. The canvas behind every card is `bgDeep`, a step darker than
/// the surface in both themes, so the fill alone separates them — a hairline
/// on top of that was a second edge saying the same thing. The content is
/// clipped to the card and the glass sits behind, unclipped, so its rim is
/// not shaved off.
struct Panel<Content: View>: View {
    @Environment(\.palette) private var palette
    var radius: CGFloat = Radii.card
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .mlGlass(.rounded(radius), fallback: palette.surface)
    }
}

/// A page that scrolls, with room for its glass's shadows.
///
/// Liquid Glass casts a soft shadow past each card's edge, and a scroll view
/// clips what it holds to its own bounds. Inset by the page's margins, it cut
/// those shadows off in straight lines down both sides of the cards and along
/// the bottom of the window — hard grey edges that on the light theme's white
/// canvas looked like dirt. This scroll view reaches out to the window's edges
/// and takes the margins back inside, so the cards sit exactly where they did
/// and their shadows have faded out before anything clips them.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Up to the header and no further: past it, scrolled cards would draw
        // over the page's title.
        ScrollView {
            content
                .padding(.horizontal, RootView.pageGutter)
                .padding(.top, RootView.pageTopInset)
                .padding(.bottom, RootView.pageBottomInset)
        }
        .mlScrollIndicators(hidden: true)
        .padding(.horizontal, -RootView.pageGutter)
        .padding(.top, -RootView.pageTopInset)
        .padding(.bottom, -RootView.pageBottomInset)
    }
}

/// A card of rows with no padding of its own — the rows carry it, so the hairline
/// between them can run to the card's edge or be inset past an icon.
struct RowGroup<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .clipShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .mlGlass(.rounded(Radii.card), fallback: palette.surface)
    }
}

/// Content at its own height while it fits, a scroll view once it does not.
///
/// A `ScrollView` takes all the height it is offered, so a list of four
/// servers in one stretched its card to the bottom of the window. On 12 there
/// is no `ViewThatFits`, and the scroll view is the safe half of the pair.
struct FitOrScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 13.0, *) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.mlScrollIndicators(hidden: true)
            }
        } else {
            ScrollView { content }
        }
    }
}

struct RowDivider: View {
    @Environment(\.palette) private var palette
    /// The design insets the rule past the icon column on rows that have one.
    var leading: CGFloat = 18

    var body: some View {
        palette.hairlineSoft
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

/// A table column heading.
///
/// The tracking lives on the `Text`, not on the row: `View.tracking` is macOS
/// 13+, while `Text.tracking` goes back much further, and a header row is an
/// `HStack` of several texts.
struct ColumnHeading: View {
    @Environment(\.palette) private var palette
    let text: String
    var width: CGFloat?
    var alignment: Alignment = .leading

    var body: some View {
        Text(text)
            .font(.ml(10.5, .heavy))
            .tracking(0.08 * 10.5)
            .foregroundStyle(palette.textMuted)
            // A heading never wraps: broken over two lines it reads as two words.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

/// `11.5px / 800 / .1em`, uppercase — the label above every group.
struct Overline: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.ml(TypeScale.micro, .heavy))
            .tracking(TypeScale.trackOverline * TypeScale.micro)
            .foregroundStyle(palette.textMuted)
    }
}

/// The rounded tile a row's glyph sits in: a quiet grey step with the glyph
/// in the text colour.
struct IconTile: View {
    @Environment(\.palette) private var palette
    let icon: Icon
    var fill: Color
    var size: CGFloat = 40
    var glyph: CGFloat = 17
    /// Turns the glyph while something is in flight. The glyph alone: turning
    /// the whole tile turned its glass with it, and rotated glass draws as a
    /// skewed slab swinging out past the row.
    var spinning = false

    var body: some View {
        IconView(icon, size: glyph)
            .inFlight(.spin, spinning)
            .foregroundStyle(palette.text)
            .frame(width: size, height: size)
            .mlGlass(.rounded(Radii.tile), fallback: fill)
    }
}

/// Turns or pulses a glyph while something is in flight.
///
/// Driven by the clock, never by a repeating animation: `repeatForever` claims
/// every other change in its transaction and every layout change while it
/// runs, so a spinning refresh icon dragged its own button round in a loop
/// whenever the page around it moved.
struct InFlight: ViewModifier {
    enum Kind { case spin, pulse }
    let kind: Kind
    let active: Bool
    var period: Double = 0.9

    func body(content: Content) -> some View {
        if active {
            // Sixty frames a second at most: on a 120 Hz display the timeline
            // would otherwise redraw twice as often for a glyph turning once
            // a second.
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: period) / period
                switch kind {
                case .spin: content.rotationEffect(.degrees(phase * 360))
                case .pulse: content.opacity(0.35 + 0.65 * abs(cos(phase * .pi)))
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func inFlight(_ kind: InFlight.Kind, _ active: Bool) -> some View {
        modifier(InFlight(kind: kind, active: active))
    }
}

// MARK: - Controls

/// 44×26 track, 20px knob, 18px of travel — the one switch in the system.
struct MLToggle: View {
    @Environment(\.palette) private var palette
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                // A translucent ink rather than `surface3` when off: on glass the
                // solid grey all but vanished against the light theme.
                Capsule().fill(isOn ? palette.accent : palette.text.opacity(0.12))
                // The knob is the opposite of its track: on a white track in
                // the dark theme a white knob would vanish.
                Circle()
                    .fill(isOn ? palette.textOnAccent : palette.text)
                    .frame(width: 20, height: 20)
                    .offset(x: isOn ? 21 : 3)
            }
            .frame(width: 44, height: 26)
            .animation(Motion.slide, value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .pointerCursor(enabled)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// The segmented pill: one accent capsule slides between the options.
///
/// The capsule is a single view positioned by index rather than a background on
/// whichever option is active paired with `matchedGeometryEffect`. That pairing
/// animates only when SwiftUI matches the two across the same transaction, which
/// it does not do reliably when the options are rebuilt by a `ForEach` — the
/// fill jumped instead of sliding. One view that moves cannot jump.
struct SegmentedPill<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var height: CGFloat = 34
    var onSelect: ((Value) -> Void)?

    private var index: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(max(1, options.count))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.accent)
                    .frame(width: width, height: height)
                    .offset(x: width * CGFloat(index))

                HStack(spacing: 0) {
                    ForEach(options, id: \.value) { option in
                        let active = option.value == selection
                        Button {
                            selection = option.value
                            onSelect?(option.value)
                        } label: {
                            Text(option.label)
                                .font(.ml(12.5, .heavy))
                                .foregroundStyle(active ? palette.textOnAccent : palette.textMuted)
                                .frame(width: width, height: height)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
            .animation(Motion.slide, value: index)
        }
        .frame(height: height)
        .padding(3)
        .mlGlass(.capsule, fallback: palette.surface2)
    }
}

/// A small round action on glass: accent-ink glyph, no label — the label is
/// the tooltip.
struct GlassIconButton: View {
    @Environment(\.palette) private var palette
    let icon: Icon
    var spinning = false
    var blinking = false
    var action: () -> Void


    var body: some View {
        Button(action: action) {
            IconView(icon, size: 15, strokeWidth: 2)
                .inFlight(.spin, spinning)
                .inFlight(.pulse, blinking)
                .foregroundStyle(palette.accentInk)
                .frame(width: 32, height: 32)
                .mlGlass(.circle, fallback: palette.surface)
                .contentShape(Circle())
        }
        .pressIcon()
    }
}

/// A filled accent button — the one primary action shape.
struct AccentButton: View {
    @Environment(\.palette) private var palette
    let title: String
    var height: CGFloat = 50
    var fullWidth = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ml(15, .heavy))
                .foregroundStyle(palette.textOnAccent)
                .padding(.horizontal, 32)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
        }
        .pressButton()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A tappable row: tile, title, subtitle, trailing chevron or external-link mark.
struct ActionRow: View {
    @Environment(\.palette) private var palette
    let icon: Icon
    let fill: Color
    let title: String
    let subtitle: String
    var trailing: Icon? = .chevronRight
    var spinning = false
    var action: () -> Void


    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(icon: icon, fill: fill, spinning: spinning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.ml(15, .heavy))
                        .foregroundStyle(palette.text)
                    Text(subtitle)
                        .font(.ml(TypeScale.meta))
                        .foregroundStyle(palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    IconView(trailing, size: trailing == .chevronRight ? 18 : 17,
                             strokeWidth: trailing == .chevronRight ? 2.2 : 2)
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .pressCard()
    }
}

/// A settings row with a switch on the right.
struct ToggleRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ml(14.5, .bold))
                    .foregroundStyle(palette.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MLToggle(isOn: $isOn, enabled: enabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

/// A progress bar at the two sizes the design uses (6px in the sidebar, 8px on
/// the subscription card).
/// A quota bar. The fill is the portion **used**.
///
/// Named `used` rather than `fraction` on purpose: the two bars showing this
/// same number disagreed for a while, one filling with what was spent and the
/// other with what was left, because the parameter said neither. A name that
/// states the direction is what stops that recurring.
struct QuotaBar: View {
    @Environment(\.palette) private var palette
    /// Portion of the quota consumed, 0…1. Nil means there is no quota, which
    /// draws empty — an unlimited plan has used none *of a limit*, and filling
    /// the bar would read as "all of it".
    let used: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.text.opacity(0.1))
                Capsule()
                    .fill(palette.accent)
                    .frame(width: geometry.size.width * min(1, max(0, used ?? 0)))
            }
        }
        .frame(height: height)
        .animation(Motion.paint, value: used)
    }
}


/// The subscription service's announcement (`announce`), as it wrote it.
///
/// It can be folded to its first line and opened again, or put away. Both are
/// remembered per message: folding or dismissing one does nothing to the next,
/// which is new news by definition. Folding is the gentler of the two — a
/// message of several lines pushes the server list down the page, and the
/// only way to have the room back used to be to lose the message.
struct AnnounceBanner: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let text: String

    @ObservedObject private var kept = AnnounceMemory.shared

    private var collapsed: Bool { kept.folded == text }

    var body: some View {
        if kept.dismissed != text {
            HStack(alignment: .top, spacing: 12) {
                IconView(.messageCircle, size: 17)
                    .foregroundStyle(palette.accentInk)
                    .padding(.top, 1)
                message
                Button(action: toggle) {
                    // One chevron that turns, as on the server picker, rather
                    // than two glyphs swapped.
                    IconView(.chevronRight, size: 14, strokeWidth: 2.4)
                        .rotationEffect(.degrees(collapsed ? 90 : -90))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .pressIcon()
                .help(L.t(collapsed ? .expandAnnounce : .collapseAnnounce, locale))
                Button {
                    withAnimation(Motion.standard) { kept.dismissed = text }
                } label: {
                    IconView(.x, size: 14)
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .pressIcon()
                .help(L.t(.hideAnnounce, locale))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .mlGlass(.rounded(Radii.card), tint: palette.accent.opacity(0.18),
                     fallback: palette.accentQuiet)
            .transition(.opacity)
        }
    }

    /// The message whole, and its first line, one over the other.
    ///
    /// Both are always laid out and only the height between them moves, so
    /// the banner folds in one motion: the whole text stays where it is and
    /// is covered from below while the single line fades in over its first.
    /// Swapping a line limit instead re-broke the text on the first frame —
    /// it snapped to one line with an ellipsis while the card was still
    /// closing around where the rest had been.
    private var message: some View {
        ZStack(alignment: .topLeading) {
            line.lineLimit(1)
                .truncationMode(.tail)
                .opacity(collapsed ? 1 : 0)
            line.fixedSize(horizontal: false, vertical: true)
                .opacity(collapsed ? 0 : 1)
                // Folded it takes no room and hangs below the first line,
                // where the clip hides it.
                .frame(height: collapsed ? 0 : nil, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        // The text is the larger target, and what a hand reaches for first.
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var line: some View {
        Text(text)
            .font(.ml(13, .medium))
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Animated at the source: the page under the banner — the server list,
    /// the cards of the subscription page, the tray's rows — moves with it,
    /// on the one curve.
    private func toggle() {
        withAnimation(Motion.standard) { kept.folded = collapsed ? "" : text }
    }
}

/// What was done with the announcement — folded, or put away — and to which
/// message, kept across launches and shared by every place the banner shows:
/// the connect page, the subscription page and the tray.
///
/// An object the banner observes rather than `@AppStorage` on the banner. A
/// value written through the defaults comes back to the view from the
/// defaults' own observer, outside the transaction that wrote it and so
/// outside its animation: the banner folded, and went away, in a single frame
/// whatever curve the write was wrapped in.
@MainActor
final class AnnounceMemory: ObservableObject {
    static let shared = AnnounceMemory()

    /// The message folded to its first line, or none.
    @Published var folded: String {
        didSet { UserDefaults.standard.set(folded, forKey: Self.foldedKey) }
    }
    /// The message put away, or none.
    @Published var dismissed: String {
        didSet { UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey) }
    }

    private static let foldedKey = "collapsedAnnouncement"
    private static let dismissedKey = "dismissedAnnouncement"

    private init() {
        folded = UserDefaults.standard.string(forKey: Self.foldedKey) ?? ""
        dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey) ?? ""
    }
}

/// A short line for the current ``TunnelIssue``, in the danger colour.
struct IssueLine: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let issue: TunnelIssue
    var centered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(.circleAlert, size: 15).padding(.top, 1)
            Text(L.issue(issue, locale))
                .font(.ml(12.5, .medium))
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.danger)
    }
}
