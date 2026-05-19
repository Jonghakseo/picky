//
//  PickyVoiceInteractionMachineTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyVoiceInteractionMachineTests {
    private let inputA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let inputB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let speechA = UUID(uuidString: "20000000-0000-0000-0000-00000000000A")!
    private let speechB = UUID(uuidString: "20000000-0000-0000-0000-00000000000B")!
    private let timerA = UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!
    private let timerB = UUID(uuidString: "10000000-0000-0000-0000-00000000000B")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pttReleaseAndFinalTranscriptMovesThroughLoadingWithPromptBubble() {
        var state = PickyVoiceInteractionState()

        state = reduce(state, .pttPressed(inputID: inputA, targetSessionID: nil, mode: .standard))
        #expect(state.phase == .pttInput)
        #expect(state.projection.voiceState == .listening)

        state = reduce(state, .pttReleased(inputID: inputA))
        #expect(state.phase == .loading)
        #expect(state.projection.voiceState == .processing)

        state = reduce(state, .sttFinal(inputID: inputA, text: "  설정 열어줘  ", now: now))
        #expect(state.phase == .loading)
        #expect(state.context.promptBubbleText == "설정 열어줘")
        #expect(state.projection.promptBubbleState == .recognized("설정 열어줘"))
    }

    @Test func speakingReplyQueuesNextReplyAndConsumesItAfterCurrentSpeechFinishes() {
        var state = PickyVoiceInteractionState()
        state = reduce(state, .agentReply(text: "first", shouldSpeak: true, speechID: speechA, timerID: timerA, inputID: inputA, now: now))
        #expect(state.phase == .speaking)
        #expect(state.context.responseBubbleText == "first")

        state = reduce(state, .agentReply(text: "second", shouldSpeak: true, speechID: speechB, timerID: timerB, inputID: inputB, now: now.addingTimeInterval(0.1)))
        #expect(state.phase == .speaking)
        #expect(state.context.responseBubbleText == "first")
        #expect(state.context.speechQueue.map(\.text) == ["second"])

        state = reduce(state, .speechFinished(speechID: speechA, now: now.addingTimeInterval(PickyVoiceInteractionMachine.minimumDisplayDuration + 0.1)))
        #expect(state.phase == .speaking)
        #expect(state.context.activeSpeechID == speechB)
        #expect(state.context.responseBubbleText == "second")
        #expect(state.context.speechQueue.isEmpty)
        #expect(state.effectsToRun.contains(.speak(speechID: speechB, text: "second")))
    }

    @Test func speechFinishBeforeMinimumDisplayDefersQueueConsumptionUntilTimer() {
        var state = PickyVoiceInteractionState()
        state = reduce(state, .agentReply(text: "first", shouldSpeak: true, speechID: speechA, timerID: timerA, inputID: inputA, now: now))
        state = reduce(state, .agentReply(text: "second", shouldSpeak: true, speechID: speechB, timerID: timerB, inputID: inputB, now: now.addingTimeInterval(0.1)))

        state = reduce(state, .speechFinished(speechID: speechA, now: now.addingTimeInterval(0.1)))
        #expect(state.phase == .speaking)
        #expect(state.context.activeSpeechID == speechA)
        #expect(state.context.isSpeechFinishPending)
        #expect(state.context.speechQueue.count == 1)

        state = reduce(state, .minimumDisplayTimerFired(timerID: timerA, now: now.addingTimeInterval(PickyVoiceInteractionMachine.minimumDisplayDuration)))
        #expect(state.phase == .speaking)
        #expect(state.context.activeSpeechID == speechB)
        #expect(state.context.responseBubbleText == "second")
    }

    @Test func pttInterruptFromSpeakingAbortsAndClearsSpeechQueue() {
        var state = PickyVoiceInteractionState()
        state = reduce(state, .agentReply(text: "first", shouldSpeak: true, speechID: speechA, timerID: timerA, inputID: inputA, now: now))
        state = reduce(state, .agentReply(text: "second", shouldSpeak: true, speechID: speechB, timerID: timerB, inputID: inputB, now: now))

        state = reduce(state, .pttPressed(inputID: inputB, targetSessionID: "pickle-1", mode: .standard))
        #expect(state.phase == .pttInput)
        #expect(state.context.speechQueue.isEmpty)
        #expect(state.context.responseBubbleText == nil)
        #expect(state.effectsToRun.contains(.stopSpeech(speechID: speechA)))
        #expect(state.effectsToRun.contains(.abortMainAgent))
    }

    @Test func abortFromStandardLoadingCancelsMainAndTargetPickleThenReturnsIdle() {
        var state = PickyVoiceInteractionState()
        state = reduce(state, .loadingStarted(inputID: inputB, transcript: "질문", targetSessionID: "pickle-1", mode: .standard, now: now, promptBubbleVisibility: .visible))
        state = reduce(state, .abort)
        #expect(state.phase == .idle)
        #expect(state.effectsToRun.contains(.abortMainAgent))
        #expect(state.effectsToRun.contains(.abortPickle(sessionID: "pickle-1")))
    }

    @Test func loadingStartedCanKeepTranscriptWhileHidingPromptBubble() {
        let state = reduce(
            PickyVoiceInteractionState(),
            .loadingStarted(
                inputID: inputA,
                transcript: "  다시 보여주지 않을 STT  ",
                targetSessionID: nil,
                mode: .standard,
                now: now,
                promptBubbleVisibility: .hidden
            )
        )

        #expect(state.phase == .loading)
        #expect(state.context.transcript == "다시 보여주지 않을 STT")
        #expect(state.context.promptBubbleText == nil)
        #expect(state.context.promptBubbleVisibility == .hidden)
        #expect(state.projection.voiceState == .processing)
        #expect(state.projection.promptBubbleState == .hidden)
        #expect(!state.effectsToRun.contains(.schedulePromptBubbleAutoHide))
    }

    @Test func hiddenPromptPolicySurvivesLateFinalTranscriptForSameInput() {
        var state = reduce(
            PickyVoiceInteractionState(),
            .loadingStarted(
                inputID: inputA,
                transcript: "처음 보였던 STT",
                targetSessionID: nil,
                mode: .standard,
                now: now,
                promptBubbleVisibility: .hidden
            )
        )

        state = reduce(state, .sttFinal(inputID: inputA, text: "  늦게 도착한 STT  ", now: now.addingTimeInterval(0.1)))

        #expect(state.phase == .loading)
        #expect(state.context.transcript == "늦게 도착한 STT")
        #expect(state.context.promptBubbleText == nil)
        #expect(state.context.promptBubbleVisibility == .hidden)
        #expect(state.projection.promptBubbleState == .hidden)
        #expect(!state.effectsToRun.contains(.schedulePromptBubbleAutoHide))
        #expect(state.effectsToRun.contains(.captureContext(inputID: inputA, transcript: "늦게 도착한 STT", targetSessionID: nil)))
    }

    private func reduce(_ state: PickyVoiceInteractionState, _ event: PickyVoiceInteractionEvent) -> PickyVoiceInteractionState {
        PickyVoiceInteractionMachine.reduce(state: state, event: event).state
    }
}
