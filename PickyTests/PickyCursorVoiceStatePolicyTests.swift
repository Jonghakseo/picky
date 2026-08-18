//
//  PickyCursorVoiceStatePolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyCursorVoiceStatePolicyTests {
    private func inputs(
        machineState: CompanionVoiceState = .idle,
        isCapturingVoiceInput: Bool = false,
        isFinalizingTranscript: Bool = false,
        hasPendingAgentResponse: Bool = false,
        isCoordinatorSpeaking: Bool = false,
        isWaitingForCursorResponse: Bool = false
    ) -> PickyCursorVoiceStatePolicy.Inputs {
        PickyCursorVoiceStatePolicy.Inputs(
            machineState: machineState,
            isCapturingVoiceInput: isCapturingVoiceInput,
            isFinalizingTranscript: isFinalizingTranscript,
            hasPendingAgentResponse: hasPendingAgentResponse,
            isCoordinatorSpeaking: isCoordinatorSpeaking,
            isWaitingForCursorResponse: isWaitingForCursorResponse
        )
    }

    @Test func allAxesClearResolvesIdle() {
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs()) == .idle)
    }

    @Test func liveCaptureAlwaysWinsOverEveryOtherAxis() {
        // Barge-in invariant: while the user physically holds PTT (or any
        // recording is active), no playback or waiting state may claim the
        // cursor — regardless of how stale async cleanup interleaves.
        let contested = inputs(
            machineState: .responding,
            isCapturingVoiceInput: true,
            isFinalizingTranscript: true,
            hasPendingAgentResponse: true,
            isCoordinatorSpeaking: true,
            isWaitingForCursorResponse: true
        )
        #expect(PickyCursorVoiceStatePolicy.resolve(contested) == .listening)
    }

    @Test func machineListeningResolvesListening() {
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs(machineState: .listening)) == .listening)
    }

    @Test func playbackBeatsWaitingAxes() {
        let machineSpeaking = inputs(machineState: .responding, hasPendingAgentResponse: true)
        #expect(PickyCursorVoiceStatePolicy.resolve(machineSpeaking) == .responding)

        let coordinatorSpeaking = inputs(isFinalizingTranscript: true, isCoordinatorSpeaking: true)
        #expect(PickyCursorVoiceStatePolicy.resolve(coordinatorSpeaking) == .responding)
    }

    @Test func eachWaitingAxisResolvesProcessing() {
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs(machineState: .processing)) == .processing)
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs(isFinalizingTranscript: true)) == .processing)
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs(hasPendingAgentResponse: true)) == .processing)
        #expect(PickyCursorVoiceStatePolicy.resolve(inputs(isWaitingForCursorResponse: true)) == .processing)
    }
}
