//
//  PickyConversationDateDivider.swift
//  Picky
//
//  Messenger-style day separator. Replaces the per-request chapter headers
//  ("최근 요청 · 2분 12초") in the Pickle conversation.
//  Design: design/proposals/messenger-ux-2026-10.md §2-3.
//

import SwiftUI

enum PickyConversationDateDividerPolicy {
    /// IDs of the first message of each calendar day, in the given order.
    static func messageIDsStartingDay(
        _ messages: [(id: String, createdAt: Date)],
        calendar: Calendar = .current
    ) -> Set<String> {
        var result = Set<String>()
        var previousDay: Date?
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day != previousDay { result.insert(message.id) }
            previousDay = day
        }
        return result
    }

    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("hud.conversation.dateDivider.today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.t("hud.conversation.dateDivider.yesterday")
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted)
            .month(.wide).day().weekday(.abbreviated)
            .locale(LocaleManager.nonisolatedEffectiveLocale)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}

struct PickyConversationDateDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: DS.Spacing.space2) {
            line
            Text(title)
                .font(PickyHUDTypography.metaMedium)
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize()
            line
        }
        .padding(.vertical, DS.Spacing.space2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }

    private var line: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
