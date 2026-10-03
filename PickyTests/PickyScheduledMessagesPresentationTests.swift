//
//  PickyScheduledMessagesPresentationTests.swift
//  PickyTests
//
//  Grouping/ordering contract for the scheduled-messages surface and the
//  composer's "send when" menu.
//

import Foundation
import Testing
@testable import Picky

struct PickyScheduledMessagesPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func followUp(_ text: String, id: String, offset: TimeInterval = 0) -> PickyQueueItem {
        PickyQueueItem(text: text, enqueuedAt: now.addingTimeInterval(offset), id: id)
    }

    private func scheduled(_ text: String, id: String, inSeconds: TimeInterval) -> PickyScheduledMessage {
        PickyScheduledMessage(id: id, text: text, dueAt: now.addingTimeInterval(inSeconds), createdAt: now)
    }

    @Test func followUpsLeadAndTimedMessagesFollowInDueOrder() {
        let presentation = PickyScheduledMessagesPresentation(
            followUps: [followUp("share the PR", id: "f1"), followUp("write release notes", id: "f2", offset: 1)],
            scheduledMessages: [
                scheduled("summarize today", id: "s-late", inSeconds: 8 * 3600),
                scheduled("check deploy logs", id: "s-soon", inSeconds: 5 * 60),
            ],
            now: now
        )

        #expect(presentation.totalCount == 4)
        #expect(presentation.groups.count == 3)
        #expect(presentation.groups[0].id == "follow-up")
        #expect(presentation.groups[0].rows.map(\.id) == ["f1", "f2"])
        #expect(presentation.groups[0].rows.map(\.kind) == [.followUp, .followUp])
        #expect(presentation.groups[0].detail == nil)
        #expect(presentation.groups[1].rows.map(\.id) == ["s-soon"])
        #expect(presentation.groups[1].detail != nil)
        #expect(presentation.groups[2].rows.map(\.id) == ["s-late"])
        #expect(presentation.nextGroupTitle == L10n.t("hud.scheduled.group.afterCurrentReply"))
    }

    @Test func timedMessagesDueInTheSameMinuteShareOneGroup() {
        let presentation = PickyScheduledMessagesPresentation(
            followUps: [],
            scheduledMessages: [
                scheduled("check deploy logs", id: "a", inSeconds: 5 * 60),
                scheduled("check the error dashboard", id: "b", inSeconds: 5 * 60 + 20),
                scheduled("summarize today", id: "c", inSeconds: 8 * 3600),
            ],
            now: now
        )

        #expect(presentation.groups.count == 2)
        #expect(presentation.groups[0].rows.map(\.id) == ["a", "b"])
        #expect(presentation.groups[1].rows.map(\.id) == ["c"])
    }

    @Test func groupTitlesUseOneCoarseUnit() {
        #expect(PickyScheduledMessagesPresentation.relativeTitle(from: now, to: now.addingTimeInterval(30))
            == L10n.t("hud.scheduled.relative.soon"))
        #expect(PickyScheduledMessagesPresentation.relativeTitle(from: now, to: now.addingTimeInterval(5 * 60))
            == L10n.t("hud.scheduled.relative.minutes", Int64(5)))
        #expect(PickyScheduledMessagesPresentation.relativeTitle(from: now, to: now.addingTimeInterval(8 * 3600))
            == L10n.t("hud.scheduled.relative.hours", Int64(8)))
        #expect(PickyScheduledMessagesPresentation.relativeTitle(from: now, to: now.addingTimeInterval(2 * 86_400))
            == L10n.t("hud.scheduled.relative.days", Int64(2)))
    }

    /// A same-day send needs only the clock; a later day needs the date too,
    /// otherwise "오전 10:16" is ambiguous.
    @Test func absoluteDetailAddsTheDateOnlyWhenTheSendDayDiffers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let sameDay = PickyScheduledMessagesPresentation.absoluteDetail(
            for: now.addingTimeInterval(300), now: now, calendar: calendar, locale: Locale(identifier: "ko_KR")
        )
        let otherDay = PickyScheduledMessagesPresentation.absoluteDetail(
            for: now.addingTimeInterval(2 * 86_400), now: now, calendar: calendar, locale: Locale(identifier: "ko_KR")
        )

        #expect(!sameDay.isEmpty)
        #expect(otherDay.count > sameDay.count)
        #expect(otherDay.hasSuffix(PickyScheduledMessagesPresentation.absoluteDetail(
            for: now.addingTimeInterval(2 * 86_400),
            now: now.addingTimeInterval(2 * 86_400),
            calendar: calendar,
            locale: Locale(identifier: "ko_KR")
        )))
    }

    @Test func followUpRowsShowTheUserInstructionWithoutThePromptEnvelope() {
        let envelope = """
        # Picky follow-up

        ## User follow-up
        - Source: text-follow-up

        share the PR

        ## Captured context
        - hidden
        """
        let presentation = PickyScheduledMessagesPresentation(
            followUps: [PickyQueueItem(text: envelope, enqueuedAt: now, id: "f1")],
            scheduledMessages: [],
            now: now
        )

        #expect(presentation.groups[0].rows.map(\.text) == ["share the PR"])
    }

    /// Two identical follow-ups plus one identical message the Pickle already
    /// took: the daemon still lists both queue ids, so both rows must stay. The
    /// panel is now the only place these messages appear.
    @Test func identicalCommittedTextDoesNotHideStillQueuedFollowUps() {
        let visibleQueue = PickyVisibleQueue(
            queuedSteers: [],
            queuedFollowUps: [followUp("retry the deploy", id: "f1"), followUp("retry the deploy", id: "f2", offset: 1)],
            committedUserMessages: [PickySubmittedUserMessage(text: "retry the deploy", createdAt: now)]
        )

        let presentation = PickyScheduledMessagesPresentation(
            followUps: visibleQueue.followUps,
            scheduledMessages: [],
            now: now
        )

        #expect(presentation.groups.first?.rows.map(\.id) == ["f1", "f2"])
    }

    /// Pre-id daemons send queue entries Picky cannot address, so those rows are
    /// listed without a toolbar instead of pointing commands at a made-up id.
    @Test func followUpWithoutAnIDIsListedButNotActionable() {
        let presentation = PickyScheduledMessagesPresentation(
            followUps: [
                PickyQueueItem(text: "legacy entry", enqueuedAt: now),
                followUp("addressable entry", id: "f2"),
            ],
            scheduledMessages: [],
            now: now
        )

        #expect(presentation.groups[0].rows.map(\.isActionable) == [false, true])
        #expect(presentation.groups[0].rows.map(\.text) == ["legacy entry", "addressable entry"])
    }

    @Test func emptyQueuesHideTheSurface() {
        let presentation = PickyScheduledMessagesPresentation(followUps: [], scheduledMessages: [], now: now)

        #expect(!presentation.isVisible)
        #expect(presentation.totalCount == 0)
        #expect(presentation.nextGroupTitle == nil)
    }

    // MARK: - Send timing menu

    @Test func sendTimingMenuDisablesTimedRowsUntilTheDelayedActionPluginIsInstalled() {
        let withoutPlugin = PickySendTimingPolicy.options(
            now: now, canSendAfterCurrentReply: true, isPluginInstalled: false
        )
        let withPlugin = PickySendTimingPolicy.options(
            now: now, canSendAfterCurrentReply: true, isPluginInstalled: true
        )

        #expect(withoutPlugin.map(\.timing) == [
            .afterCurrentReply,
            .delay(seconds: 5 * 60),
            .delay(seconds: 8 * 3600),
            .delay(seconds: 2 * 86_400),
        ])
        #expect(withoutPlugin.map(\.isEnabled) == [true, false, false, false])
        #expect(withPlugin.map(\.isEnabled) == [true, true, true, true])
        // No "send now" row: the split button's left half already does that.
        #expect(withPlugin.count == 4)
    }

    @Test func sendTimingMenuDisablesTheFollowUpRowWhenTheSessionCannotQueueOne() {
        let options = PickySendTimingPolicy.options(
            now: now, canSendAfterCurrentReply: false, isPluginInstalled: true
        )

        #expect(options[0].timing == .afterCurrentReply)
        #expect(!options[0].isEnabled)
        #expect(options[0].shortcut == "⌥↵")
        #expect(options.dropFirst().map(\.isEnabled) == [true, true, true])
        #expect(options.dropFirst().compactMap(\.detail).count == 3)
    }

    @Test func timedOptionsCarryTheDelayTheDaemonCommandNeeds() {
        #expect(PickySendTiming.afterCurrentReply.delayMilliseconds == nil)
        #expect(PickySendTiming.delay(seconds: 5 * 60).delayMilliseconds == 300_000)
    }

    /// A timed message is stored as plain text, so a screenshot or an armed
    /// screen capture cannot travel with it.
    @Test func sendTimingMenuDisablesTimedRowsWhileTheDraftCarriesScreenContext() {
        let options = PickySendTimingPolicy.options(
            now: now,
            canSendAfterCurrentReply: true,
            isPluginInstalled: true,
            carriesScreenContext: true
        )

        #expect(options.map(\.isEnabled) == [true, false, false, false])
        #expect(options.dropFirst().allSatisfy { $0.disabledReason != nil })
        // The missing-plugin case keeps its own install affordance instead.
        #expect(PickySendTimingPolicy.options(
            now: now, canSendAfterCurrentReply: true, isPluginInstalled: false
        ).allSatisfy { $0.disabledReason == nil })
    }

    /// Picking a send time mid-edit would create a second message instead of
    /// saving the one being edited, so the chevron is inert until the edit ends.
    @Test func sendTimingMenuIsUnavailableWhileEditingAScheduledMessage() {
        #expect(PickySendTimingPolicy.isMenuEnabled(isSendEnabled: true, isEditingScheduledMessage: false))
        #expect(!PickySendTimingPolicy.isMenuEnabled(isSendEnabled: true, isEditingScheduledMessage: true))
        #expect(!PickySendTimingPolicy.isMenuEnabled(isSendEnabled: false, isEditingScheduledMessage: false))
    }
}
