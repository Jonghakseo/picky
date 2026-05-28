//
//  PickyFullscreenConversationListViewTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@Suite("PickyFullscreenConversationListView")
struct PickyFullscreenConversationListViewTests {
    @Test func scrollAnimationRespectsReducedMotion() {
        #expect(!PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: false, reduceMotion: false))
        #expect(PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: true, reduceMotion: false))
        #expect(!PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: true, reduceMotion: true))
    }

    @Test func initialEntryUsesBottomDefaultScrollAnchor() {
        #expect(PickyFullscreenConversationListView.usesBottomDefaultScrollAnchor)
    }

    @Test func turnInputsKeyTracksTranscriptDependencies() {
        var session = sessionFixture()
        let initialKey = PickyFullscreenConversationListView.turnInputsKey(
            session: session,
            completedTurnCount: 0,
            expandedWorkSummaryTurnCount: 0
        )

        session.messages.append(message(id: "agent-2", kind: .agentText, text: "new answer"))
        let appendedKey = PickyFullscreenConversationListView.turnInputsKey(
            session: session,
            completedTurnCount: 0,
            expandedWorkSummaryTurnCount: 0
        )

        #expect(appendedKey != initialKey)
        #expect(PickyFullscreenConversationListView.turnInputsKey(
            session: session,
            completedTurnCount: 1,
            expandedWorkSummaryTurnCount: 0
        ) != appendedKey)
        #expect(PickyFullscreenConversationListView.turnInputsKey(
            session: session,
            completedTurnCount: 0,
            expandedWorkSummaryTurnCount: 1
        ) != appendedKey)
    }

    @Test func fullscreenDetailWidthTracksAvailableColumnWithoutTouchingDivider() {
        for columnWidth in [CGFloat(1040), 1280, 1600] {
            let detailWidth = PickyFullscreenConversationPaneView.responsiveConversationDetailWidth(forColumnWidth: columnWidth)

            #expect(detailWidth <= columnWidth - PickyFullscreenConversationPaneView.conversationDividerClearance)
            #expect(detailWidth <= 760)
        }
    }

    @Test func fullscreenDetailWidthAccountsForNarrowCenterColumnInsets() {
        for columnWidth in [CGFloat(480), 498, 528] {
            let detailWidth = PickyFullscreenConversationPaneView.responsiveConversationDetailWidth(forColumnWidth: columnWidth)
            let occupiedWidth = detailWidth
                + PickyFullscreenConversationPaneView.conversationListInnerHorizontalPadding
                + PickyFullscreenConversationPaneView.conversationDividerClearance
                + PickyFullscreenConversationPaneView.conversationUserBubbleOppositeReserve

            #expect(occupiedWidth <= columnWidth)
        }
    }

    private func sessionFixture() -> PickySessionListViewModel.SessionCard {
        PickyAgentSession(
            id: "session-1",
            title: "Fullscreen Fixture",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_060),
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: [
                message(id: "user-1", kind: .userText, text: "question"),
                message(id: "agent-1", kind: .agentText, text: "answer")
            ]
        ).toSessionCard()
    }

    private func message(id: String, kind: PickySessionMessageKind, text: String?) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil
        )
    }
}

private extension PickyAgentSession {
    func toSessionCard() -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard.fromAgentSession(self)
    }
}
