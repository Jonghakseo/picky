//
//  PickyMainCancelPillPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

struct PickyMainCancelPillPolicyTests {
    @Test
    func mainTurnInFlightCoversVoiceAndTypedResponseSignals() {
        #expect(PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: true,
            voiceState: .idle,
            isWaitingForCursorResponse: false,
            hasLiveActivities: false
        ))
        #expect(PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: false,
            voiceState: .processing,
            isWaitingForCursorResponse: false,
            hasLiveActivities: false
        ))
        #expect(PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: false,
            voiceState: .idle,
            isWaitingForCursorResponse: true,
            hasLiveActivities: false
        ))
        #expect(PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: false,
            voiceState: .idle,
            isWaitingForCursorResponse: false,
            hasLiveActivities: true
        ))
        // An armed Quick Input follow-up is cancellable even before its
        // response has produced activity or a cursor waiting projection.
        #expect(PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: false,
            voiceState: .idle,
            isWaitingForCursorResponse: false,
            hasLiveActivities: false,
            hasActiveFollowUpTurn: true
        ))
        #expect(!PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: false,
            voiceState: .idle,
            isWaitingForCursorResponse: false,
            hasLiveActivities: false
        ))
    }

    @Test
    func presentationIsSuppressedWhileAPickyPanelOwnsKeyboardInput() {
        #expect(PickyMainCancelPillPolicy.shouldPresent(
            isMainTurnInFlight: true,
            isPickyPanelKeyWindow: false
        ))
        #expect(!PickyMainCancelPillPolicy.shouldPresent(
            isMainTurnInFlight: true,
            isPickyPanelKeyWindow: true
        ))
        #expect(!PickyMainCancelPillPolicy.shouldPresent(
            isMainTurnInFlight: false,
            isPickyPanelKeyWindow: false
        ))
    }

    @Test
    func repeatedEscapeKeyDownIsIgnoredUntilAnotherPhysicalPress() {
        #expect(PickyMainCancelPillPolicy.shouldHandleEscape(
            eventType: .keyDown,
            keyCode: 53,
            isAutorepeat: false
        ))
        #expect(!PickyMainCancelPillPolicy.shouldHandleEscape(
            eventType: .keyDown,
            keyCode: 53,
            isAutorepeat: true
        ))
        #expect(!PickyMainCancelPillPolicy.shouldHandleEscape(
            eventType: .keyUp,
            keyCode: 53,
            isAutorepeat: false
        ))
    }

    @Test
    func followUpAbortUsesOnlyTheOriginalVoiceInFlightGate() {
        #expect(PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: true,
            voiceState: .idle
        ))
        #expect(PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: false,
            voiceState: .responding
        ))
        #expect(!PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: false,
            voiceState: .processing
        ))
        #expect(!PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: false,
            voiceState: .idle
        ))
    }

    @Test
    func hoverOnlyChangesTheRestingPresentation() {
        #expect(PickyMainCancelPillPolicy.stateAfterHover(true, currentState: .rest) == .hover)
        #expect(PickyMainCancelPillPolicy.stateAfterHover(false, currentState: .hover) == .rest)
        #expect(PickyMainCancelPillPolicy.stateAfterHover(true, currentState: .escapeArmed) == .escapeArmed)
        #expect(PickyMainCancelPillPolicy.stateAfterHover(false, currentState: .cancelled) == .cancelled)
    }

    @Test
    func cancellationPresentationChangesOnlyAfterAbortSucceeds() {
        #expect(PickyMainCancelPillPolicy.stateAfterCancellationAttempt(succeeded: true) == .cancelled)
        #expect(PickyMainCancelPillPolicy.stateAfterCancellationAttempt(succeeded: false) == .rest)
    }

    @Test
    func secondEscapeConfirmsCancellationAndFirstEscapeArmsIt() {
        let armed = PickyMainCancelPillPolicy.stateAfterEscape(currentState: .rest)
        #expect(armed == .escapeArmed)
        #expect(PickyMainCancelPillPolicy.stateAfterEscape(currentState: armed) == .cancelled)
        #expect(PickyMainCancelPillPolicy.stateAfterEscape(currentState: .cancelled) == .cancelled)
        #expect(PickyMainCancelPillPolicy.escapeConfirmationWindow == 0.8)
        #expect(PickyMainCancelPillPolicy.cancellationConfirmationDuration == 1.2)
    }
}
