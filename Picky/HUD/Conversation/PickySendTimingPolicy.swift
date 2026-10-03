//
//  PickySendTimingPolicy.swift
//  Picky
//
//  "보낼 시점" menu behind the composer's split send button. Design:
//  build/render-gallery/steer-followup/9-send-menu, 10-send-menu-no-plugin.
//

import Foundation

enum PickySendTiming: Equatable, Identifiable, Hashable {
    /// Today's follow-up: delivered as soon as the current reply ends.
    case afterCurrentReply
    /// Delayed-action timed send, relative to the moment it is picked.
    case delay(seconds: Int)
    /// Delayed-action timed send at a wall-clock time ("tomorrow 9:00", custom).
    case at(Date)
    /// Opens the custom date/time editor instead of sending.
    case custom

    var id: String {
        switch self {
        case .afterCurrentReply: "after-current-reply"
        case .delay(let seconds): "delay-\(seconds)"
        case .at(let date): "at-\(Int(date.timeIntervalSince1970))"
        case .custom: "custom"
        }
    }

    /// Delay for the daemon's `scheduleMessage`, measured when the row is picked
    /// so a menu left open does not shift an absolute time. `nil` for rows that
    /// do not schedule. An absolute time that has just passed still sends
    /// (after one second) rather than being dropped.
    func delayMilliseconds(now: Date = Date()) -> Int? {
        switch self {
        case .afterCurrentReply, .custom: nil
        case .delay(let seconds): seconds * 1000
        case .at(let date): max(1000, Int((date.timeIntervalSince(now) * 1000).rounded()))
        }
    }
}

struct PickySendTimingOption: Equatable, Identifiable {
    let timing: PickySendTiming
    let title: String
    /// Absolute send time for timed rows; `nil` for the follow-up row.
    let detail: String?
    /// Keyboard equivalent hint; only the follow-up row has one.
    let shortcut: String?
    let isEnabled: Bool
    /// Tooltip for a row that is disabled for a reason the menu does not already
    /// spell out. The missing-plugin case has its own install affordance instead.
    let disabledReason: String?

    var id: String { timing.id }

    init(
        timing: PickySendTiming,
        title: String,
        detail: String?,
        shortcut: String?,
        isEnabled: Bool,
        disabledReason: String? = nil
    ) {
        self.timing = timing
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

enum PickySendTimingPolicy {
    /// Relative presets; "tomorrow at 9:00" and the custom row follow them.
    static let presetDelays: [Int] = [5 * 60, 60 * 60]
    static let tomorrowPresetHour = 9

    /// The chevron is inert while a scheduled message is being edited: picking a
    /// send time there would create a second message instead of saving the edit.
    static func isMenuEnabled(isSendEnabled: Bool, isEditingScheduledMessage: Bool) -> Bool {
        isSendEnabled && !isEditingScheduledMessage
    }

    /// `isPluginInstalled == false` keeps the timed rows visible but disabled so
    /// the menu explains what is missing instead of hiding the capability.
    /// `carriesScreenContext` disables them too: a timed message is stored as
    /// plain text, so attachments and armed screen context cannot ride along.
    static func options(
        now: Date = Date(),
        canSendAfterCurrentReply: Bool,
        isPluginInstalled: Bool,
        carriesScreenContext: Bool = false,
        calendar: Calendar = .current,
        locale: Locale = LocaleManager.nonisolatedEffectiveLocale
    ) -> [PickySendTimingOption] {
        var options: [PickySendTimingOption] = [
            PickySendTimingOption(
                timing: .afterCurrentReply,
                title: L10n.t("hud.scheduled.group.afterCurrentReply"),
                detail: nil,
                shortcut: "⌥↵",
                isEnabled: canSendAfterCurrentReply
            )
        ]
        let isTimedEnabled = isPluginInstalled && !carriesScreenContext
        let timedDisabledReason = isPluginInstalled && carriesScreenContext
            ? L10n.t("hud.composer.sendTiming.textOnly")
            : nil
        for seconds in presetDelays {
            let dueAt = now.addingTimeInterval(TimeInterval(seconds))
            options.append(
                PickySendTimingOption(
                    timing: .delay(seconds: seconds),
                    title: PickyScheduledMessagesPresentation.relativeTitle(from: now, to: dueAt),
                    detail: PickyScheduledMessagesPresentation.absoluteDetail(
                        for: dueAt,
                        now: now,
                        calendar: calendar,
                        locale: locale
                    ),
                    isEnabled: isTimedEnabled,
                    disabledReason: timedDisabledReason
                )
            )
        }
        if let tomorrow = tomorrowPresetDate(now: now, calendar: calendar) {
            options.append(
                PickySendTimingOption(
                    timing: .at(tomorrow),
                    title: L10n.t(
                        "hud.composer.sendTiming.tomorrowAt",
                        PickyCustomSendTimePolicy.timeText(for: tomorrow, calendar: calendar, locale: locale)
                    ),
                    detail: PickyCustomSendTimePolicy.dateText(for: tomorrow, calendar: calendar, locale: locale),
                    isEnabled: isTimedEnabled,
                    disabledReason: timedDisabledReason
                )
            )
        }
        options.append(
            PickySendTimingOption(
                timing: .custom,
                title: L10n.t("hud.composer.sendTiming.custom"),
                detail: nil,
                isEnabled: isTimedEnabled,
                disabledReason: timedDisabledReason
            )
        )
        return options
    }

    /// Tomorrow at 9:00 in the user's calendar, even shortly after midnight;
    /// Slack's "tomorrow" preset behaves the same way.
    static func tomorrowPresetDate(now: Date, calendar: Calendar) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return calendar.date(bySettingHour: tomorrowPresetHour, minute: 0, second: 0, of: tomorrow)
    }
}

extension PickySendTimingOption {
    init(
        timing: PickySendTiming,
        title: String,
        detail: String?,
        isEnabled: Bool,
        disabledReason: String? = nil
    ) {
        self.init(
            timing: timing,
            title: title,
            detail: detail,
            shortcut: nil,
            isEnabled: isEnabled,
            disabledReason: disabledReason
        )
    }
}
