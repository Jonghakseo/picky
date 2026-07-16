//
//  PickyFeedbackSendStateMachineTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyFeedbackSendStateMachineTests {
    @Test func successfulSendClearsDraftOnlyAfterCompletion() {
        var state = PickyFeedbackSendStateMachine()

        let didBeginSending = state.beginSending()
        #expect(didBeginSending)
        #expect(state.status == .sending)
        let draftDisposition = state.finish(.success(()))
        #expect(draftDisposition == .clear)
        #expect(state.status == .sent)
    }

    @Test func failedSendPreservesDraftAndExposesError() {
        var state = PickyFeedbackSendStateMachine()

        let didBeginSending = state.beginSending()
        #expect(didBeginSending)
        let draftDisposition = state.finish(.failure(PickyFeedbackSendFailure(message: "Couldn't send. Offline.")))
        #expect(draftDisposition == .preserve)
        #expect(state.status == .failed("Couldn't send. Offline."))
    }

    @Test func duplicateSubmitIsRejectedWhileSendIsInFlight() {
        var state = PickyFeedbackSendStateMachine()

        let didBeginSending = state.beginSending()
        let didBeginDuplicateSend = state.beginSending()
        #expect(didBeginSending)
        #expect(!didBeginDuplicateSend)
        #expect(state.status == .sending)
    }

    @Test func feedbackFailurePresentationMapsTechnicalFailuresToRecoveryGuidance() {
        #expect(PickyFeedbackSendErrorDescription.userMessage(
            PickyFeedbackSendError.transport("NSURLErrorDomain -1009")
        ) == L10n.t("feedback.sendFailure.connection"))
        #expect(PickyFeedbackSendErrorDescription.userMessage(
            PickyFeedbackSendError.slackError("invalid_auth")
        ) == L10n.t("feedback.sendFailure.service"))
        #expect(PickyFeedbackSendErrorDescription.userMessage(
            PickyFeedbackSendError.httpStatus(500, "upload")
        ) == L10n.t("feedback.sendFailure.attachment"))
        #expect(PickyFeedbackSendErrorDescription.userMessage(
            PickyDiagnosticsBundleError.zipFailed("disk full")
        ) == L10n.t("feedback.sendFailure.diagnostics"))
    }
}
