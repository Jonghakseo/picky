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
