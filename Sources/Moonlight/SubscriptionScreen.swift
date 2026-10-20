import SwiftUI
import AppKit
import MoonlightDesign
import MoonlightCore

struct SubscriptionScreen: View {
    @EnvironmentObject var tunnel: TunnelController
    @Environment(\.palette) private var palette
    @Environment(\.appLocale) private var locale
    @Binding var page: Page

    var body: some View {
        PageScroll {
            VStack(spacing: 14) {
                if let announce = tunnel.info.announce {
                    AnnounceBanner(text: announce)
                }
                columns
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 14) {
                planCard
                trafficCard
            }
            VStack(spacing: 14) {
                refreshRow
                actionRows
            }
            .frame(width: 360)
        }
    }

    // MARK: - Plan

    private var planCard: some View {
        // The one inverted surface in the app: the plan, white on black.
        VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t(.plan, locale))
                            .font(.ml(TypeScale.meta, .heavy))
                            .opacity(0.6)
                        Text(tunnel.info.title ?? L.t(.planUnknown, locale))
                            .font(.mlDisplay(32))
                            .tracking(TypeScale.trackDisplay * 32)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(L.t(tunnel.info.isActive ? .active : .expired, locale))
                        .font(.ml(TypeScale.micro, .heavy))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(palette.inkWash)
                        .clipShape(Capsule())
                }

                HStack(spacing: 10) {
                    heroStat(L.t(.remainingCaps, locale),
                             Format.days(tunnel.info.daysLeft, locale: locale))
                    heroStat(L.t(.traffic, locale),
                             Format.bytes(tunnel.info.used, locale: locale))
                }
                .padding(.top, 22)
            }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .foregroundStyle(palette.textOnAccent)
        .clipShape(RoundedRectangle(cornerRadius: Radii.panel, style: .continuous))
        .mlGlass(.rounded(Radii.panel), tint: palette.accent, fallback: palette.accent)
    }

    private func heroStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.ml(10.5, .heavy))
                .tracking(0.06 * 10.5)
                .opacity(0.65)
            Text(value)
                .font(.mlDisplay(18))
                .tracking(TypeScale.trackDisplay * 18)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Traffic

    private var trafficCard: some View {
        Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Overline(text: L.t(.trafficCaps, locale))
                    Spacer()
                    Text(Format.quota(used: tunnel.info.used,
                                      total: tunnel.info.total, locale: locale))
                        .font(.ml(TypeScale.meta, .bold))
                        .foregroundStyle(palette.text2)
                }
                QuotaBar(used: tunnel.info.usedFraction).padding(.top, 14)
                Text(expiryLine)
                    .font(.ml(TypeScale.meta))
                    .foregroundStyle(palette.textMuted)
                    .padding(.top, 12)
                if let refill = tunnel.info.refillDate {
                    Text("\(L.t(.trafficResets, locale)) \(Format.date(refill, locale: locale))")
                        .font(.ml(TypeScale.meta))
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var expiryLine: String {
        guard let expire = tunnel.info.expire else { return Format.days(nil, locale: locale) }
        return "\(L.t(.validUntil, locale)) \(Format.date(expire, locale: locale))"
    }

    // MARK: - Actions

    private var refreshRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            refreshCard
            if let issue = tunnel.issue {
                IssueLine(issue: issue).padding(.horizontal, 6)
            }
        }
    }

    private var refreshCard: some View {
        RowGroup {
            ActionRow(
                icon: .refreshCW,
                fill: palette.cat1,
                title: L.t(.refreshSubscription, locale),
                subtitle: refreshMeta,
                trailing: nil,
                spinning: tunnel.isRefreshing
            ) {
                // A second press stops a refresh that is taking too long.
                if tunnel.canStopRefresh {
                    tunnel.cancelRefresh()
                } else {
                    Task { await tunnel.refresh() }
                }
            }
        }
    }

    private var refreshMeta: String {
        if tunnel.canStopRefresh { return L.t(.refreshMetaStop, locale) }
        if tunnel.isRefreshing { return L.t(.refreshMetaSyncing, locale) }
        if let last = tunnel.lastRefresh {
            return "\(L.t(.lastUpdated, locale)) \(L.ago(last, locale))"
        }
        return L.t(.refreshMetaIdle, locale)
    }

    private var actionRows: some View {
        RowGroup {
            ActionRow(
                icon: .sparkles,
                fill: palette.cat2,
                title: L.t(.extendSubscription, locale),
                subtitle: L.t(.extendSubtitle, locale),
                trailing: .externalLink
            ) {
                // Always the bot: it is where a plan is paid for. The page a
                // subscription names for itself shows the plan, and sent people
                // looking for a way to pay that is not there.
                NSWorkspace.shared.open(AppConfig.telegramBotURL)
            }
            RowDivider(leading: 74)
            ActionRow(
                icon: .circleUser,
                fill: palette.cat3,
                title: L.t(.personalAccount, locale),
                subtitle: L.t(.personalAccountSub, locale),
                trailing: .externalLink
            ) {
                NSWorkspace.shared.open(AppConfig.cabinetURL)
            }
            // One subscription at a time: importing replaces it, so offering
            // to *add* one beside an active plan promised something the app
            // does not do. Removing it brings the row back.
            if !tunnel.hasSubscription {
                RowDivider(leading: 74)
                ActionRow(
                    icon: .plus,
                    fill: palette.cat4,
                    title: L.t(.addSubscriptionRow, locale),
                    subtitle: L.t(.addSubscriptionSubtitle, locale)
                ) {
                    page = .importSubscription
                }
            }
            if tunnel.hasSubscription {
                RowDivider(leading: 74)
                ActionRow(
                    icon: .trash2,
                    fill: palette.cat5,
                    title: L.t(.removeSubscription, locale),
                    // Never the link itself: it is a credential, and anyone
                    // who reads it off the screen has the subscription.
                    subtitle: L.t(.removeSubscriptionSub, locale),
                    trailing: nil
                ) {
                    Task { await tunnel.removeSubscription() }
                }
            }
        }
    }

}
