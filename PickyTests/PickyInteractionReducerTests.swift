import Foundation
import Testing
@testable import Picky

struct PickyInteractionReducerTests {
    private let inputA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let inputB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let timerA = UUID(uuidString: "10000000-0000-0000-0000-00000000000A")!
    private let timerB = UUID(uuidString: "10000000-0000-0000-0000-00000000000B")!
    private let speechA = UUID(uuidString: "20000000-0000-0000-0000-00000000000A")!
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func staleMinimumDisplayTimerIsIgnoredWhenNewReplyIsVisible() {
        var state = PickyInteractionState()
        state = reduce(state, .quickReply(contextID: "ctx-a", text: "reply A", originSource: .text, replyKind: .main, sessionID: nil, inputID: inputA), id: timerA).state
        state = reduce(state, .quickReply(contextID: "ctx-b", text: "reply B", originSource: .text, replyKind: .main, sessionID: nil, inputID: inputB), id: timerB).state

        let transition = reduce(state, .minimumDisplayTimerFired(timerID: timerA, speechID: nil, inputID: inputA), id: UUID(uuidString: "30000000-0000-0000-0000-00000000000A")!)

        #expect(transition.state.output == .showingTextReply(
            contextID: "ctx-b",
            text: "reply B",
            minimumDisplayTimerID: timerB,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration)
        ))
        #expect(transition.journalRecords.first?.kind == .staleEvent)
    }

    @Test func quickReplyImmediateSpeechFinishKeepsDisplayUntilMatchingTimerFires() {
        var state = PickyInteractionState()
        state.contextOwnership["voice-context"] = .voice(inputID: inputA)

        let reply = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "spoken reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: speechA, source: .agent)
        )
        #expect(reply.effects == [
            .scheduleMinimumDisplay(timerID: timerA, speechID: speechA, inputID: inputA, delay: PickyInteractionReducer.minimumDisplayDuration),
            .speak(speechID: speechA, text: "spoken reply", contextID: "voice-context")
        ])

        let finished = reduce(reply.state, .speechFinished(speechID: speechA), id: UUID(uuidString: "30000000-0000-0000-0000-00000000000B")!)
        #expect(finished.state.output == .speaking(
            contextID: "voice-context",
            speechID: speechA,
            text: "spoken reply",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration),
            finishPending: true
        ))

        let cleared = reduce(finished.state, .minimumDisplayTimerFired(timerID: timerA, speechID: speechA, inputID: inputA), id: UUID(uuidString: "30000000-0000-0000-0000-00000000000C")!, offset: PickyInteractionReducer.minimumDisplayDuration)
        #expect(cleared.state.output == .idle)
    }

    @Test func speakableQuickRepliesQueueBehindCurrentSpeech() {
        var state = PickyInteractionState()
        state.contextOwnership["voice-context"] = .voice(inputID: inputA)

        state = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "first reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: speechA, source: .agent)
        ).state

        let queued = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "second reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerB,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: inputB, source: .agent)
        )

        #expect(queued.effects.isEmpty)
        #expect(queued.state.queuedSpeechReplies.map(\.text) == ["second reply"])
        #expect(queued.journalRecords.last?.message == "Voice quick reply queued")

        let started = reduce(
            queued.state,
            .speechFinished(speechID: speechA),
            id: UUID(uuidString: "30000000-0000-0000-0000-00000000000F")!,
            offset: PickyInteractionReducer.minimumDisplayDuration + 0.1
        )

        #expect(started.state.queuedSpeechReplies.isEmpty)
        #expect(started.effects == [
            .scheduleMinimumDisplay(timerID: timerB, speechID: inputB, inputID: inputA, delay: PickyInteractionReducer.minimumDisplayDuration),
            .speak(speechID: inputB, text: "second reply", contextID: "voice-context")
        ])
        let expectedSecondDeadline = baseDate
            .addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration + 0.1)
            .addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration)
        #expect(started.state.output == .speaking(
            contextID: "voice-context",
            speechID: inputB,
            text: "second reply",
            minimumDisplayTimerID: timerB,
            minimumDisplayUntil: expectedSecondDeadline,
            finishPending: false
        ))
        #expect(started.journalRecords.last?.message == "Queued voice quick reply started")
    }

    @Test func pendingSpeechQueueClearsWhenNewUserInputStarts() {
        var state = PickyInteractionState()
        state.contextOwnership["voice-context"] = .voice(inputID: inputA)
        state = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "first reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: speechA, source: .agent)
        ).state
        state = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "queued reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerB,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: inputB, source: .agent)
        ).state

        let interrupted = reduce(
            state,
            .textSubmitted(text: "new request", inputID: inputB),
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            correlation: .init(inputID: inputB, source: .quickInput)
        )

        #expect(interrupted.state.queuedSpeechReplies.isEmpty)
        #expect(interrupted.effects.contains(.stopSpeech(reason: .superseded, speechID: speechA)))
    }

    @Test func quickReplyImmediateSpeechFailureKeepsDisplayUntilMatchingTimerFires() {
        var state = PickyInteractionState()
        state.contextOwnership["voice-context"] = .voice(inputID: inputA)

        let reply = reduce(
            state,
            .quickReply(contextID: "voice-context", text: "spoken reply", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "voice-context", speechID: speechA, source: .agent)
        )
        let failed = reduce(reply.state, .speechFailed(speechID: speechA), id: UUID(uuidString: "30000000-0000-0000-0000-00000000000D")!)

        #expect(failed.state.output == .speaking(
            contextID: "voice-context",
            speechID: speechA,
            text: "spoken reply",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration),
            finishPending: true
        ))

        let cleared = reduce(failed.state, .minimumDisplayTimerFired(timerID: timerA, speechID: speechA, inputID: inputA), id: UUID(uuidString: "30000000-0000-0000-0000-00000000000E")!, offset: PickyInteractionReducer.minimumDisplayDuration)
        #expect(cleared.state.output == .idle)
    }

    @Test func notifyPickleCompletionQuickReplySpeaksEvenWhenSystemOriginated() {
        let transition = reduce(
            PickyInteractionState(),
            .quickReply(contextID: "pickle-session", text: "피클 작업이 완료됐습니다.", originSource: .system, replyKind: .pickleCompletion, sessionID: "pickle-session", inputID: nil),
            id: timerA
        )

        #expect(transition.state.output == .speaking(
            contextID: "pickle-session",
            speechID: timerA,
            text: "피클 작업이 완료됐습니다.",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration),
            finishPending: false
        ))
        #expect(transition.state.lastDisplayMessage?.source == .pickleCompletion)
        #expect(transition.effects == [
            .scheduleMinimumDisplay(timerID: timerA, speechID: timerA, inputID: nil, delay: PickyInteractionReducer.minimumDisplayDuration),
            .speak(speechID: timerA, text: "피클 작업이 완료됐습니다.", contextID: "pickle-session")
        ])
    }

    @Test func textContextCapturedRecordsOwnershipBeforeSubmitEffect() {
        var state = PickyInteractionState()
        state.pendingTextInputs[inputA] = PickyTextInputState(text: "hello")
        state.input = .textSubmitting(inputID: inputA, text: "hello")
        let context = context(id: "text-context", source: "text", transcript: "hello")

        let transition = reduce(state, .textContextCaptured(inputID: inputA, context: context), id: timerA)

        #expect(transition.state.contextOwnership["text-context"] == .text(inputID: inputA))
        #expect(transition.effects == [
            .recordContextOwnership(inputID: inputA, contextID: "text-context", owner: .text(inputID: inputA)),
            .submitText(inputID: inputA, context: context, text: "hello")
        ])
    }

    @Test func quickReplyMetadataDecodingIsTolerant() throws {
        let missing = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello"}}"#)
        #expect(missing == .quickReply(contextID: "ctx", text: "hello", originSource: .unknown, replyKind: .unknown, sessionID: nil, inputID: nil))

        let invalid = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","originSource":"wat","replyKind":"nope"}}"#)
        #expect(invalid == .quickReply(contextID: "ctx", text: "hello", originSource: .unknown, replyKind: .unknown, sessionID: nil, inputID: nil))

        let hyphenated = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","originSource":"voice-follow-up","replyKind":"pickle-completion"}}"#)
        #expect(hyphenated == .quickReply(contextID: "ctx", text: "hello", originSource: .voiceFollowUp, replyKind: .pickleCompletion, sessionID: nil, inputID: nil))

        let legacyVoice = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","source":"voice"}}"#)
        #expect(legacyVoice == .quickReply(contextID: "ctx", text: "hello", originSource: .voice, replyKind: .unknown, sessionID: nil, inputID: nil))

        let legacyMain = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","source":"main"}}"#)
        #expect(legacyMain == .quickReply(contextID: "ctx", text: "hello", originSource: .unknown, replyKind: .main, sessionID: nil, inputID: nil))
    }

    @Test func externalContextCapturedRegistersCliOwnerAndEntersWaitingForAgent() {
        // CLI submissions skip the textSubmitted/voicePressed lifecycle, so the reducer
        // needs externalContextCaptured to flip the cursor into the loading/processing
        // state. Without this transition the cursor stays idle until the quickReply
        // arrives and the user sees no "thinking" feedback.
        let inputID = UUID()
        let packet = context(id: "context-cli-1", source: "cli", transcript: "hello from cli")
        let transition = reduce(
            PickyInteractionState(),
            .externalContextCaptured(inputID: inputID, text: "hello from cli", context: packet),
            id: timerA,
            correlation: .init(inputID: inputID, contextID: packet.id, source: .system)
        )

        #expect(transition.state.contextOwnership["context-cli-1"] == .cli)
        #expect(transition.state.output == .waitingForAgent(
            inputID: inputID,
            contextID: "context-cli-1",
            promptPreview: "hello from cli"
        ))
        #expect(transition.effects.contains(.recordContextOwnership(inputID: inputID, contextID: "context-cli-1", owner: .cli)))
    }

    @Test func cliCursorOwnerMarksWaitingForCursorResponseProjection() {
        // CompanionManager flips voiceState to .processing only when the projection
        // reports isWaitingForCursorResponse. That requires the cursor owner to use
        // cursor-response presentation, which is the whole point of .cli. Guards the
        // projection contract that drives the cursor loading state for CLI submits.
        let inputID = UUID()
        let packet = context(id: "context-cli-2", source: "cli", transcript: "loading test")
        let transition = reduce(
            PickyInteractionState(),
            .externalContextCaptured(inputID: inputID, text: "loading test", context: packet),
            id: timerA
        )
        let projection = PickyInteractionProjection(state: transition.state)
        #expect(projection.isWaitingForCursorResponse == true)
    }

    // MARK: - PTT/voice + CLI race scenarios (Q1: voice priority)

    @Test func externalContextCapturedWhileVoiceListeningPreservesVoicePhase() {
        // PTT held -> input is .voiceListening. A CLI submit's externalContextCaptured
        // must not flip the output state (the user's voice turn hasn't completed yet)
        // and must not preëmpt any in-flight speaking output. Only the ownership
        // entry is registered so the eventual CLI quickReply still routes through the
        // .cli owner.
        var state = PickyInteractionState()
        state.input = .voiceListening(inputID: inputA, targetSessionID: nil)
        let voicePacket = context(id: "context-cli-during-voice", source: "cli", transcript: "hello from cli")
        let externalInput = UUID()
        let transition = reduce(state, .externalContextCaptured(inputID: externalInput, text: "hello from cli", context: voicePacket), id: timerA)

        #expect(transition.state.input == .voiceListening(inputID: inputA, targetSessionID: nil))
        #expect(transition.state.output == .idle, "output must stay idle so the cursor's listening glyph wins over the CLI loading state")
        #expect(transition.state.contextOwnership["context-cli-during-voice"] == .cli)
        #expect(transition.effects.contains(.recordContextOwnership(inputID: externalInput, contextID: "context-cli-during-voice", owner: .cli)))
        // No stopSpeech / preëmption effects because no speech was in flight.
        let stopSpeechEffects = transition.effects.filter { if case .stopSpeech = $0 { return true } else { return false } }
        #expect(stopSpeechEffects.isEmpty)
    }

    @Test func externalContextCapturedWhileVoiceFinalizingPreservesVoicePhase() {
        // Same policy as listening, exercised against the .voiceFinalizing phase to
        // guard the full "hasActiveVoiceInput" surface (listening + finalizing +
        // submitting all count as active).
        var state = PickyInteractionState()
        state.input = .voiceFinalizing(inputID: inputA, targetSessionID: nil, transcriptPreview: "i was saying")
        let packet = context(id: "context-cli-during-finalize", source: "cli", transcript: "cli text")
        let transition = reduce(state, .externalContextCaptured(inputID: inputB, text: "cli text", context: packet), id: timerA)

        #expect(transition.state.input == .voiceFinalizing(inputID: inputA, targetSessionID: nil, transcriptPreview: "i was saying"))
        #expect(transition.state.output == .idle)
        #expect(transition.state.contextOwnership["context-cli-during-finalize"] == .cli)
    }

    @Test func externalContextCapturedWhileVoiceSubmittingPreservesVoicePhase() {
        var state = PickyInteractionState()
        state.input = .voiceSubmitting(inputID: inputA, targetSessionID: nil, transcript: "done")
        let packet = context(id: "context-cli-during-submit", source: "cli", transcript: "cli text")
        let transition = reduce(state, .externalContextCaptured(inputID: inputB, text: "cli text", context: packet), id: timerA)

        #expect(transition.state.input == .voiceSubmitting(inputID: inputA, targetSessionID: nil, transcript: "done"))
        #expect(transition.state.output == .idle)
        #expect(transition.state.contextOwnership["context-cli-during-submit"] == .cli)
    }

    @Test func cliQuickReplyDuringActiveVoiceInputFallsBackToSilentTextReply() {
        // End-to-end Q1 verification: after externalContextCaptured registers .cli
        // ownership during PTT, the corresponding quickReply must NOT speak (would
        // talk over the user) and must show as a text-only reply.
        var state = PickyInteractionState()
        state.input = .voiceListening(inputID: inputA, targetSessionID: nil)
        let packet = context(id: "context-cli-race-tts", source: "cli", transcript: "hello")
        state = reduce(state, .externalContextCaptured(inputID: inputB, text: "hello", context: packet), id: timerA).state
        #expect(state.contextOwnership["context-cli-race-tts"] == .cli)

        let replyTransition = reduce(state, .quickReply(contextID: "context-cli-race-tts", text: "answer", originSource: .cli, replyKind: .main, sessionID: nil, inputID: nil), id: timerB)

        let speakEffects = replyTransition.effects.filter { if case .speak = $0 { return true } else { return false } }
        #expect(speakEffects.isEmpty, "TTS must not fire while voice input is active")
        if case .showingTextReply(let contextID, let text, _, _) = replyTransition.state.output {
            #expect(contextID == "context-cli-race-tts")
            #expect(text == "answer")
        } else {
            Issue.record("expected .showingTextReply, got \(replyTransition.state.output)")
        }
    }

    // MARK: - Speaking + CLI race scenarios (Q2: queue behind in-flight TTS)

    @Test func externalContextCapturedWhileSpeakingDoesNotPreemptInFlightTTS() {
        // Q2: if a previous reply is currently speaking, a CLI submit's
        // externalContextCaptured must not interrupt it. The reducer only registers
        // the ownership; the running .speaking output stays put. When CLI's quickReply
        // arrives the existing `.speaking -> queuedSpeechReplies.append` branch kicks
        // in and the queue drains in FIFO order.
        var state = PickyInteractionState()
        state.contextOwnership["prior-voice-ctx"] = .voice(inputID: inputA)
        state = reduce(
            state,
            .quickReply(contextID: "prior-voice-ctx", text: "talking", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "prior-voice-ctx", speechID: speechA, source: .agent)
        ).state
        guard case .speaking(_, let runningSpeechID, _, _, _, _) = state.output else {
            Issue.record("expected .speaking after prior voice quickReply")
            return
        }

        let packet = context(id: "context-cli-during-speech", source: "cli", transcript: "cli text")
        let transition = reduce(state, .externalContextCaptured(inputID: inputB, text: "cli text", context: packet), id: timerB)

        #expect(transition.state.output == state.output, "speaking state must be preserved verbatim")
        let stopSpeechEffects = transition.effects.filter { if case .stopSpeech = $0 { return true } else { return false } }
        #expect(stopSpeechEffects.isEmpty, "the in-flight TTS must not be cancelled")
        #expect(transition.state.contextOwnership["context-cli-during-speech"] == .cli)
        _ = runningSpeechID
    }

    @Test func cliQuickReplyArrivingDuringSpeakingIsQueuedBehindCurrentTTS() {
        // Q2 end-to-end: after Q2's externalContextCaptured policy leaves the output
        // in .speaking, the matching CLI quickReply must enqueue rather than start
        // its own startSpeakingReply. Then when the running TTS finishes (driven by
        // minimumDisplayTimerFired in production; for the test we just check the
        // queuedSpeechReplies array), the CLI reply is ready to drain.
        var state = PickyInteractionState()
        state.contextOwnership["prior-voice-ctx"] = .voice(inputID: inputA)
        state = reduce(state, .quickReply(contextID: "prior-voice-ctx", text: "talking", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA), id: timerA, correlation: .init(inputID: inputA, contextID: "prior-voice-ctx", speechID: speechA, source: .agent)).state

        let packet = context(id: "context-cli-queued", source: "cli", transcript: "cli text")
        state = reduce(state, .externalContextCaptured(inputID: inputB, text: "cli text", context: packet), id: timerB).state

        let queuedTransition = reduce(state, .quickReply(contextID: "context-cli-queued", text: "cli answer", originSource: .cli, replyKind: .main, sessionID: nil, inputID: nil), id: UUID())

        #expect(queuedTransition.state.queuedSpeechReplies.count == 1)
        #expect(queuedTransition.state.queuedSpeechReplies.first?.contextID == "context-cli-queued")
        #expect(queuedTransition.state.queuedSpeechReplies.first?.text == "cli answer")
        if case .speaking(let speakingContextID, _, _, _, _, _) = queuedTransition.state.output {
            #expect(speakingContextID == "prior-voice-ctx", "the original speaking reply must still own the output")
        } else {
            Issue.record("expected .speaking to be preserved while the CLI reply is queued")
        }
    }

    // MARK: - Idle baseline (regression: don't break the loading-cursor path)

    @Test func externalContextCapturedWhileIdleEntersWaitingForAgent() {
        // The earlier loading-cursor test covered the happy path; this one re-asserts
        // that the voice/speaking-aware branches did NOT regress the idle case.
        let packet = context(id: "context-cli-idle", source: "cli", transcript: "hi")
        let transition = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hi", context: packet), id: timerA)
        if case .waitingForAgent(let inputID, let contextID, let promptPreview) = transition.state.output {
            #expect(inputID == inputA)
            #expect(contextID == "context-cli-idle")
            #expect(promptPreview == "hi")
        } else {
            Issue.record("expected .waitingForAgent in the idle baseline")
        }
        #expect(transition.state.contextOwnership["context-cli-idle"] == .cli)
    }

    @Test func externalContextCapturedClearsQueuedRepliesOnlyWhenIdle() {
        // Idle path clears queued speech replies (parity with voiceContextCaptured).
        // Voice/speaking-aware paths must not, otherwise we'd lose previously queued
        // voice answers when a CLI submit slips in.
        var state = PickyInteractionState()
        state.queuedSpeechReplies = [
            PickyQueuedSpeechReply(contextID: "queued-ctx", text: "queued", timerID: timerA, speechID: speechA, inputID: nil, displaySource: .voiceReply)
        ]
        let packet = context(id: "context-cli-idle-clear", source: "cli", transcript: "hi")
        let idleTransition = reduce(state, .externalContextCaptured(inputID: inputA, text: "hi", context: packet), id: timerB)
        #expect(idleTransition.state.queuedSpeechReplies.isEmpty, "idle CLI submit clears the queue (matches voiceContextCaptured semantics)")

        var voiceState = state
        voiceState.input = .voiceListening(inputID: inputA, targetSessionID: nil)
        let voiceBusyTransition = reduce(voiceState, .externalContextCaptured(inputID: inputB, text: "hi", context: packet), id: timerB)
        #expect(voiceBusyTransition.state.queuedSpeechReplies.count == 1, "voice-priority path must preserve queued voice replies")
    }

    @Test func cliOwnershipIsPreservedAcrossVoiceTurnSoLaterQuickReplyStillRoutesAsCli() {
        // Even when the user's voice turn lands its own quickReply first, the CLI
        // ownership entry must survive so the eventual CLI quickReply maps to the
        // .cli owner (bubble + TTS) instead of falling back to .unknown.
        var state = PickyInteractionState()
        state.input = .voiceListening(inputID: inputA, targetSessionID: nil)
        let cliPacket = context(id: "context-cli-survives", source: "cli", transcript: "hi")
        state = reduce(state, .externalContextCaptured(inputID: inputB, text: "hi", context: cliPacket), id: timerA).state
        #expect(state.contextOwnership["context-cli-survives"] == .cli)

        // Voice turn lands its own quickReply (different contextID).
        state.contextOwnership["voice-ctx"] = .voice(inputID: inputA)
        state.input = .idle
        state = reduce(state, .quickReply(contextID: "voice-ctx", text: "voice answer", originSource: nil, replyKind: .main, sessionID: nil, inputID: inputA), id: timerB, correlation: .init(inputID: inputA, contextID: "voice-ctx", source: .agent)).state

        // CLI ownership entry must still be there.
        #expect(state.contextOwnership["context-cli-survives"] == .cli)
    }

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

    private func decodeQuickReply(_ json: String) throws -> PickyInteractionEvent {
        try JSONDecoder().decode(PickyInteractionEvent.self, from: Data(json.utf8))
    }

    private func context(id: String, source: String, transcript: String?) -> PickyContextPacket {
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
}
