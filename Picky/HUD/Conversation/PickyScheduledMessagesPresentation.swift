//
//  PickyScheduledMessagesPresentation.swift
//  Picky
//
//  Pure projection for the "scheduled messages" surface above the composer.
//  Two sources feed it: queued follow-ups (delivered when the current reply
//  ends) and delayed-action timed messages. Design: build/render-gallery
//  /steer-followup/11-scheduled-collapsed, 12-scheduled-expanded.
//

import Foundation

/// One row in the scheduled surface. `followUp` rows are addressed by
/// `PickyQueueItem.id`, `timed` rows by `PickyScheduledMessage.id`.
struct PickyScheduledMessageRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case followUp
        case timed
    }

    let id: String
    let kind: Kind
    let text: String
    /// Absolute send time. `nil` for follow-ups, which have no clock.
    let dueAt: Date?
    /// False for a queue entry an older daemon sent without an id: it can be
    /// listed, but no per-item command can address it, so it shows no toolbar.
    let isActionable: Bool

    init(id: String, kind: Kind, text: String, dueAt: Date?, isActionable: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.dueAt = dueAt
        self.isActionable = isActionable
    }
}

struct PickyScheduledMessageGroup: Identifiable, Equatable {
    let id: String
    /// Relative, coarse heading: "이번 응답이 끝나면", "5분 후", "2일 후".
    let title: String
    /// Absolute send time, shown next to the heading. `nil` for follow-ups.
    let detail: String?
    let rows: [PickyScheduledMessageRow]
}

struct PickyScheduledMessagesPresentation: Equatable {
    let groups: [PickyScheduledMessageGroup]

    /// Follow-ups keep queue order; timed messages are grouped by the minute
    /// they are due so "send both of these in 5 minutes" reads as one block.
    init(
        followUps: [PickyQueueItem],
        scheduledMessages: [PickyScheduledMessage],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = LocaleManager.nonisolatedEffectiveLocale
    ) {
        var groups: [PickyScheduledMessageGroup] = []
        if !followUps.isEmpty {
            groups.append(
                PickyScheduledMessageGroup(
                    id: "follow-up",
                    title: L10n.t("hud.scheduled.group.afterCurrentReply"),
                    detail: nil,
                    rows: followUps.enumerated().map { index, item in
                        PickyScheduledMessageRow(
                            id: item.id ?? "follow-up-\(index)",
                            kind: .followUp,
                            text: item.userFacingText,
                            dueAt: nil,
                            isActionable: item.id != nil
                        )
                    }
                )
            )
        }

        var bucketOrder: [Date] = []
        var buckets: [Date: [PickyScheduledMessage]] = [:]
        for message in scheduledMessages.sorted(by: { $0.dueAt < $1.dueAt }) {
            let minute = Self.minuteBucket(message.dueAt, calendar: calendar)
            if buckets[minute] == nil {
                buckets[minute] = []
                bucketOrder.append(minute)
            }
            buckets[minute]?.append(message)
        }
        for minute in bucketOrder {
            let messages = buckets[minute] ?? []
            guard let first = messages.first else { continue }
            groups.append(
                PickyScheduledMessageGroup(
                    id: "timed-\(minute.timeIntervalSince1970)",
                    title: Self.relativeTitle(from: now, to: first.dueAt),
                    detail: Self.absoluteDetail(for: first.dueAt, now: now, calendar: calendar, locale: locale),
                    rows: messages.map {
                        PickyScheduledMessageRow(id: $0.id, kind: .timed, text: $0.text, dueAt: $0.dueAt)
                    }
                )
            )
        }
        self.groups = groups
    }

    init(groups: [PickyScheduledMessageGroup]) {
        self.groups = groups
    }

    static let empty = PickyScheduledMessagesPresentation(groups: [])

    /// `now` truncated to the minute. Group headings are minute-coarse anyway, so
    /// this keeps the presentation equal between keystrokes instead of producing a
    /// new value (and a new diff) on every render.
    static func currentMinute(_ date: Date = Date(), calendar: Calendar = .current) -> Date {
        minuteBucket(date, calendar: calendar)
    }

    var totalCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
    var isVisible: Bool { totalCount > 0 }
    var rows: [PickyScheduledMessageRow] { groups.flatMap(\.rows) }

    /// Collapsed line: always one line, whatever the count.
    var summaryText: String {
        L10n.t("hud.scheduled.summary", Int64(totalCount))
    }

    var nextGroupTitle: String? { groups.first?.title }

    var nextText: String? {
        nextGroupTitle.map { L10n.t("hud.scheduled.summary.next", $0) }
    }

    var accessibilityValue: String {
        guard let nextGroupTitle else { return summaryText }
        return L10n.t("hud.scheduled.summary.accessibilityValue", Int64(totalCount), nextGroupTitle)
    }

    func row(id: String) -> PickyScheduledMessageRow? {
        rows.first { $0.id == id }
    }

    private static func minuteBucket(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Coarse single-unit relative heading. Anything under a minute reads as
    /// "soon" rather than a second count that is stale by the time it renders.
    static func relativeTitle(from now: Date, to dueAt: Date) -> String {
        let seconds = dueAt.timeIntervalSince(now)
        guard seconds >= 60 else { return L10n.t("hud.scheduled.relative.soon") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return L10n.t("hud.scheduled.relative.minutes", Int64(minutes)) }
        let hours = minutes / 60
        if hours < 24 { return L10n.t("hud.scheduled.relative.hours", Int64(hours)) }
        return L10n.t("hud.scheduled.relative.days", Int64(hours / 24))
    }

    /// Time only on the same day, date plus weekday otherwise.
    static func absoluteDetail(
        for dueAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = LocaleManager.nonisolatedEffectiveLocale
    ) -> String {
        let time = dueAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        guard !calendar.isDate(dueAt, inSameDayAs: now) else { return time }
        // Month/day/weekday only: the year never helps for a send time the user
        // just picked, and it pushes the row into truncation.
        let day = dueAt.formatted(
            Date.FormatStyle().locale(locale).month(.abbreviated).day().weekday(.abbreviated)
        )
        return "\(day) \(time)"
    }
}
