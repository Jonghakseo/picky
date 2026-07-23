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
        #expect(PickyMainQuestionPanelLayout.cappedHeight(fittingHeight: 180, visibleScreenHeight: 800) == PickyMainQuestionPanelLayout.estimatedPanelHeight)
    }

    @Test
    func multipleQuestionRequestsUseStepsAndResetToTheFirstQuestion() {
        let viewModel = PickyMainQuestionPanelViewModel()
        let questions = [textQuestion(id: "first"), textQuestion(id: "second")]

        viewModel.configure(request: request(questions: questions))
        #expect(viewModel.usesSteps)
        #expect(viewModel.currentStepIndex == 0)
        #expect(viewModel.isFirstStep)
        #expect(!viewModel.isLastStep)

        viewModel.formState.textValues["first"] = "ready"
        viewModel.goNext()
        #expect(viewModel.currentStepIndex == 1)

        viewModel.configure(request: request(id: "replacement", questions: questions))
        #expect(viewModel.currentStepIndex == 0)
        #expect(viewModel.isFirstStep)
    }

    @Test
    func wizardOnlyAdvancesWhenTheCurrentRequiredQuestionIsSatisfied() {
        let viewModel = PickyMainQuestionPanelViewModel()
        viewModel.configure(request: request(questions: [textQuestion(id: "first"), textQuestion(id: "second")]))

        #expect(!viewModel.isCurrentStepSubmittable)
        viewModel.goNext()
        #expect(viewModel.currentStepIndex == 0)

        viewModel.formState.textValues["first"] = "answer"
        #expect(viewModel.isCurrentStepSubmittable)
        viewModel.goNext()
        #expect(viewModel.currentStepIndex == 1)
        #expect(viewModel.isLastStep)
    }

    @Test
    func wizardBackNavigationPreservesTheCurrentAnswer() {
        let viewModel = PickyMainQuestionPanelViewModel()
        viewModel.configure(request: request(questions: [textQuestion(id: "first"), textQuestion(id: "second")]))
        viewModel.formState.textValues["first"] = "preserved"
        viewModel.goNext()
        viewModel.goBack()

        #expect(viewModel.currentStepIndex == 0)
        #expect(viewModel.formState.textValues["first"] == "preserved")
    }

    @Test
    func answerFailureOnlyReopensTheActiveRequest() {
        let error = PickyMainQuestionPanelAnswerError(message: "delivery failed")

        #expect(PickyMainQuestionPanelPolicy.shouldReopenAfterAnswerFailure(
            requestID: "request-1",
            activeRequestID: "request-1",
            error: error
        ))
        #expect(!PickyMainQuestionPanelPolicy.shouldReopenAfterAnswerFailure(
            requestID: "request-1",
            activeRequestID: "request-2",
            error: error
        ))
        #expect(!PickyMainQuestionPanelPolicy.shouldReopenAfterAnswerFailure(
            requestID: "request-1",
            activeRequestID: "request-1",
            error: nil
        ))
    }

    private func request(
        id: String = "main-question",
        questions: [PickyExtensionUiQuestion] = []
    ) -> PickyExtensionUiRequest {
        PickyExtensionUiRequest(
            id: id,
            sessionId: "picky-main",
            method: "askUserQuestion",
            title: "Continue?",
            questions: questions,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func textQuestion(id: String) -> PickyExtensionUiQuestion {
        PickyExtensionUiQuestion(
            id: id,
            type: .text,
            prompt: id,
            label: nil,
            options: nil,
            allowOther: nil,
            required: true,
            placeholder: nil,
            defaultValue: nil
        )
    }
}
