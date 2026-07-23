//
//  PickyMainQuestionPanelPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMainQuestionPanelPolicyTests {
    @Test
    func activityOverlayShowsOnlyWhileProcessingWithLiveActivity() {
        #expect(PickyMainActivityOverlayPolicy.shouldShow(
            voiceState: .processing,
            hasActivities: true,
            hasPendingQuestion: false
        ))
        #expect(!PickyMainActivityOverlayPolicy.shouldShow(
            voiceState: .responding,
            hasActivities: true,
            hasPendingQuestion: false
        ))
    }

    @Test
    func activityOverlayShowsForPendingQuestionWithoutToolActivity() {
        #expect(PickyMainActivityOverlayPolicy.shouldShow(
            voiceState: .processing,
            hasActivities: false,
            hasPendingQuestion: true
        ))
        #expect(!PickyMainActivityOverlayPolicy.shouldShow(
            voiceState: .processing,
            hasActivities: false,
            hasPendingQuestion: false
        ))
    }

    @Test
    func pendingQuestionPresentationReplacesLiveToolChips() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "tool-1",
            toolName: "read",
            status: "running",
            argsPreview: #"{"path":"Picky/Overlay/BlueCursorView.swift"}"#
        )

        let presentation = PickyMainActivityChipPresentation(
            activities: [activity],
            isQuestionPending: true
        )

        #expect(presentation.models.count == 1)
        #expect(presentation.isQuestionPending)
    }

    @Test
    func cancellationUsesMainExtensionUiCancelledPayload() {
        #expect(PickyMainQuestionPanelPolicy.cancellationValue == .object(["cancelled": .bool(true)]))
    }

    @Test
    func panelPresentationTracksRequestPresence() {
        #expect(!PickyMainQuestionPanelPolicy.shouldPresent(request: nil))
        #expect(PickyMainQuestionPanelPolicy.shouldPresent(request: request()))
    }

    @Test
    func answerRejectionKeepsThePendingQuestionVisible() {
        let rejection = PickyErrorEvent(code: "bad_message", message: "Unknown extension UI request", commandId: "answer-1")

        #expect(!PickyMainQuestionPanelPolicy.shouldClearPendingQuestion(after: rejection))
        #expect(PickyMainQuestionPanelPolicy.shouldClearPendingQuestion(after: nil))
    }

    @Test
    func panelHeightIsCappedToTheVisibleScreen() {
        #expect(PickyMainQuestionPanelLayout.cappedHeight(fittingHeight: 900, visibleScreenHeight: 800) == 560)
        #expect(PickyMainQuestionPanelLayout.cappedHeight(fittingHeight: 300, visibleScreenHeight: 800) == PickyMainQuestionPanelLayout.estimatedPanelHeight)
    }

    private func request() -> PickyExtensionUiRequest {
        PickyExtensionUiRequest(
            id: "main-question",
            sessionId: "picky-main",
            method: "askUserQuestion",
            title: "Continue?",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
