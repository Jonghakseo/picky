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

    @Test func notifySideCompletionQuickReplySpeaksEvenWhenSystemOriginated() {
        let transition = reduce(
            PickyInteractionState(),
            .quickReply(contextID: "side-session", text: "사이드 에이전트 작업이 완료됐습니다.", originSource: .system, replyKind: .sideCompletion, sessionID: "side-session", inputID: nil),
            id: timerA
        )

        #expect(transition.state.output == .speaking(
            contextID: "side-session",
            speechID: timerA,
            text: "사이드 에이전트 작업이 완료됐습니다.",
            minimumDisplayTimerID: timerA,
            minimumDisplayUntil: baseDate.addingTimeInterval(PickyInteractionReducer.minimumDisplayDuration),
            finishPending: false
        ))
        #expect(transition.state.lastDisplayMessage?.source == .sideCompletion)
        #expect(transition.effects == [
            .scheduleMinimumDisplay(timerID: timerA, speechID: timerA, inputID: nil, delay: PickyInteractionReducer.minimumDisplayDuration),
            .speak(speechID: timerA, text: "사이드 에이전트 작업이 완료됐습니다.", contextID: "side-session")
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

        let hyphenated = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","originSource":"voice-follow-up","replyKind":"side-completion"}}"#)
        #expect(hyphenated == .quickReply(contextID: "ctx", text: "hello", originSource: .voiceFollowUp, replyKind: .sideCompletion, sessionID: nil, inputID: nil))

        let legacyVoice = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","source":"voice"}}"#)
        #expect(legacyVoice == .quickReply(contextID: "ctx", text: "hello", originSource: .voice, replyKind: .unknown, sessionID: nil, inputID: nil))

        let legacyMain = try decodeQuickReply(#"{"quickReply":{"contextId":"ctx","text":"hello","source":"main"}}"#)
        #expect(legacyMain == .quickReply(contextID: "ctx", text: "hello", originSource: .unknown, replyKind: .main, sessionID: nil, inputID: nil))
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
