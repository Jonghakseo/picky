//
//  PickyInteractionStateMachineTests.swift
//  PickyTests
//
//  Tight state-machine coverage for `PickyInteractionReducer` focused on the
//  `.speaking` output phase and the events that can preempt it. These tests
//  pin down the contract that protects the cursor response bubble from
//  getting stuck after a TTS reply is interrupted by another reply, a typed
//  message, or a new voice input.
//
//  The matrix below is intentionally exhaustive — each test covers exactly
//  one (initial output) × (event) transition so a regression points at the
//  exact branch that broke.
//

import Foundation
import Testing
@testable import Picky

struct PickyInteractionStateMachineTests {
    // MARK: - Identifier fixtures

    private let inputA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let inputB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let speechA = UUID(uuidString: "20000000-0000-0000-0000-00000000000A")!
    private let speechB = UUID(uuidString: "20000000-0000-0000-0000-00000000000B")!
    private let timerA = UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!
    private let timerB = UUID(uuidString: "10000000-0000-0000-0000-00000000000B")!
    private let timerC = UUID(uuidString: "10000000-0000-0000-0000-00000000000C")!
    private let envelopeA = UUID(uuidString: "30000000-0000-0000-0000-00000000000A")!
    private let envelopeB = UUID(uuidString: "30000000-0000-0000-0000-00000000000B")!
    private let envelopeC = UUID(uuidString: "30000000-0000-0000-0000-00000000000C")!

    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let voiceContextID = "voice-context"
    private let sideSessionID = "side-session"
    private let mainSessionID = "main-session"

    // MARK: - Group A: `.speaking` preemption emits stopSpeech + drops overlay reason
    //
    // The bug we fix here: any event that overwrites a `.speaking` output with a
    // non-`.speaking` output must (a) emit `.stopSpeech(.superseded)` so the in-flight
    // TTS is actually stopped and (b) remove the `.speakingResponse` overlay reason
    // so subsequent overlay-visibility math is correct. Without this both the playing
    // utterance and the cursor bubble can outlive the projection state.

