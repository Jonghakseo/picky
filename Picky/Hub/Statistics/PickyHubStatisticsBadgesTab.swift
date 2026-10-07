//
//  PickyHubStatisticsBadgesTab.swift
//  Picky
//
//  배지 tab. Badges are derived from the whole snapshot, so the page filter
//  never hides one. The statistics store also remembers earned badges, so a
//  badge stays earned when later history no longer proves it.
//

import SwiftUI

struct PickyHubStatisticsBadgesTab: View {
    let snapshot: PickyHubStatisticsSnapshot
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let board = PickyHubBadgePolicy.board(snapshot: snapshot, earned: statisticsStore.earnedBadges)
        let columnCount = contentWidth / fontScale >= 640 ? 4 : (contentWidth / fontScale >= 420 ? 3 : 2)
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubBadgeBanner(board: board)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field, alignment: .top), count: columnCount),
                spacing: PickyHubTheme.Spacing.field
            ) {
                ForEach(board.badges) { PickyHubBadgeTile(badge: $0) }
            }
        }
    }
}

private struct PickyHubBadgeBanner: View {
    let board: PickyHubBadgeBoard

    var body: some View {
        HStack(spacing: PickyHubTheme.Spacing.field) {
            Text(Image(systemName: highlighted?.kind.systemImage ?? "rosette"))
                .pickyFont(size: 18, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textOnAction)
                .frame(width: 40, height: 40)
                .background(Circle().fill(PickyHubTheme.Colors.action))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(verbatim: detail)
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: PickyHubTheme.Spacing.related)
            Text(L10n.t("hub.stats.badges.count", board.badges.count, board.earnedCount))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize()
        }
        .padding(PickyHubTheme.Spacing.field)
        .background(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous).fill(PickyHubTheme.Colors.actionTint))
        .overlay(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.card, style: .continuous).stroke(PickyHubTheme.Colors.action.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .pickyHubSelectableText()
    }

    private var highlighted: PickyHubBadge? { board.recentlyEarned ?? board.nextGoal }

    private var title: String {
        if let recent = board.recentlyEarned {
            return L10n.t("hub.stats.badges.recent", PickyHubBadgePresentation.name(recent.kind))
        }
        if let next = board.nextGoal {
            return L10n.t("hub.stats.badges.next.title", PickyHubBadgePresentation.name(next.kind))
        }
        return L10n.t("hub.stats.badges.allEarned")
    }

    private var detail: String? {
        guard let next = board.nextGoal else { return nil }
        let progress = PickyHubBadgePresentation.progress(next)
        if board.recentlyEarned != nil {
            return L10n.t("hub.stats.badges.next.detail", PickyHubBadgePresentation.name(next.kind), progress)
        }
        return "\(PickyHubBadgePresentation.rule(next.kind)) · \(progress)"
    }
}

private struct PickyHubBadgeTile: View {
    let badge: PickyHubBadge
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: PickyHubTheme.Spacing.related) {
            Text(Image(systemName: badge.kind.systemImage))
                .pickyFont(size: 24, weight: .semibold)
                .foregroundColor(badge.isEarned ? PickyHubTheme.Colors.textOnAction : PickyHubTheme.Colors.textTertiary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(badge.isEarned ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.barTrack))
                .overlay(Circle().stroke(badge.isEarned ? PickyHubTheme.Colors.action.opacity(0.3) : .clear, lineWidth: 4).padding(-4))
                .padding(.top, DS.Spacing.space1)
                .accessibilityHidden(true)
            Text(verbatim: PickyHubBadgePresentation.name(badge.kind))
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(badge.isEarned ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Text(verbatim: PickyHubBadgePresentation.rule(badge.kind))
                .pickyFont(size: 11, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let earnedAt = badge.earnedAt {
                Text(verbatim: PickyHubBadgePresentation.earnedDescription(earnedAt, locale: locale))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.action)
            } else {
                VStack(spacing: DS.Spacing.space1) {
                    PickyHubProgressBar(fraction: badge.fraction, height: 5)
                    Text(verbatim: PickyHubBadgePresentation.progress(badge))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .monospacedDigit()
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
            }
        }
        .padding(PickyHubTheme.Spacing.field)
        .frame(maxWidth: .infinity, minHeight: 186)
        .pickyHubCard()
        .accessibilityElement(children: .combine)
        .pickyHubSelectableText()
    }
}

enum PickyHubBadgePresentation {
    static func name(_ kind: PickyHubBadgeKind) -> String {
        switch kind {
        case .firstPickle: L10n.t("hub.stats.badge.firstPickle.name")
        case .weekStreak: L10n.t("hub.stats.badge.weekStreak.name")
        case .nightOwl: L10n.t("hub.stats.badge.nightOwl.name")
        case .millionTokens: L10n.t("hub.stats.badge.millionTokens.name")
        case .busyDay: L10n.t("hub.stats.badge.busyDay.name")
        case .noFollowUp: L10n.t("hub.stats.badge.noFollowUp.name")
        case .explorer: L10n.t("hub.stats.badge.explorer.name")
        case .monthStreak: L10n.t("hub.stats.badge.monthStreak.name")
        }
    }

    static func rule(_ kind: PickyHubBadgeKind) -> String {
        switch kind {
        case .firstPickle: L10n.t("hub.stats.badge.firstPickle.rule")
        case .weekStreak: L10n.t("hub.stats.badge.weekStreak.rule")
        case .nightOwl: L10n.t("hub.stats.badge.nightOwl.rule")
        case .millionTokens: L10n.t("hub.stats.badge.millionTokens.rule")
        case .busyDay: L10n.t("hub.stats.badge.busyDay.rule")
        case .noFollowUp: L10n.t("hub.stats.badge.noFollowUp.rule")
        case .explorer: L10n.t("hub.stats.badge.explorer.rule")
        case .monthStreak: L10n.t("hub.stats.badge.monthStreak.rule")
        }
    }

    static func progress(_ badge: PickyHubBadge) -> String {
        if badge.kind == .millionTokens {
            return "\(PickyHubTokenFormatter.string(badge.progress)) / \(PickyHubTokenFormatter.string(badge.kind.target))"
        }
        return "\(badge.progress) / \(badge.kind.target)"
    }

    static func earnedDescription(_ date: Date, locale: Locale, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return L10n.t("hub.stats.badges.earnedToday") }
        return L10n.t("hub.stats.badges.earned", date.formatted(.dateTime.month().day().locale(locale)))
    }
}
