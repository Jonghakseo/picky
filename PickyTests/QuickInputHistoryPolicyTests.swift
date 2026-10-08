//
//  QuickInputHistoryPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct QuickInputHistoryPolicyTests {
    @Test
    func emptyTranscriptDoesNotShowHistoryCard() {
        #expect(!QuickInputHistoryPolicy.shouldShowCard(for: []))
        #expect(QuickInputHistoryPolicy.anchorItemID(in: []) == nil)
        #expect(!QuickInputHistoryPolicy.hasEarlierItems(in: []))
    }

    @Test
    func latestUserPromptAnchorsTheCompactHistoryTurn() {
        let messages = [
            message(role: .user, text: "older prompt", second: 1),
            message(role: .assistant, text: "older reply", second: 2),
            message(role: .user, text: "latest prompt", second: 3),
            message(role: .assistant, text: "latest reply", second: 4)
        ]

        #expect(QuickInputHistoryPolicy.shouldShowCard(for: items(messages)))
        #expect(QuickInputHistoryPolicy.anchorItemID(in: items(messages)) == id(messages[2]))
        #expect(QuickInputHistoryPolicy.hasEarlierItems(in: items(messages)))
    }

    @Test
    func pendingUserPromptRemainsTheHistoryAnchor() {
        let messages = [
            message(role: .user, text: "prompt", second: 1),
            message(role: .assistant, text: "reply", second: 2),
            message(role: .user, text: "waiting prompt", second: 3)
        ]

        #expect(QuickInputHistoryPolicy.anchorItemID(in: items(messages)) == id(messages[2]))
    }

    @Test
    func singleTurnDoesNotAdvertiseEarlierMessages() {
        let messages = [
            message(role: .user, text: "prompt", second: 1),
            message(role: .assistant, text: "reply", second: 2)
        ]

        #expect(!QuickInputHistoryPolicy.hasEarlierItems(in: items(messages)))
    }

    @Test
    func cardHeightUsesDefaultAndAvailableScreenCaps() {
        #expect(QuickInputHistoryPolicy.cardHeightLimit(
            visibleScreenHeight: nil,
            spaceAbovePill: nil
        ) == QuickInputHistoryPolicy.defaultCardHeight)
        #expect(QuickInputHistoryPolicy.cardHeightLimit(
            visibleScreenHeight: 800,
            spaceAbovePill: 100
        ) == 100)
        #expect(QuickInputHistoryPolicy.cardHeightLimit(
            visibleScreenHeight: 240,
            spaceAbovePill: 200
        ) == 108)
    }

    @Test
    func insufficientSpaceHidesCardAndReservesPaddingBeforeScrollContent() {
        let messages = [message(role: .user, text: "prompt", second: 1)]
        let insufficientHeight = QuickInputHistoryPolicy.minimumCardHeight - 1

        #expect(!QuickInputHistoryPolicy.shouldDisplayCard(
            for: items(messages),
            cardHeightLimit: insufficientHeight
        ))
        #expect(QuickInputHistoryPolicy.shouldDisplayCard(
            for: items(messages),
            cardHeightLimit: QuickInputHistoryPolicy.minimumCardHeight
        ))
        #expect(QuickInputHistoryPolicy.scrollHeightLimit(
            cardHeightLimit: QuickInputHistoryPolicy.minimumCardHeight
        ) == QuickInputHistoryPolicy.minimumScrollContentHeight)
    }

    @Test
    func bottomFadeRequiresTranscriptContentBelowTheViewport() {
        #expect(!QuickInputHistoryPolicy.hasContentBelowViewport(
            contentBottom: 120,
            viewportHeight: 120
        ))
        #expect(!QuickInputHistoryPolicy.hasContentBelowViewport(
            contentBottom: 120.5,
            viewportHeight: 120
        ))
        #expect(QuickInputHistoryPolicy.hasContentBelowViewport(
            contentBottom: 121,
            viewportHeight: 120
        ))
    }

    @Test
    func appendingNewUserPromptAdvancesHistoryAnchor() {
        var messages = [
            message(role: .user, text: "older prompt", second: 1),
            message(role: .assistant, text: "older reply", second: 2)
        ]
        let newPrompt = message(role: .user, text: "new prompt", second: 3)

        messages.append(newPrompt)

        #expect(QuickInputHistoryPolicy.anchorItemID(in: items(messages)) == id(newPrompt))
    }

    /// The card is short: a question of the current turn that waits on the
    /// user starts the view so its buttons show without scrolling.
    @Test
    func waitingQuestionOfTheLatestTurnStartsTheHistory() {
        let messages = [
            message(role: .user, text: "older prompt", second: 1),
            message(role: .assistant, text: "older reply", second: 2),
            message(role: .user, text: "fix the report", second: 3),
            message(role: .assistant, text: "the discount is applied ten times", second: 4)
        ]
        let snapshot = PickyMainTasksSnapshot(tasks: [], decisions: [decision(id: "fix", state: .pending, second: 5)])
        let entries = PickyMainTaskPresentation.timelineItems(messages: messages, snapshot: snapshot)

        #expect(QuickInputHistoryPolicy.anchorItemID(in: entries) == "decision-fix")
        #expect(QuickInputHistoryPolicy.hasEarlierItems(in: entries))
    }

    /// Answered, or left open in an earlier turn, a question does not take the
    /// start away from the latest prompt.
    @Test
    func answeredOrEarlierQuestionsLeaveTheAnchorAtTheLatestPrompt() {
        let messages = [
            message(role: .user, text: "fix the report", second: 1),
            message(role: .assistant, text: "the discount is applied ten times", second: 2),
            message(role: .user, text: "what is on my calendar", second: 10)
        ]
        let earlierOpen = PickyMainTasksSnapshot(tasks: [], decisions: [decision(id: "fix", state: .pending, second: 3)])
        let answered = PickyMainTasksSnapshot(tasks: [], decisions: [decision(id: "fix", state: .task, second: 11)])

        for snapshot in [earlierOpen, answered] {
            let entries = PickyMainTaskPresentation.timelineItems(messages: messages, snapshot: snapshot)
            #expect(QuickInputHistoryPolicy.anchorItemID(in: entries) == id(messages[2]))
        }
    }

    @Test
    func historyBackgroundBecomesSolidAfterUserScrollUntilNextPresentation() {
        var mode: QuickInputHistoryBackgroundMode = .lightweight

        mode.recordUserScroll()
        #expect(mode == .solid)

        mode.recordUserScroll()
        #expect(mode == .solid)

        mode.resetForPresentation()
        #expect(mode == .lightweight)
    }

    @Test
    func newSessionActionFollowsEffectiveSolidPresentation() {
        #expect(!QuickInputHistoryPolicy.shouldShowNewSessionAction(
            backgroundMode: .lightweight,
            reduceTransparency: false
        ))
        #expect(QuickInputHistoryPolicy.shouldShowNewSessionAction(
            backgroundMode: .solid,
            reduceTransparency: false
        ))
        #expect(QuickInputHistoryPolicy.shouldShowNewSessionAction(
            backgroundMode: .lightweight,
            reduceTransparency: true
        ))
    }

    private func items(_ messages: [PickyMainAgentMessage]) -> [PickyMainConversationTimelineItem] {
        messages.map(PickyMainConversationTimelineItem.message)
    }

    private func id(_ message: PickyMainAgentMessage) -> String {
        PickyMainConversationTimelineItem.message(message).id
    }

    private func decision(id: String, state: PickyMainDelegationState, second: TimeInterval) -> PickyMainDelegationDecision {
        PickyMainDelegationDecision(
            id: id,
            state: state,
            title: "Fix the discount",
            instructions: "Fix the discount math",
            cwd: nil,
            question: "Hand the fix to a Pickle?",
            createdAt: Date(timeIntervalSince1970: second),
            updatedAt: Date(timeIntervalSince1970: second),
            fromTaskId: nil,
            taskId: state == .task ? "task-1" : nil,
            pickle: nil
        )
    }

    private func message(
        role: PickyMainAgentMessage.Role,
        text: String,
        second: TimeInterval
    ) -> PickyMainAgentMessage {
        PickyMainAgentMessage(
            role: role,
            text: text,
            createdAt: Date(timeIntervalSince1970: second)
        )
    }
}