    @Test func speakingPreemptedByTextQuickReplyEmitsStopSpeechAndDropsSpeakingOverlay() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(0.35)
        )

        // A `.main` quickReply with a system origin and no cursor-presentation owner
        // routes to `.showingTextReply` — exactly the path that left voiceState
        // stuck at `.responding` in production.
        let transition = reduce(
            initial,
            .quickReply(
                contextID: "main-context",
                text: "typed reply",
                originSource: .system,
                replyKind: .main,
                sessionID: nil,
                inputID: nil
            ),
            id: timerB
        )

        expectShowingTextReply(
            transition.state.output,
            contextID: "main-context",
            text: "typed reply",
            timerID: timerB
        )
        #expect(transition.state.lastDisplayMessage?.source == .textReply)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        // The stopSpeech carries the OLD speechID so the late .speechFailed
        // dispatch hits the now-stale .speaking branch in the reducer guard.
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
        #expect(transition.effects.contains(.scheduleMinimumDisplay(
            timerID: timerB, speechID: nil, inputID: nil, delay: PickyInteractionReducer.minimumDisplayDuration
        )))
    }

    @Test func speakingPreemptedBySideCompletionDuringVoiceInputEmitsStopSpeechAndShowsSuppressedReply() {
        // Synthetic state the production code can never construct on its own
        // (voicePressed clears `.speaking` first), but we exercise the reducer
        // branch directly to lock in the cleanup contract.
        var initial = speakingState(
            contextID: sideSessionID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(0.35)
        )
        initial.input = .voiceListening(inputID: inputB, targetSessionID: nil)
        initial.overlay = .visible(reason: [.speakingResponse, .activeVoiceInput])

        let transition = reduce(
            initial,
            .quickReply(
                contextID: sideSessionID,
                text: "completed side work",
                originSource: .system,
                replyKind: .sideCompletion,
                sessionID: sideSessionID,
                inputID: nil
            ),
            id: timerB
        )

        guard case .suppressedReply(let contextID, let text, let reason, let outputTimer, _) = transition.state.output else {
            Issue.record("Expected suppressedReply, got \(transition.state.output)")
            return
        }
        #expect(contextID == sideSessionID)
        #expect(text == "completed side work")
        #expect(reason == .activeVoiceInput)
        #expect(outputTimer == timerB)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func speakingReplacedByNewSpeakingDoesNotDoubleStopButReplacesUtterance() {
        var initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(0.35)
        )
        initial.contextOwnership[voiceContextID] = .voice(inputID: inputA)

        let transition = reduce(
            initial,
            .quickReply(
                contextID: voiceContextID,
                text: "second voice reply",
                originSource: .voice,
                replyKind: .main,
                sessionID: nil,
                inputID: inputA
            ),
            id: timerB,
            correlation: .init(inputID: inputA, contextID: voiceContextID, speechID: speechB, source: .agent)
        )

        // The new `.speak` effect drives `runSpeakEffect` to call
        // `stopCurrentSpeech` internally, so the reducer intentionally does not
        // emit a redundant `.stopSpeech` here — verifying that prevents a noisy
        // stale `.speechFailed` event for the previous utterance.
        guard case .speaking(let contextID, let speechID, let text, _, _, let finishPending) = transition.state.output else {
            Issue.record("Expected new speaking output, got \(transition.state.output)")
            return
        }
        #expect(contextID == voiceContextID)
        #expect(speechID == speechB)
        #expect(text == "second voice reply")
        #expect(finishPending == false)
        #expect(isSpeakingResponseOverlayActive(transition.state))
        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
        #expect(transition.effects.contains(.speak(speechID: speechB, text: "second voice reply", contextID: voiceContextID)))
    }

    @Test func speakingPreemptedByQuickInputTextSubmittedEmitsStopSpeechAndShowsWaiting() {
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)

        let transition = reduce(
            initial,
            .textSubmitted(text: "follow up", inputID: inputB),
            id: timerB,
            correlation: .init(inputID: inputB, source: .quickInput)
        )

        guard case .waitingForAgent(let inputID, _, let preview) = transition.state.output else {
            Issue.record("Expected waitingForAgent, got \(transition.state.output)")
            return
        }
        #expect(inputID == inputB)
        #expect(preview == "follow up")
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
        #expect(transition.effects.contains(.captureTextContext(inputID: inputB, text: "follow up")))
    }

    @Test func speakingNotPreemptedByPlainTextSubmittedThatLeavesOutputUnchanged() {
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)

        // Plain `.text` source `textSubmitted` is a no-op on `state.output`, so
        // the `.speaking` output and overlay reason must be untouched and no
        // `.stopSpeech` effect should be emitted.
        let transition = reduce(
            initial,
            .textSubmitted(text: "background type", inputID: inputB),
            id: timerB,
            correlation: .init(inputID: inputB, source: .text)
        )

        #expect(transition.state.output == initial.output)
        #expect(isSpeakingResponseOverlayActive(transition.state))
        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
    }

    @Test func speakingPreemptedByTextContextCapturedEmitsStopSpeech() {
        var initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)
        initial.pendingTextInputs[inputB] = PickyTextInputState(text: "queued", source: .text)
        initial.input = .textSubmitting(inputID: inputB, text: "queued")

        let context = makeContext(id: "captured-context", source: "text", transcript: "queued")
        let transition = reduce(initial, .textContextCaptured(inputID: inputB, context: context), id: timerB)

        guard case .waitingForAgent(let inputID, let contextID, _) = transition.state.output else {
            Issue.record("Expected waitingForAgent, got \(transition.state.output)")
            return
        }
        #expect(inputID == inputB)
        #expect(contextID == "captured-context")
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func speakingPreemptedByVoiceContextCapturedEmitsStopSpeech() {
        var initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)
        initial.pendingVoiceInputs[inputB] = PickyVoiceInputState()
        initial.input = .voiceSubmitting(inputID: inputB, targetSessionID: nil, transcript: "voice ask")

        let context = makeContext(id: "voice-ctx-2", source: "voice", transcript: "voice ask")
        let transition = reduce(
            initial,
            .voiceContextCaptured(inputID: inputB, transcript: "voice ask", context: context, targetSessionID: nil),
            id: timerB
        )

        guard case .waitingForAgent = transition.state.output else {
            Issue.record("Expected waitingForAgent, got \(transition.state.output)")
            return
        }
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func speakingPreemptedByTranscriptFailedEmitsStopSpeechAndIdles() {
        var initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)
        initial.pendingVoiceInputs[inputB] = PickyVoiceInputState()
        initial.input = .voiceFinalizing(inputID: inputB, targetSessionID: nil, transcriptPreview: nil)
        initial.overlay = .visible(reason: [.speakingResponse, .activeVoiceInput])

        let transition = reduce(
            initial,
            .transcriptFailed(message: "no audio", inputID: inputB),
            id: timerB
        )

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func speakingPreemptedByQuickInputTextSubmissionFailedEmitsStopSpeechAndIdles() {
        var initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)
        initial.pendingTextInputs[inputB] = PickyTextInputState(text: "queued", source: .quickInput)
        initial.input = .textSubmitting(inputID: inputB, text: "queued")

        let transition = reduce(
            initial,
            .textSubmissionFailed(message: "boom", inputID: inputB),
            id: timerB
        )

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func speakingPreemptedByPlainTextSubmissionFailedAlsoEmitsStopSpeechAndIdles() {
        var initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)
        initial.pendingTextInputs[inputB] = PickyTextInputState(text: "queued", source: .text)
        initial.input = .textSubmitting(inputID: inputB, text: "queued")

        let transition = reduce(
            initial,
            .textSubmissionFailed(message: "boom", inputID: inputB),
            id: timerB
        )

        // `failDirectMessage` mutates `latestAgentSessionSummary` directly to
        // surface the error. If the cursor were still .responding (output
        // still .speaking) at that moment the bubble would flash the error
        // text while TTS keeps reading the old utterance — a desync.
        // Preempting on plain-text failure too keeps the cursor surface
        // honest at the cost of cutting the in-flight TTS.
        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(containsStopSpeech(reason: .superseded, speechID: speechA, in: transition.effects))
    }

    @Test func nonSpeakingPlainTextSubmissionFailedDoesNotForceOutputToIdle() {
        var initial = PickyInteractionState()
        initial.output = .showingTextReply(
            contextID: "ctx",
            text: "existing reply",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate
        )
        initial.pendingTextInputs[inputB] = PickyTextInputState(text: "queued", source: .text)
        initial.input = .textSubmitting(inputID: inputB, text: "queued")

        let transition = reduce(
            initial,
            .textSubmissionFailed(message: "boom", inputID: inputB),
            id: timerB
        )

        // Plain-text failure must only collapse output to .idle when it was
        // genuinely .speaking. An unrelated .showingTextReply (or any other
        // non-.speaking output) stays put so the failed background submission
        // doesn't tear down chrome it never raised.
        #expect(transition.state.output == initial.output)
        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
    }

    @Test func speakingPreemptedByVoicePressedEmitsUserInterruptedStopSpeech() {
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: timerA)

        let transition = reduce(
            initial,
            .voicePressed(targetSessionID: nil),
            id: timerB,
            correlation: .init(inputID: inputB, source: .voice)
        )

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        // voicePressed semantically encodes a *user* action, so its stop reason
        // stays `.userInterrupted`, not `.superseded`.
        #expect(containsStopSpeech(reason: .userInterrupted, speechID: speechA, in: transition.effects))
        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
    }

    // MARK: - Group B: `.speechFinished` / `.speechFailed` race & staleness
    //
    // `.speechFinished` and `.speechFailed` only fire the `.speaking → .idle` cleanup
    // when the current output is still `.speaking` with the matching speechID.
    // Anything else is stale and must not perturb state. Combined with Group A's
    // preemption cleanup, the duplicate stale events from preempted utterances
    // are silently absorbed.

    @Test func speechFinishedAfterMinimumDisplayTransitionsSpeakingToIdle() {
        // timerID == nil signals "minimum display already satisfied" — speech
        // completion can transition straight to .idle.
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)

        let transition = reduce(initial, .speechFinished(speechID: speechA), id: envelopeA)

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
        #expect(transition.journalRecords.last?.kind == .stateChanged)
    }

    @Test func speechFailedAfterMinimumDisplayTransitionsSpeakingToIdle() {
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)

        let transition = reduce(initial, .speechFailed(speechID: speechA), id: envelopeA)

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
    }

    @Test func speechFinishedBeforeMinimumDisplaySetsFinishPendingTrue() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration)
        )

        // Fire speech completion well before the min-display window closes.
        let transition = reduce(initial, .speechFinished(speechID: speechA), id: envelopeA, offset: 0)

        guard case .speaking(_, _, _, _, _, let finishPending) = transition.state.output else {
            Issue.record("Expected still-speaking output with finishPending=true, got \(transition.state.output)")
            return
        }
        #expect(finishPending == true)
        // overlay reason must remain so the response bubble keeps rendering
        // until the min-display timer fires.
        #expect(isSpeakingResponseOverlayActive(transition.state))
    }

    @Test func speechFailedBeforeMinimumDisplaySetsFinishPendingTrue() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration)
        )

        let transition = reduce(initial, .speechFailed(speechID: speechA), id: envelopeA, offset: 0)

        guard case .speaking(_, _, _, _, _, let finishPending) = transition.state.output else {
            Issue.record("Expected still-speaking output with finishPending=true, got \(transition.state.output)")
            return
        }
        #expect(finishPending == true)
        #expect(isSpeakingResponseOverlayActive(transition.state))
    }

    @Test func speechFinishedWithMismatchedSpeechIDIsStaleEvenWhileSpeaking() {
        let initial = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)

        let transition = reduce(initial, .speechFinished(speechID: speechB), id: envelopeA)

        // State must be unchanged.
        #expect(transition.state == initial)
        #expect(transition.effects.isEmpty)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    @Test func speechFinishedAfterPreemptionToShowingTextReplyIsStale() {
        // Set up by *running* the preemption through the reducer to mirror
        // the real timeline — speaking → preempted → stale completion arrives.
        var state = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)
        state = reduce(
            state,
            .quickReply(contextID: "main-context", text: "typed", originSource: .system, replyKind: .main, sessionID: nil, inputID: nil),
            id: envelopeA
        ).state

        let transition = reduce(state, .speechFinished(speechID: speechA), id: envelopeB)

        // Output must remain at the showingTextReply set by the preemption.
        guard case .showingTextReply = transition.state.output else {
            Issue.record("Expected output still showingTextReply, got \(transition.state.output)")
            return
        }
        #expect(transition.effects.isEmpty)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    @Test func speechFinishedAfterPreemptionToWaitingForAgentIsStale() {
        var state = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)
        state = reduce(
            state,
            .textSubmitted(text: "queued", inputID: inputB),
            id: envelopeA,
            correlation: .init(inputID: inputB, source: .quickInput)
        ).state

        let transition = reduce(state, .speechFinished(speechID: speechA), id: envelopeB)

        guard case .waitingForAgent = transition.state.output else {
            Issue.record("Expected output still waitingForAgent, got \(transition.state.output)")
            return
        }
        #expect(transition.effects.isEmpty)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    @Test func speechFinishedAfterPreemptionToIdleIsStale() {
        var state = speakingState(contextID: voiceContextID, speechID: speechA, timerID: nil)
        state = reduce(state, .voicePressed(targetSessionID: nil), id: envelopeA, correlation: .init(inputID: inputB, source: .voice)).state

        let transition = reduce(state, .speechFinished(speechID: speechA), id: envelopeB)

        // voicePressed already moved output to .idle; stale completion must
        // not flip back through any path.
        #expect(transition.state.output == .idle)
        #expect(transition.effects.isEmpty)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    // MARK: - Group C: `.minimumDisplayTimerFired` transitions

    @Test func minDisplayTimerOnFinishPendingSpeakingTransitionsToIdle() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate,
            finishPending: true
        )

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerA, speechID: speechA, inputID: nil),
            id: envelopeA,
            offset: PickyInteractionReducer.minimumDisplayDuration
        )

        #expect(transition.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(transition.state))
    }

    @Test func minDisplayTimerOnActiveSpeakingClearsTimerKeepsSpeaking() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration),
            finishPending: false
        )

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerA, speechID: speechA, inputID: nil),
            id: envelopeA,
            offset: PickyInteractionReducer.minimumDisplayDuration
        )

        guard case .speaking(_, _, _, let timerID, let until, let finishPending) = transition.state.output else {
            Issue.record("Expected still speaking output, got \(transition.state.output)")
            return
        }
        // Timer is consumed but speech keeps going; min-display is now satisfied.
        #expect(timerID == nil)
        #expect(until == nil)
        #expect(finishPending == false)
        #expect(isSpeakingResponseOverlayActive(transition.state))
    }

    @Test func minDisplayTimerOnShowingTextReplyTransitionsToIdle() {
        var initial = PickyInteractionState()
        initial.output = .showingTextReply(
            contextID: "ctx",
            text: "shown",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate
        )

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerA, speechID: nil, inputID: nil),
            id: envelopeA,
            offset: PickyInteractionReducer.minimumDisplayDuration
        )

        #expect(transition.state.output == .idle)
    }

    @Test func minDisplayTimerOnSuppressedReplyTransitionsToIdle() {
        var initial = PickyInteractionState()
        initial.output = .suppressedReply(
            contextID: "ctx",
            text: "suppressed",
            reason: .activeVoiceInput,
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate
        )

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerA, speechID: nil, inputID: nil),
            id: envelopeA,
            offset: PickyInteractionReducer.minimumDisplayDuration
        )

        #expect(transition.state.output == .idle)
    }

    @Test func staleMinDisplayTimerOnSpeakingWithDifferentTimerIDIsIgnored() {
        let initial = speakingState(
            contextID: voiceContextID,
            speechID: speechA,
            timerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration)
        )

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerB, speechID: speechA, inputID: nil),
            id: envelopeA
        )

        #expect(transition.state == initial)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    @Test func staleMinDisplayTimerOnIdleStateIsIgnored() {
        let initial = PickyInteractionState()

        let transition = reduce(
            initial,
            .minimumDisplayTimerFired(timerID: timerA, speechID: nil, inputID: nil),
            id: envelopeA
        )

        #expect(transition.state == initial)
        #expect(transition.journalRecords.last?.kind == .staleEvent)
    }

    // MARK: - Group D: Realistic race scenarios drive the full event timeline

    @Test func sideCompletionThenAnotherSideCompletionPlaysSecondAndIdlesOnSecondFinish() {
        // First completion → speaking(A).
        var state = reduce(
            PickyInteractionState(),
            .quickReply(contextID: sideSessionID, text: "first", originSource: .system, replyKind: .sideCompletion, sessionID: sideSessionID, inputID: nil),
            id: envelopeA
        ).state
        guard case .speaking(_, let firstSpeechID, _, _, _, _) = state.output else {
            Issue.record("Expected speaking after first sideCompletion")
            return
        }

        // Second completion arrives while the first is still speaking.
        let secondTransition = reduce(
            state,
            .quickReply(contextID: sideSessionID, text: "second", originSource: .system, replyKind: .sideCompletion, sessionID: sideSessionID, inputID: nil),
            id: envelopeB,
            offset: 0.05
        )
        state = secondTransition.state

        // New `.speak(secondSpeechID)` effect emitted; no `.stopSpeech` because
        // the new speak takes over inside the runtime.
        guard case .speaking(_, let secondSpeechID, _, _, _, _) = state.output else {
            Issue.record("Expected speaking after second sideCompletion, got \(state.output)")
            return
        }
        #expect(secondSpeechID != firstSpeechID)
        #expect(secondTransition.effects.contains(.speak(speechID: secondSpeechID, text: "second", contextID: sideSessionID)))
        #expect(!containsStopSpeech(reason: .superseded, in: secondTransition.effects))

        // Stale finish for the FIRST speechID is ignored.
        let staleFinish = reduce(state, .speechFinished(speechID: firstSpeechID), id: envelopeC, offset: 0.1)
        #expect(staleFinish.state == state)
        #expect(staleFinish.journalRecords.last?.kind == .staleEvent)

        // Real finish for the SECOND speechID transitions to idle.
        let cleanFinish = reduce(
            state,
            .speechFinished(speechID: secondSpeechID),
            id: envelopeC,
            offset: PickyInteractionReducer.minimumDisplayDuration + 0.5
        )
        #expect(cleanFinish.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(cleanFinish.state))
    }

    @Test func sideCompletionThenTextReplyPreemptionThenMinDisplayTimerEndsAtIdleWithoutSpeakingOverlay() {
        var state = reduce(
            PickyInteractionState(),
            .quickReply(contextID: sideSessionID, text: "first", originSource: .system, replyKind: .sideCompletion, sessionID: sideSessionID, inputID: nil),
            id: envelopeA
        ).state
        guard case .speaking(_, let speechID, _, _, _, _) = state.output else {
            Issue.record("Expected speaking after sideCompletion")
            return
        }

        // A different reply kind arrives that routes to `.showingTextReply`.
        let preempt = reduce(
            state,
            .quickReply(contextID: "main-context", text: "typed reply", originSource: .system, replyKind: .main, sessionID: nil, inputID: nil),
            id: envelopeB,
            offset: 0.05
        )
        state = preempt.state
        #expect(containsStopSpeech(reason: .superseded, speechID: speechID, in: preempt.effects))
        #expect(!isSpeakingResponseOverlayActive(state))

        // Late `.speechFinished` from the preempted utterance is stale.
        let staleFinish = reduce(state, .speechFinished(speechID: speechID), id: envelopeC, offset: 0.1)
        #expect(staleFinish.state == state)
        #expect(staleFinish.journalRecords.last?.kind == .staleEvent)

        // Eventually the text-reply min-display timer fires → idle.
        guard case .showingTextReply(_, _, let textTimer, _) = state.output, let textTimer else {
            Issue.record("Expected text reply with timer set")
            return
        }
        let finalize = reduce(
            state,
            .minimumDisplayTimerFired(timerID: textTimer, speechID: nil, inputID: nil),
            id: UUID(),
            offset: PickyInteractionReducer.minimumDisplayDuration + 0.1
        )
        #expect(finalize.state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(finalize.state))
    }

    @Test func voiceReplyThenQuickInputPreemptionThenSubmissionFailureEndsAtIdleWithoutSpeakingOverlay() {
        // A voice-owned reply produces speaking(A).
        var state = PickyInteractionState()
        state.contextOwnership[voiceContextID] = .voice(inputID: inputA)
        state = reduce(
            state,
            .quickReply(contextID: voiceContextID, text: "voice answer", originSource: .voice, replyKind: .main, sessionID: nil, inputID: inputA),
            id: envelopeA,
            correlation: .init(inputID: inputA, contextID: voiceContextID, speechID: speechA, source: .agent)
        ).state
        guard case .speaking = state.output else {
            Issue.record("Expected speaking after voice reply")
            return
        }

        // Quick input preempts → waitingForAgent.
        state = reduce(
            state,
            .textSubmitted(text: "follow up", inputID: inputB),
            id: envelopeB,
            correlation: .init(inputID: inputB, source: .quickInput)
        ).state
        guard case .waitingForAgent = state.output else {
            Issue.record("Expected waitingForAgent after quick input preemption, got \(state.output)")
            return
        }
        #expect(!isSpeakingResponseOverlayActive(state))

        // Quick input submission fails → idle.
        state = reduce(
            state,
            .textSubmissionFailed(message: "boom", inputID: inputB),
            id: envelopeC
        ).state
        #expect(state.output == .idle)
        #expect(!isSpeakingResponseOverlayActive(state))
    }

    // MARK: - Group E: idempotency / correctness regressions

    @Test func preemptionFromIdleStateIsNoOp() {
        let initial = PickyInteractionState()

        let transition = reduce(
            initial,
            .quickReply(contextID: "ctx", text: "hi", originSource: .system, replyKind: .main, sessionID: nil, inputID: nil),
            id: envelopeA
        )

        // No `.stopSpeech` effect — there was nothing to preempt.
        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
    }

    @Test func preemptionFromShowingTextReplyStateIsNoOp() {
        var initial = PickyInteractionState()
        initial.output = .showingTextReply(
            contextID: "ctx",
            text: "old reply",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate
        )

        let transition = reduce(
            initial,
            .quickReply(contextID: "ctx2", text: "newer reply", originSource: .system, replyKind: .main, sessionID: nil, inputID: nil),
            id: envelopeA
        )

        #expect(!containsStopSpeech(reason: .superseded, in: transition.effects))
    }

    // MARK: - Test helpers

    private func reduce(
        _ state: PickyInteractionState,
        _ event: PickyInteractionEvent,
        id: UUID,
        offset: TimeInterval = 0,
        correlation: PickyInteractionCorrelation = .init(source: .unknown)
    ) -> PickyInteractionTransition {
        PickyInteractionReducer.reduce(
            state: state,
            envelope: PickyInteractionEnvelope(
                id: id,
                occurredAt: baseDate.addingTimeInterval(offset),
                event: event,
                correlation: correlation
            )
        )
    }

    private func speakingState(
        contextID: String,
        speechID: UUID,
        text: String = "speaking text",
        timerID: UUID? = nil,
        minimumDisplayUntil: Date? = nil,
        finishPending: Bool = false
    ) -> PickyInteractionState {
        var state = PickyInteractionState()
        state.output = .speaking(
            contextID: contextID,
            speechID: speechID,
            text: text,
            minimumDisplayTimerID: timerID,
            minimumDisplayUntil: minimumDisplayUntil,
            finishPending: finishPending
        )
        state.overlay = .visible(reason: [.speakingResponse])
        return state
    }

    private func isSpeakingResponseOverlayActive(_ state: PickyInteractionState) -> Bool {
        if case .visible(let reasons) = state.overlay {
            return reasons.contains(.speakingResponse)
        }
        return false
    }

    private func makeContext(id: String, source: String, transcript: String?) -> PickyContextPacket {
        PickyContextPacket(
            id: id,
            source: source,
            capturedAt: baseDate,
            transcript: transcript,
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }

    /// Returns true if `effects` contains a `.stopSpeech` for `reason`. When
    /// `speechID` is supplied, the match also pins the carried speechID so
    /// tests can lock the reducer's contract that *the preempted utterance*
    /// is reported — not whatever runs next.
    private func containsStopSpeech(
        reason: PickySpeechStopReason,
        speechID: UUID? = nil,
        in effects: [PickyInteractionEffect]
    ) -> Bool {
        effects.contains { effect in
            guard case .stopSpeech(let actualReason, let actualSpeechID) = effect else { return false }
            guard actualReason == reason else { return false }
            return speechID == nil || actualSpeechID == speechID
        }
    }

    /// Convenience matcher that fails with a descriptive message if `output`
    /// is not the expected `.showingTextReply` shape.
    private func expectShowingTextReply(
        _ output: PickyOutputPhase,
        contextID expectedContextID: String,
        text expectedText: String,
        timerID expectedTimerID: UUID?
    ) {
        guard case .showingTextReply(let contextID, let text, let timerID, _) = output else {
            Issue.record("Expected showingTextReply, got \(output)")
            return
        }
        #expect(contextID == expectedContextID)
        #expect(text == expectedText)
        #expect(timerID == expectedTimerID)
    }
}
