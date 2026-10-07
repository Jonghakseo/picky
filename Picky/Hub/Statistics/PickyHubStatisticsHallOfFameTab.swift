//
//  PickyHubStatisticsHallOfFameTab.swift
//  Picky
//
//  Pickle 명예의 전당 tab: what Pickles produced, and the all-time leader
//  for each kind of effort. Uses the whole snapshot, never the page filter.
//

import SwiftUI

struct PickyHubStatisticsHallOfFameTab: View {
    let snapshot: PickyHubStatisticsSnapshot
    let canOpen: (String) -> Bool
    let onOpen: (String) -> Void
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let fame = PickyHubHallOfFamePolicy.hallOfFame(records: snapshot.records)
        if fame.awards.isEmpty && fame.allTime.isEmpty {
            PickyHubEmptyState(
                systemImage: "trophy",
                title: "hub.stats.fame.empty.title",
                message: "hub.stats.fame.empty.message"
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PickyHubSubsectionTitle(title: "hub.stats.fame.totals.title")
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field, alignment: .top),
                    count: PickyHubGridPolicy.columnCount(for: contentWidth / fontScale, maximum: 4, spacing: PickyHubTheme.Spacing.field)
                )
                LazyVGrid(columns: columns, spacing: PickyHubTheme.Spacing.field) {
                    total("hub.stats.fame.totals.changedFiles", fame.allTime.changedFiles, thisMonth: fame.thisMonth.changedFiles)
                    total("hub.stats.fame.totals.artifacts", fame.allTime.artifacts, thisMonth: fame.thisMonth.artifacts)
                    total("hub.stats.fame.totals.toolCalls", fame.allTime.toolCalls, thisMonth: fame.thisMonth.toolCalls)
                    total("hub.stats.fame.totals.subagents", fame.allTime.subagents, thisMonth: fame.thisMonth.subagents)
                }
                Text("hub.stats.fame.totals.caption")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .pickyHubSelectableText()
                    .padding(.top, PickyHubTheme.Spacing.related)
                if !fame.awards.isEmpty {
                    PickyHubSubsectionTitle(title: "hub.stats.fame.awards.title")
                        .padding(.top, PickyHubTheme.Spacing.group)
                    VStack(spacing: 0) {
                        ForEach(fame.awards) { award in
                            PickyHubAwardRow(
                                award: award,
                                onOpen: canOpen(award.record.id) ? { onOpen(award.record.id) } : nil
                            )
                            if award.id != fame.awards.last?.id {
                                Divider().overlay(PickyHubTheme.Colors.borderSoft)
                            }
                        }
                    }
                    .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
                    .pickyHubCard()
                }
            }
        }
    }

    private func total(_ label: LocalizedStringKey, _ value: Int, thisMonth: Int) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(label)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            Text(verbatim: PickyHubHallOfFamePresentation.count(value))
                .pickyFont(size: 28, weight: .semibold)
                .tracking(-1)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L10n.t("hub.stats.fame.totals.thisMonth", PickyHubHallOfFamePresentation.count(thisMonth)))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard()
        .accessibilityElement(children: .combine)
        .pickyHubSelectableText()
    }
}

private struct PickyHubAwardRow: View {
    let award: PickyHubAward
    let onOpen: (() -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: PickyHubTheme.Spacing.field) {
            Text(Image(systemName: award.kind.systemImage))
                .pickyFont(size: 15, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.action)
                .frame(width: 36, height: 36)
                .background(Circle().fill(PickyHubTheme.Colors.actionTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PickyHubHallOfFamePresentation.title(award.kind))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                Text(verbatim: award.record.title)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .help(award.record.title)
                Text(verbatim: "\(award.record.project) · \(award.record.createdAt.formatted(.dateTime.month().day().locale(locale)))")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .pickyHubSelectableText()
            Spacer(minLength: PickyHubTheme.Spacing.field)
            PickyHubBadgePill(text: PickyHubHallOfFamePresentation.value(award))
            if let onOpen {
                PickyHubTextLink(title: "hub.stats.fame.open", action: onOpen)
                    .accessibilityLabel(Text(L10n.t("hub.stats.fame.open.accessibility", award.record.title)))
            }
        }
        .frame(minHeight: 72)
    }
}

enum PickyHubHallOfFamePresentation {
    static func count(_ value: Int) -> String {
        value >= 100_000 ? PickyHubTokenFormatter.string(value) : value.formatted()
    }

    static func title(_ kind: PickyHubAwardKind) -> String {
        switch kind {
        case .longestWork: L10n.t("hub.stats.fame.award.longestWork")
        case .mostChangedFiles: L10n.t("hub.stats.fame.award.mostChangedFiles")
        case .mostSubagents: L10n.t("hub.stats.fame.award.mostSubagents")
        case .mostFollowUps: L10n.t("hub.stats.fame.award.mostFollowUps")
        case .mostTokens: L10n.t("hub.stats.fame.award.mostTokens")
        }
    }

    static func value(_ award: PickyHubAward) -> String {
        switch award.kind {
        case .longestWork: duration(milliseconds: award.value)
        case .mostChangedFiles: L10n.t("hub.stats.fame.value.files", award.value)
        case .mostSubagents: L10n.t("hub.stats.fame.value.subagents", award.value)
        case .mostFollowUps: L10n.t("hub.stats.fame.value.followUps", award.value)
        case .mostTokens: L10n.t("hub.stats.fame.value.tokens", PickyHubTokenFormatter.string(award.value))
        }
    }

    static func duration(milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        if minutes < 1 { return L10n.t("hub.stats.fame.value.underMinute") }
        if minutes < 60 { return L10n.t("hub.stats.fame.value.minutes", minutes) }
        return L10n.t("hub.stats.fame.value.hoursMinutes", minutes / 60, minutes % 60)
    }
}
