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
    /// Delayed-action timed send.
    case delay(seconds: Int)

    var id: String {
        switch self {
        case .afterCurrentReply: "after-current-reply"
        case .delay(let seconds): "delay-\(seconds)"
        }
    }

    var delayMilliseconds: Int? {
        switch self {
        case .afterCurrentReply: nil
        case .delay(let seconds): seconds * 1000
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
    /// Fixed presets. Spacing them this far apart keeps the menu to three rows
    /// instead of a picker; the agent itself can schedule anything finer.
    static let presetDelays: [Int] = [5 * 60, 8 * 60 * 60, 2 * 24 * 60 * 60]

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
                    isEnabled: isPluginInstalled && !carriesScreenContext,
                    disabledReason: isPluginInstalled && carriesScreenContext
                        ? L10n.t("hud.composer.sendTiming.textOnly")
                        : nil
                )
            )
        }
        return options
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
