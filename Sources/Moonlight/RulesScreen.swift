import SwiftUI
import UniformTypeIdentifiers
import MoonlightDesign
import MoonlightCore

/// Routing rules, laid out the way Flowvy does it: the user's own, and the
/// subscription's.
///
/// The user's own rules are kept by the app, apart from the subscription, so a
/// refresh never touches them. Each goes before the subscription's rules
/// (Override) or after them (Extend), to `DIRECT`, `REJECT` or one of the
/// subscription's groups. They can be switched off, edited, deleted and
/// dragged into order — and all of that is a draft until **Apply**, which has
/// the core check them first: a rule it refuses would take the whole config,
/// and the tunnel, down with it.
///
/// The subscription's rules are shown as it wrote them, to read, not to edit.
struct RulesScreen: View {
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    @Binding var page: Page

    private enum Tab: Hashable { case mine, profile }

    /// The rule the editor is open on: an existing one, or nil for a new one.
    private struct Editing: Identifiable {
        let id = UUID()
        var rule: RoutingRule?
    }

    @State private var tab: Tab = .mine
    /// The rules as last applied, and as being edited.
    @State private var saved: [RoutingRule] = []
    @State private var draft: [RoutingRule] = []
    @State private var query = ""
    @State private var editing: Editing?
    @State private var dragging: RoutingRule.ID?
    @State private var applying = false
    /// Whether the apply under way has the core download the AS numbers first.
    @State private var downloading = false
    /// Why the last apply did not go through, until the draft changes.
    @State private var refusal: TunnelController.RulesRefusal?
    /// The subscription's rules, parsed once per change rather than per render.
    @State private var profile: [ProfileRule] = []

    private var dirty: Bool { draft != saved }
    private var failed: Bool { refusal != nil }

    private var filter: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var shownMine: [RoutingRule] {
        guard !filter.isEmpty else { return draft }
        return draft.filter {
            $0.kind.rawValue.lowercased().contains(filter) || $0.value.lowercased().contains(filter)
                || $0.target.lowercased().contains(filter)
        }
    }

