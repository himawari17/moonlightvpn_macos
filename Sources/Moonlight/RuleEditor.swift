import SwiftUI
import MoonlightDesign
import MoonlightCore

/// Adding or editing one rule of the user's own: what it matches, where it
/// sends it, and whether it goes before or after the subscription's rules.
///
/// The value is checked before the rule is kept — a value the core refuses
/// would take the whole config down, not just the rule.
struct RuleEditor: View {
    @Environment(\.palette) private var palette
    @Environment(\.liquidGlass) private var liquidGlass
    @Environment(\.appLocale) private var locale
    let original: RoutingRule?
    /// The subscription's groups, in its order.
    let groups: [String]
    let tunnelMode: TunnelMode
    let save: (RoutingRule) -> Void
    let cancel: () -> Void

    @State private var kind: RoutingRule.Kind
    @State private var value: String
    @State private var target: String
    @State private var priority: RoutingRule.Priority
    @State private var invalid: RoutingRule.Invalid?
    @State private var choosingKind = false
    @State private var choosingApp = false

    init(original: RoutingRule?, groups: [String], tunnelMode: TunnelMode,
         save: @escaping (RoutingRule) -> Void, cancel: @escaping () -> Void) {
        self.original = original
        self.groups = groups
        self.tunnelMode = tunnelMode
        self.save = save
        self.cancel = cancel
        _kind = State(initialValue: original?.kind ?? .domainSuffix)
        _value = State(initialValue: original?.value ?? "")
        _target = State(initialValue: original?.target ?? RoutingRule.direct)
        _priority = State(initialValue: original?.priority ?? .override)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            palette.hairlineSoft.frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                field(L.t(.ruleType, locale)) {
                    typePicker
                    if kind.needsDownload { downloadNote }
                }
                field(L.t(.ruleValue, locale)) { valueField }
                field(L.t(.ruleTarget, locale)) { targetList }
                field(L.t(.rulePriority, locale)) { priorityChoice }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            palette.hairlineSoft.frame(height: 1)
            footer
        }
        .frame(width: 480)
    }

    // MARK: - Parts

    private var header: some View {
        HStack {
            Text(L.t(original == nil ? .rulesAdd : .rulesEdit, locale))
                .font(.mlDisplay(17))
                .tracking(TypeScale.trackDisplay * 17)
                .foregroundStyle(palette.text)
            Spacer()
            Button(action: cancel) {
                IconView(.x, size: 16)
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .pressIcon()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.ml(12.5, .bold))
                .foregroundStyle(palette.text2)
            content()
        }
    }

    /// A popover rather than a `Menu`: macOS draws a menu's label as plain
    /// text whatever view it is given, so the field lost its look.
    private var typePicker: some View {
        Button {
            choosingKind.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(kind.rawValue)
                    .font(.mlMono(13, .semibold))
                    .foregroundStyle(palette.text)
                if kind.needsProcessMatching {
                    Text("TUN")
                        .font(.ml(9.5, .heavy))
                        .foregroundStyle(tunnelMode == .tun ? palette.textMuted : palette.warning)
                        .help(L.t(.ruleTunOnly, locale))
                }
                Spacer(minLength: 8)
                IconView(.chevronRight, size: 13, strokeWidth: 2.4)
                    .rotationEffect(.degrees(choosingKind ? -90 : 90))
                    .foregroundStyle(palette.textMuted)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .mlGlass(.rounded(Radii.field), fallback: palette.surface2)
            .contentShape(Rectangle())
        }
        .pressCard()
        .animation(Motion.paint, value: choosingKind)
        .popover(isPresented: $choosingKind, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(RoutingRule.Kind.Family.allCases, id: \.self) { family in
                        sectionLabel(L.family(family, locale))
                            .padding(.top, family == .domain ? 0 : 6)
                        ForEach(RoutingRule.Kind.allCases.filter { $0.family == family }, id: \.self) { option in
                            listRow(option.rawValue, mono: true, selected: option == kind) {
                                kind = option
                                invalid = nil
                                choosingKind = false
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: 340, height: 360)
            .environment(\.palette, palette)
            .environment(\.liquidGlass, liquidGlass)
            .mlLocale(locale)
        }
    }

    /// A rule of this kind has the core download a database before it loads:
    /// once, and not at all where the download is blocked. Said here, before
    /// the rule is added, rather than only as an apply that fails afterwards.
    private var downloadNote: some View {
        Text(L.t(.ruleNeedsDownload, locale))
            .font(.ml(12))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A row in one of the editor's dropdowns.
    private func listRow(_ title: String, mono: Bool, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(mono ? .mlMono(13, selected ? .semibold : .regular) : .ml(13, selected ? .bold : .medium))
                    .foregroundStyle(selected ? palette.text : palette.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    IconView(.check, size: 13, strokeWidth: 2.6).foregroundStyle(palette.accentInk)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.text.opacity(selected ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .pressCard()
    }

    private var valueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(kind.placeholder, text: $value)
                    .textFieldStyle(.plain)
                    .font(.mlMono(13))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .mlGlass(.rounded(Radii.field), fallback: palette.surface2)
                    .onChange(of: value) { _ in invalid = nil }
                    .onSubmit(commit)
                if kind.needsProcessMatching { appPicker }
            }
            if let invalid {
                Text(L.invalid(invalid, locale))
                    .font(.ml(12))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fills a process rule's value from an app: its executable, its path, or
    /// a pattern for either — so nobody has to know what a bundle's binary is
    /// called.
    private var appPicker: some View {
        Button {
            choosingApp.toggle()
        } label: {
            IconView(.layers, size: 16)
                .foregroundStyle(palette.text)
                .frame(width: 40, height: 40)
                .mlGlass(.rounded(Radii.field), fallback: palette.surface2)
                .contentShape(Rectangle())
        }
        .pressIcon()
        .help(L.t(.ruleChooseApp, locale))
        .popover(isPresented: $choosingApp, arrowEdge: .bottom) {
            AppChooser { app in
                pick(app)
                choosingApp = false
            }
            .environment(\.palette, palette)
            .environment(\.liquidGlass, liquidGlass)
            .mlLocale(locale)
        }
    }

    private var targetList: some View {
        let known = [RoutingRule.direct, RoutingRule.reject] + groups
        // A rule whose group has since gone from the subscription still shows
        // where it pointed.
        let lost = known.contains(target) ? nil : target
        let list = VStack(alignment: .leading, spacing: 2) {
                sectionLabel(L.t(.targetBuiltIn, locale))
                targetRow(RoutingRule.direct, note: L.t(.targetDirect, locale), dot: palette.stUpInk)
                targetRow(RoutingRule.reject, note: L.t(.targetReject, locale), dot: palette.danger)
                if !groups.isEmpty || lost != nil {
                    sectionLabel(L.t(.targetGroups, locale)).padding(.top, 6)
                    ForEach(groups, id: \.self) { group in
                        targetRow(group, note: nil, dot: palette.accentInk)
                    }
                    if let lost {
                        targetRow(lost, note: L.t(.targetMissing, locale), dot: palette.danger)
                    }
                }
            }
            .padding(8)
        // Its own height while it fits; past that it scrolls, with the
        // scroller showing, so groups under the fold are not taken for absent.
        return Group {
            if #available(macOS 13.0, *) {
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView { list }.scrollIndicators(.visible)
                }
            } else {
                ScrollView { list }
            }
        }
        .frame(maxHeight: 184)
        .mlGlass(.rounded(Radii.card), fallback: palette.surface)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ml(10.5, .heavy))
            .tracking(0.08 * 10.5)
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func targetRow(_ name: String, note: String?, dot: Color) -> some View {
        let selected = target == name
        return Button {
            target = name
        } label: {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(name)
                    .font(.ml(13.5, selected ? .bold : .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.ml(12))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(1)
                }
                if selected {
                    IconView(.check, size: 14, strokeWidth: 2.6).foregroundStyle(palette.accentInk)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if selected {
                    Color.clear.mlSoftGlass(RoundedRectangle(cornerRadius: 10, style: .continuous),
                                            wash: palette.text.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .pressCard()
        .animation(Motion.paint, value: selected)
    }

    /// Side by side, as tall as the taller of the two: stacked, they made the
    /// sheet taller than the window it hangs from.
    private var priorityChoice: some View {
        HStack(spacing: 8) {
            priorityCard(.override, title: L.t(.priorityOverride, locale),
                         note: L.t(.priorityOverrideSub, locale))
            priorityCard(.extend, title: L.t(.priorityExtend, locale),
                         note: L.t(.priorityExtendSub, locale))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func priorityCard(_ option: RoutingRule.Priority, title: String, note: String) -> some View {
        let selected = priority == option
        return Button {
            priority = option
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? palette.accent : palette.hairline, lineWidth: 2)
                    if selected { Circle().fill(palette.accent).padding(5) }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ml(14, .bold)).foregroundStyle(palette.text)
                    Text(note)
                        .font(.ml(11.5))
                        .foregroundStyle(palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxHeight: .infinity)
            .mlGlass(.rounded(Radii.card),
                     tint: selected ? palette.accent.opacity(0.1) : nil,
                     fallback: selected ? palette.accentQuiet : palette.surface)
            .contentShape(Rectangle())
        }
        .pressCard()
        .animation(Motion.paint, value: selected)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: cancel) {
                Text(L.t(.ruleCancel, locale))
                    .font(.ml(13, .heavy))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .pressButton()
            .keyboardShortcut(.cancelAction)
            Button(action: commit) {
                Text(L.t(original == nil ? .rulesAdd : .ruleSave, locale))
                    .font(.ml(13, .heavy))
                    .foregroundStyle(palette.textOnAccent)
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                    .mlGlass(.capsule, tint: palette.accent, fallback: palette.accent)
            }
            .pressButton()
            .keyboardShortcut(.defaultAction)
            .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(value.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Actions

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = RoutingRule.validate(kind: kind, value: trimmed) {
            invalid = problem
            return
        }
        save(RoutingRule(id: original?.id ?? UUID(), kind: kind, value: trimmed, target: target,
                         priority: priority, enabled: original?.enabled ?? true))
    }

    private func pick(_ app: AppEntry) {
        let binary = "\(app.path)/Contents/MacOS/\(app.executable)"
        switch kind {
        case .processName: value = app.executable
        case .processPath: value = binary
        case .processNameRegex:
            value = "(?i)^\(NSRegularExpression.escapedPattern(for: app.executable))$"
        case .processPathRegex:
            // Everything inside the bundle, helpers included.
            value = "(?i)^\(NSRegularExpression.escapedPattern(for: app.path))/.*"
        default: break
        }
    }

}

/// The apps a process rule can be filled from: what is running, then what is
/// installed, with a filter.
///
/// A view of its own, owning its list and loading it when it opens. The list
/// used to live in the editor and be drawn in the popover from there; the
/// popover is a window of its own, never saw the list arrive, and spun for
/// good. The installed list is kept once read — scanning the application
/// folders opens every bundle in them.
private struct AppChooser: View {
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    let pick: (AppEntry) -> Void

    @MainActor private static var installedCache: [AppEntry]?

    @State private var running: [AppEntry] = []
    @State private var installed: [AppEntry]? = AppChooser.installedCache
    @State private var query = ""

    private func matching(_ apps: [AppEntry]) -> [AppEntry] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(text) || $0.executable.lowercased().contains(text) }
    }

    var body: some View {
        let live = matching(running)
        let liveNames = Set(running.map(\.executable))
        let rest = matching((installed ?? []).filter { !liveNames.contains($0.executable) })
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconView(.search, size: 14).foregroundStyle(palette.textMuted)
                TextField(L.t(.searchApps, locale), text: $query)
                    .textFieldStyle(.plain)
                    .font(.ml(13))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .mlGlass(.capsule, fallback: palette.surface2)
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !live.isEmpty {
                        heading(L.t(.ruleRunning, locale).uppercased())
                        ForEach(live) { row($0) }
                    }
                    if !rest.isEmpty {
                        heading(L.t(.installedApps, locale)).padding(.top, live.isEmpty ? 0 : 6)
                        ForEach(rest) { row($0) }
                    }
                    if installed == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                    } else if live.isEmpty, rest.isEmpty {
                        Text(L.t(.nothingFound, locale))
                            .font(.ml(12.5))
                            .foregroundStyle(palette.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(20)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 320, height: 400)
        .task {
            running = AppInventory.runningApps()
            guard installed == nil else { return }
            let found = await Task.detached(priority: .userInitiated) { AppInventory.installed() }.value
            Self.installedCache = found
            installed = found
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.ml(10.5, .heavy))
            .tracking(0.08 * 10.5)
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }

    private func row(_ app: AppEntry) -> some View {
        Button {
            pick(app)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text(app.name)
                    .font(.ml(13, .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(app.executable)
                    .font(.mlMono(11))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .pressCard()
    }
}
