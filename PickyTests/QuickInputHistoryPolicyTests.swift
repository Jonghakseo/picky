//
//  QuickInputHistoryPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct QuickInputHistoryPolicyTests {
    @Test
    func emptyTranscriptDoesNotShowHistoryCard() {
        #expect(!QuickInputHistoryPolicy.shouldShowCard(for: []))
        #expect(QuickInputHistoryPolicy.anchorMessageID(in: []) == nil)
        #expect(!QuickInputHistoryPolicy.hasEarlierMessages(in: []))
    }

    @Test
    func latestUserPromptAnchorsTheCompactHistoryTurn() {
        let messages = [
            message(role: .user, text: "older prompt", second: 1),
            message(role: .assistant, text: "older reply", second: 2),
            message(role: .user, text: "latest prompt", second: 3),
            message(role: .assistant, text: "latest reply", second: 4)
        ]

        #expect(QuickInputHistoryPolicy.shouldShowCard(for: messages))
        #expect(QuickInputHistoryPolicy.anchorMessageID(in: messages) == messages[2].id)
        #expect(QuickInputHistoryPolicy.hasEarlierMessages(in: messages))
    }

    @Test
    func pendingUserPromptRemainsTheHistoryAnchor() {
        let messages = [
            message(role: .user, text: "prompt", second: 1),
            message(role: .assistant, text: "reply", second: 2),
            message(role: .user, text: "waiting prompt", second: 3)
        ]

        #expect(QuickInputHistoryPolicy.anchorMessageID(in: messages) == messages[2].id)
    }

    @Test
    func singleTurnDoesNotAdvertiseEarlierMessages() {
        let messages = [
            message(role: .user, text: "prompt", second: 1),
            message(role: .assistant, text: "reply", second: 2)
        ]

        #expect(!QuickInputHistoryPolicy.hasEarlierMessages(in: messages))
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
            visibleScreenHeight: 300,
            spaceAbovePill: 200
        ) == 135)
    }

    @Test
    func insufficientSpaceHidesCardAndReservesPaddingBeforeScrollContent() {
        let messages = [message(role: .user, text: "prompt", second: 1)]
        let insufficientHeight = QuickInputHistoryPolicy.minimumCardHeight - 1

        #expect(!QuickInputHistoryPolicy.shouldDisplayCard(
            for: messages,
            cardHeightLimit: insufficientHeight
        ))
        #expect(QuickInputHistoryPolicy.shouldDisplayCard(
            for: messages,
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

        #expect(QuickInputHistoryPolicy.anchorMessageID(in: messages) == newPrompt.id)
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