    private var shownProfile: [(index: Int, rule: ProfileRule)] {
        let all = profile.enumerated().map { (index: $0.offset, rule: $0.element) }
        guard !filter.isEmpty else { return all }
        return all.filter {
            $0.rule.kind.lowercased().contains(filter) || $0.rule.value.lowercased().contains(filter)
                || $0.rule.target.lowercased().contains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            controls
            if tunnel.routingMode != .rule { modeNote }
            ZStack {
                if tab == .mine { mine } else { subscription }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) { applyBar }
        .sheet(item: $editing) { editing in
            RuleEditor(
                original: editing.rule,
                groups: tunnel.ruleTargets,
                tunnelMode: tunnel.tunnelMode,
                save: { rule in
                    if let at = draft.firstIndex(where: { $0.id == rule.id }) {
                        draft[at] = rule
                    } else {
                        withAnimation(Motion.standard) { draft.append(rule) }
                    }
                    refusal = nil
                    self.editing = nil
                },
                cancel: { self.editing = nil }
            )
            // A sheet is a window of its own, and takes none of this one's
            // theme or language with it unless handed them.
            .environment(\.palette, palette)
            .environment(\.liquidGlass, settings.liquidGlass)
            .mlLocale(locale)
            .preferredColorScheme(settings.theme == .dark ? .dark : .light)
        }
        .onAppear {
            saved = tunnel.routingRules
            draft = saved
            profile = tunnel.profileRules.map(ProfileRule.init(line:))
        }
        .onChange(of: tunnel.profileRules) { lines in
            profile = lines.map(ProfileRule.init(line:))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            SegmentedPill(
                selection: $tab,
                options: [(Tab.mine, L.t(.rulesMine, locale)), (Tab.profile, L.t(.rulesProfile, locale))],
                height: 28
            )
            .frame(width: 290)

            Text("\(L.t(tab == .mine ? .rulesOwnCount : .rulesProfileCount, locale)): "
                 + "\(tab == .mine ? draft.count : profile.count)")
                .font(.ml(12.5, .heavy))
                .foregroundStyle(palette.accentInk)
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 34)
                .mlGlass(.capsule, tint: palette.accent.opacity(0.18), fallback: palette.accentQuiet)

            HStack(spacing: 8) {
                IconView(.search, size: 14).foregroundStyle(palette.textMuted)
                TextField(L.t(.rulesFilter, locale), text: $query)
                    .textFieldStyle(.plain)
                    .font(.ml(12.5))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .mlGlass(.capsule, fallback: palette.surface2)

            if tab == .mine {
                Button {
                    editing = Editing(rule: nil)
                } label: {
                    HStack(spacing: 6) {
                        IconView(.plus, size: 14, strokeWidth: 2.6)
                        Text(L.t(.rulesAdd, locale)).font(.ml(12.5, .heavy)).fixedSize()
                    }
                    .foregroundStyle(palette.textOnAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
                }
                .pressButton()
            }
        }
    }

    private var modeNote: some View {
        HStack(spacing: 10) {
            IconView(.circleAlert, size: 15).foregroundStyle(palette.warning)
            Text(L.t(.rulesModeNote, locale))
                .font(.ml(12.5))
                .foregroundStyle(palette.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - My rules

    @ViewBuilder
    private var mine: some View {
        if draft.isEmpty {
            emptyPanel(title: L.t(.rulesEmpty, locale), hint: L.t(.rulesEmptyHint, locale), add: true)
        } else {
            Panel(radius: Radii.card, padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: RuleColumns.spacing) {
                        Color.clear.frame(width: RuleColumns.grip + RuleColumns.spacing + RuleColumns.toggle,
                                          height: 0)
                        ColumnHeading(text: L.t(.colType, locale), width: RuleColumns.type)
                        ColumnHeading(text: L.t(.colValue, locale))
                        ColumnHeading(text: L.t(.colTarget, locale), width: RuleColumns.target)
                        ColumnHeading(text: L.t(.colPriority, locale), width: RuleColumns.priority)
                        Color.clear.frame(width: RuleColumns.actions, height: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    palette.hairlineSoft.frame(height: 1)

                    FitOrScroll {
                        VStack(spacing: 0) {
                            ForEach(shownMine) { rule in
                                row(for: rule)
                                palette.hairlineSoft.frame(height: 1)
                            }
                            if shownMine.isEmpty { nothingFound }
                        }
                        // Room for the apply bar, which floats over the foot.
                        .padding(.bottom, dirty || failed ? 64 : 0)
                    }
                }
            }
        }
    }

    private func row(for rule: RoutingRule) -> some View {
        OwnRuleRow(
            rule: rule,
            missing: ![RoutingRule.direct, RoutingRule.reject].contains(rule.target)
                && !tunnel.ruleTargets.contains(rule.target),
            tunOnly: rule.kind.needsProcessMatching && tunnel.tunnelMode != .tun,
            reorderable: filter.isEmpty,
            isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    guard let at = draft.firstIndex(where: { $0.id == rule.id }) else { return }
                    draft[at].enabled = on
                    refusal = nil
                }
            ),
            edit: { editing = Editing(rule: rule) },
            delete: {
                withAnimation(Motion.standard) { draft.removeAll { $0.id == rule.id } }
                refusal = nil
            },
            startDrag: { dragging = rule.id }
        )
        .onDrop(of: [UTType.text], delegate: RuleDrop(target: rule, rules: $draft, dragging: $dragging))
    }

    // MARK: - The subscription's rules

    @ViewBuilder
    private var subscription: some View {
        if profile.isEmpty {
            emptyPanel(
                title: L.t(tunnel.hasSubscription ? .rulesProfileEmpty : .noSubscription, locale),
                hint: nil, add: false
            )
        } else {
            Panel(radius: Radii.card, padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: RuleColumns.spacing) {
                        ColumnHeading(text: "#", width: RuleColumns.index, alignment: .trailing)
                        ColumnHeading(text: L.t(.colType, locale), width: RuleColumns.type)
                        ColumnHeading(text: L.t(.colValue, locale))
                        ColumnHeading(text: L.t(.colTarget, locale), width: RuleColumns.profileTarget)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    palette.hairlineSoft.frame(height: 1)

                    // A subscription can carry hundreds of rules: lazily.
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shownProfile, id: \.index) { entry in
                                ProfileRuleRow(index: entry.index + 1, rule: entry.rule)
                                palette.hairlineSoft.frame(height: 1)
                            }
                            if shownProfile.isEmpty { nothingFound }
                        }
                    }
                    .mlScrollIndicators(hidden: false)
                }
            }
        }
    }

    // MARK: - Pieces

    private var nothingFound: some View {
        Text(L.t(.nothingFound, locale))
            .font(.ml(TypeScale.meta))
            .foregroundStyle(palette.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func emptyPanel(title: String, hint: String?, add: Bool) -> some View {
        Panel(radius: Radii.card, padding: 36) {
            VStack(spacing: 10) {
                IconView(.route, size: 30).foregroundStyle(palette.textMuted)
                Text(title)
                    .font(.ml(15, .heavy))
                    .foregroundStyle(palette.text)
                if let hint {
                    Text(hint)
                        .font(.ml(TypeScale.meta))
                        .foregroundStyle(palette.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if add {
                    Button {
                        editing = Editing(rule: nil)
                    } label: {
                        Text(L.t(.rulesAdd, locale))
                            .font(.ml(13, .heavy))
                            .foregroundStyle(palette.textOnAccent)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
                    }
                    .pressButton()
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Unsaved changes, and the way to keep or drop them — over the foot of
    /// the page, only while there is something to apply.
    private var applyBar: some View {
        ZStack {
            if dirty || failed {
                // Every label keeps its own width. A row hands its flexible
                // children equal shares of what is left rather than what each
                // asks for: beside the shorter "Применяются…" the share that
                // came to Apply was narrower than its label, and the label
                // wrapped — "Применит", "ь" — for as long as applying took.
                HStack(spacing: 14) {
                    ZStack {
                        if applying {
                            ProgressView().controlSize(.small)
                        } else {
                            IconView(.circleAlert, size: 15)
                                .foregroundStyle(failed ? palette.danger : palette.textMuted)
                        }
                    }
                    .frame(width: 16, height: 16)
                    // The note is as wide as the longest thing it says while
                    // the bar is up, so pressing Apply changes the words and
                    // leaves the buttons where the pointer is.
                    // Where applying has the core download the AS numbers first,
                    // the wait says so rather than only that it is applying.
                    let wait = L.t((applying ? downloading : tunnel.downloadsDatabase(for: draft))
                                   ? .rulesDownloading : .rulesApplying, locale)
                    ZStack(alignment: .leading) {
                        Group {
                            Text(L.t(.rulesUnsaved, locale))
                            Text(wait)
                            if failed { Text(refusalText) }
                        }
                        .hidden()
                        .accessibilityHidden(true)
                        if applying {
                            Text(wait)
                                .foregroundStyle(palette.text2)
                        } else {
                            Text(failed ? refusalText : L.t(.rulesUnsaved, locale))
                                .foregroundStyle(failed ? palette.danger : palette.text2)
                        }
                    }
                    .font(.ml(12.5, .semibold))
                    .fixedSize()
                    Button {
                        withAnimation(Motion.standard) { draft = saved }
                        refusal = nil
                    } label: {
                        Text(L.t(.rulesReset, locale))
                            .font(.ml(12.5, .heavy))
                            .foregroundStyle(palette.text)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                    }
                    .pressButton()
                    .disabled(applying)
                    Button(action: apply) {
                        Text(L.t(.rulesApply, locale))
                            .font(.ml(12.5, .heavy))
                            .foregroundStyle(palette.textOnAccent)
                            .fixedSize()
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
                    }
                    .pressButton()
                    .disabled(applying || !dirty)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .mlGlass(.capsule, fallback: palette.surface)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: dirty || failed)
        .animation(Motion.paint, value: applying)
    }

    /// What went wrong with the last apply: a blocked download is not the
    /// core refusing the rules, and says which database it was.
    private var refusalText: String {
        switch refusal {
        case .downloadBlocked(let asn):
            return L.t(asn ? .rulesDownloadBlockedASN : .rulesDownloadBlocked, locale)
        case .rejected, nil:
            return L.t(.rulesApplyFailed, locale)
        }
    }

    private func apply() {
        let rules = draft
        downloading = tunnel.downloadsDatabase(for: rules)
        applying = true
        Task {
            let refused = await tunnel.applyRoutingRules(rules)
            applying = false
            refusal = refused
            if refused == nil { saved = rules }
        }
    }
}

/// The rules tables' column widths, shared by headers and rows.
private enum RuleColumns {
    static let spacing: CGFloat = 12
    static let grip: CGFloat = 14
    static let toggle: CGFloat = 44
    static let type: CGFloat = 150
    static let target: CGFloat = 130
    static let priority: CGFloat = 86
    static let actions: CGFloat = 62
    static let index: CGFloat = 30
    static let profileTarget: CGFloat = 170
}

// MARK: - Rows

private struct OwnRuleRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let rule: RoutingRule
    /// Points at a group the subscription no longer has.
    let missing: Bool
    /// A process rule while the tunnel runs as a system proxy.
    let tunOnly: Bool
    let reorderable: Bool
    @Binding var isOn: Bool
    let edit: () -> Void
    let delete: () -> Void
    let startDrag: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: RuleColumns.spacing) {
            IconView(.gripVertical, size: 14)
                .foregroundStyle(palette.textMuted.opacity(reorderable ? 1 : 0.3))
                .frame(width: RuleColumns.grip, height: 28)
                .contentShape(Rectangle())
                .help(L.t(.ruleDragHint, locale))
                .onDrag {
                    startDrag()
                    return NSItemProvider(object: rule.id.uuidString as NSString)
                }
                .allowsHitTesting(reorderable)

            MLToggle(isOn: $isOn)
                .frame(width: RuleColumns.toggle)

            Group {
                HStack(spacing: 6) {
                    KindChip(kind: rule.kind.rawValue)
                    if tunOnly {
                        Text("TUN")
                            .font(.ml(9.5, .heavy))
                            .foregroundStyle(palette.warning)
                            .help(L.t(.ruleTunOnly, locale))
                    }
                }
                .frame(width: RuleColumns.type, alignment: .leading)

                Text(rule.value)
                    .font(.mlMono(12.5))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(rule.value)

                Text(rule.target)
                    .font(.ml(12.5, .bold))
                    .foregroundStyle(missing ? palette.danger : targetTone)
                    .lineLimit(1)
                    .frame(width: RuleColumns.target, alignment: .leading)
                    .help(missing ? L.t(.targetMissing, locale) : rule.target)

                PriorityBadge(priority: rule.priority)
                    .frame(width: RuleColumns.priority, alignment: .leading)
            }
            .opacity(rule.enabled ? 1 : 0.45)

            HStack(spacing: 10) {
                RowIconButton(icon: .squarePen, hint: L.t(.ruleEditHint, locale), action: edit)
                RowIconButton(icon: .trash2, hint: L.t(.ruleDeleteHint, locale),
                              danger: true, action: delete)
            }
            .frame(width: RuleColumns.actions, alignment: .trailing)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.text.opacity(hovering ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.paint, value: hovering)
        .animation(Motion.paint, value: rule.enabled)
    }

    private var targetTone: Color {
        switch rule.target {
        case RoutingRule.direct: return palette.text2
        case RoutingRule.reject: return palette.danger
        default: return palette.accentInk
        }
    }
}

private struct ProfileRuleRow: View {
    @Environment(\.palette) private var palette
    let index: Int
    let rule: ProfileRule

    var body: some View {
        HStack(spacing: RuleColumns.spacing) {
            Text("\(index)")
                .font(.mlMono(11))
                .foregroundStyle(palette.textMuted)
                .frame(width: RuleColumns.index, alignment: .trailing)
            KindChip(kind: rule.kind)
                .frame(width: RuleColumns.type, alignment: .leading)
            Text(rule.value.isEmpty ? "—" : rule.value)
                .font(.mlMono(12))
                .foregroundStyle(rule.value.isEmpty ? palette.textMuted : palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(rule.value)
            Text(rule.target)
                .font(.ml(12, .bold))
                .foregroundStyle(rule.target == RoutingRule.reject ? palette.danger
                                 : rule.target == RoutingRule.direct ? palette.text2 : palette.accentInk)
                .lineLimit(1)
                .frame(width: RuleColumns.profileTarget, alignment: .leading)
                .help(rule.target)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// A rule's type, in the core's own spelling.
private struct KindChip: View {
    @Environment(\.palette) private var palette
    let kind: String

    var body: some View {
        Text(kind)
            .font(.mlMono(11, .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.text.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct PriorityBadge: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let priority: RoutingRule.Priority

    var body: some View {
        let override = priority == .override
        Text(L.t(override ? .priorityOverride : .priorityExtend, locale).uppercased())
            .font(.ml(10.5, .heavy))
            .tracking(0.05 * 10.5)
            .foregroundStyle(override ? palette.accentInk : palette.text2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(override ? palette.accent.opacity(0.13) : palette.text.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help(L.t(override ? .priorityOverrideSub : .priorityExtendSub, locale))
    }
}

private struct RowIconButton: View {
    @Environment(\.palette) private var palette
    let icon: Icon
    let hint: String
    var danger = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 15)
                .foregroundStyle(hovering ? (danger ? palette.danger : palette.text) : palette.textMuted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .pressIcon()
        .onHover { hovering = $0 }
        .animation(Motion.paint, value: hovering)
        .help(hint)
    }
}

/// Reorders as a dragged rule passes over another, so the list makes room
/// under the pointer rather than jumping on the drop.
private struct RuleDrop: DropDelegate {
    let target: RoutingRule
    @Binding var rules: [RoutingRule]
    @Binding var dragging: RoutingRule.ID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id,
              let from = rules.firstIndex(where: { $0.id == dragging }),
              let to = rules.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(Motion.standard) {
            rules.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
