import CoreGraphics
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

        // Queued replies are prefetched so incremental providers can warm their
        // audio during the current utterance (no-op for non-incremental ones).
        #expect(queued.effects == [.prefetchSpeech(text: "second reply")])
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

    @Test func narrationChunksQueueInOrderAndFinalReplyDoesNotRepeatThem() {
        var state = PickyInteractionState()
        state.contextOwnership["voice-context"] = .voice(inputID: inputA)

        let first = reduce(
            state,
            .narrationChunk(contextID: "voice-context", text: "첫 문장.", originSource: .voice, replyKind: .main, sessionID: nil, shouldSpeak: true, shouldSpeakFinalReply: false),
            id: timerA,
            correlation: .init(contextID: "voice-context", speechID: speechA, source: .agent)
        )
        let second = reduce(
            first.state,
            .narrationChunk(contextID: "voice-context", text: "둘째 문장.", originSource: .voice, replyKind: .main, sessionID: nil, shouldSpeak: true, shouldSpeakFinalReply: false),
            id: timerB,
            correlation: .init(contextID: "voice-context", speechID: inputB, source: .agent)
        )
        #expect(second.state.queuedSpeechReplies.map(\.text) == ["둘째 문장."])
        // The queued sentence is prefetched so its audio warms while the first plays.
        #expect(second.effects.contains(.prefetchSpeech(text: "둘째 문장.")))

        let final = reduce(
            second.state,
            .streamedQuickReplyFinal(contextID: "voice-context", text: "첫 문장. 둘째 문장.", originSource: .voice, replyKind: .main, sessionID: nil, inputID: inputA),
            id: UUID()
        )
        #expect(final.state.queuedSpeechReplies.map(\.text) == ["둘째 문장."])
        #expect(final.effects.isEmpty)
        #expect(final.state.lastDisplayMessage?.text == "첫 문장. 둘째 문장.")
    }

    @Test func ordinaryNarrationProjectsCompletedSentencesWithoutIncrementalTTS() {
        var state = PickyInteractionState()
        state.contextOwnership["stream-context"] = .quickInputText(inputID: inputA)

        let first = reduce(
            state,
            .narrationChunk(contextID: "stream-context", text: "첫 문장.", originSource: .text, replyKind: .main, sessionID: nil, shouldSpeak: false, shouldSpeakFinalReply: true),
            id: timerA
        )
        let second = reduce(
            first.state,
            .narrationChunk(contextID: "stream-context", text: "둘째 문장.", originSource: .text, replyKind: .main, sessionID: nil, shouldSpeak: false, shouldSpeakFinalReply: true),
            id: timerB
        )

        #expect(PickyInteractionProjection(state: first.state).latestDisplayText == "첫 문장.")
        #expect(PickyInteractionProjection(state: second.state).latestDisplayText == "첫 문장. 둘째 문장.")
        #expect(second.state.finalNarrationSpeechContextIDs == ["stream-context"])
        #expect(second.effects.isEmpty)
    }

    @Test func ttsDisabledNarrationKeepsSentenceStreamWithoutCreatingFinalSpeech() {
        var state = PickyInteractionState()
        state.contextOwnership["silent-context"] = .quickInputText(inputID: inputA)
        state.output = .waitingForAgent(inputID: inputA, contextID: "silent-context", promptPreview: "question")

        let sentence = reduce(
            state,
            .narrationChunk(contextID: "silent-context", text: "보이는 문장.", originSource: .text, replyKind: .main, sessionID: nil, shouldSpeak: false, shouldSpeakFinalReply: false),
            id: timerA
        )
        let final = reduce(
            sentence.state,
            .streamedQuickReplyFinal(contextID: "silent-context", text: "보이는 문장.", originSource: .text, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerB
        )

        #expect(PickyInteractionProjection(state: final.state).latestDisplayText == "보이는 문장.")
        if case .showingTextReply(let contextID, let text, _, _) = final.state.output {
            #expect(contextID == "silent-context")
            #expect(text == "보이는 문장.")
        } else {
            Issue.record("expected silent stream to settle as showingTextReply")
        }
        #expect(final.effects == [
            .scheduleMinimumDisplay(timerID: timerB, speechID: nil, inputID: inputA, delay: PickyInteractionReducer.minimumDisplayDuration)
        ])
        #expect(final.state.finalNarrationSpeechContextIDs.isEmpty)
    }

    @Test func emptyCommittedVisualRevealsWithoutBorrowingBubbleText() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .quickInputText(inputID: inputA)
        let identity = visualIdentity(segmentID: "empty-segment", ordinal: 0)
        let target = PickyPointerTarget(
            id: "empty-pointer",
            screenLocation: CGPoint(x: 10, y: 10),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            bubbleText: "navigation label",
            duration: 0.5
        )

        state = reduce(state, .visualNarrationSegmentPrepared(identity: identity, visual: .point(target)), id: timerA).state
        let committed = reduce(
            state,
            .visualNarrationSegmentCommitted(identity: identity, text: nil, sentenceCount: 0),
            id: timerB
        )
        let projection = PickyInteractionProjection(state: committed.state)

        #expect(committed.state.activeVisualNarrationIdentity == identity)
        #expect(committed.state.activeVisualNarrationSentenceCount == 0)
        #expect(committed.state.pointer.target?.id == "empty-pointer")
        #expect(projection.latestDisplayText == nil)
        #expect(projection.hasActivePointVisualNarration == false)
    }

    @Test func invalidatedVisualTurnRejectsFreshSegmentIDsAfterUserInput() {
        var state = PickyInteractionState()
        let oldIdentity = visualIdentity(segmentID: "old-a", ordinal: 0)
        let lateIdentity = visualIdentity(segmentID: "old-b", ordinal: 1)
        let target = PickyPointerTarget(
            id: "old-pointer",
            screenLocation: .zero,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            duration: 0.5
        )

        state = reduce(state, .visualNarrationSegmentPrepared(identity: oldIdentity, visual: .point(target)), id: timerA).state
        state = reduce(state, .agentAnnotationsClearedForUserInput, id: timerB).state
        let stale = reduce(
            state,
            .visualNarrationSegmentPrepared(identity: lateIdentity, visual: .point(target)),
            id: UUID()
        )

        #expect(stale.state.visualNarrationSegments.isEmpty)
        #expect(stale.state.activeVisualNarrationTurnIdentity == nil)
        #expect(stale.state.invalidatedVisualNarrationTurnIdentities.contains(
            PickyVisualNarrationTurnIdentity(segmentIdentity: oldIdentity)
        ))
        #expect(stale.journalRecords.last?.kind == .staleEvent)
    }

    @Test func mainSessionResetStopsSpeechAndTombstonesVisualTurn() throws {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .voice(inputID: inputA)
        let identity = visualIdentity(segmentID: "reset-segment", ordinal: 0)
        let target = PickyPointerTarget(
            id: "reset-pointer",
            screenLocation: .zero,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            duration: 0.5
        )
        state = reduce(state, .visualNarrationSegmentPrepared(identity: identity, visual: .point(target)), id: UUID()).state
        state = reduce(
            state,
            .visualNarrationSegmentSentence(identity: identity, index: 0, text: "reset me.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerA,
            correlation: .init(contextID: "visual-context", speechID: speechA, source: .agent)
        ).state

        let reset = reduce(state, .mainAgentSessionReset, id: timerB)

        #expect(reset.state.output == .idle)
        #expect(reset.state.visualNarrationSegments.isEmpty)
        #expect(reset.state.activeVisualNarrationTurnIdentity == nil)
        #expect(reset.state.invalidatedVisualNarrationTurnIdentities.contains(
            PickyVisualNarrationTurnIdentity(segmentIdentity: identity)
        ))
        #expect(reset.effects.contains(.stopSpeech(reason: .superseded, speechID: speechA)))
        let roundTripped = try JSONDecoder().decode(
            PickyInteractionEvent.self,
            from: JSONEncoder().encode(PickyInteractionEvent.mainAgentSessionReset)
        )
        #expect(roundTripped == .mainAgentSessionReset)
    }

    @Test func ordinaryNarrationAfterVisualBarrierClearsVisualAtMatchingSpeechStart() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .voice(inputID: inputA)
        let identity = visualIdentity(segmentID: "before-malformed-barrier", ordinal: 0)
        let target = PickyPointerTarget(
            id: "barrier-pointer",
            screenLocation: .zero,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            duration: 0.5
        )

        state = reduce(state, .visualNarrationSegmentPrepared(identity: identity, visual: .point(target)), id: UUID()).state
        state = reduce(
            state,
            .visualNarrationSegmentSentence(identity: identity, index: 0, text: "시각 설명.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerA,
            correlation: .init(contextID: "visual-context", speechID: speechA, source: .agent)
        ).state
        state = reduce(
            state,
            .speechStarted(text: "시각 설명.", speechID: speechA, sourceContextID: "visual-context"),
            id: UUID()
        ).state
        #expect(state.activeVisualNarrationIdentity == identity)

        state = reduce(
            state,
            .narrationChunk(contextID: "visual-context", text: "barrier 뒤 설명.", originSource: .voice, replyKind: .main, sessionID: nil, shouldSpeak: true, shouldSpeakFinalReply: false),
            id: timerB,
            correlation: .init(contextID: "visual-context", speechID: inputB, source: .agent)
        ).state
        #expect(state.activeVisualNarrationIdentity == identity)

        state = reduce(state, .speechFinished(speechID: speechA), id: UUID(), offset: 1).state
        #expect(state.activeVisualNarrationIdentity == identity)
        let startedOrdinary = reduce(
            state,
            .speechStarted(text: "barrier 뒤 설명.", speechID: inputB, sourceContextID: "visual-context"),
            id: UUID(),
            offset: 1.1
        )

        #expect(startedOrdinary.state.activeVisualNarrationIdentity == nil)
        #expect(PickyInteractionProjection(state: startedOrdinary.state).latestDisplayText == "barrier 뒤 설명.")
    }

    @Test func visualNarrationFinalReplyModeActivatesAndAccumulatesBySentence() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .quickInputText(inputID: inputA)
        let identity = visualIdentity(segmentID: "segment-a", ordinal: 0)
        let target = PickyPointerTarget(
            id: "pointer-a",
            screenLocation: CGPoint(x: 30, y: 40),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            bubbleText: "target label",
            duration: 0.5
        )

        let prepared = reduce(
            state,
            .visualNarrationSegmentPrepared(identity: identity, visual: .point(target)),
            id: timerA
        )
        #expect(PickyInteractionProjection(state: prepared.state).latestDisplayText == nil)

        let first = reduce(
            prepared.state,
            .visualNarrationSegmentSentence(identity: identity, index: 0, text: "첫 문장.", originSource: .text, replyKind: .main, sessionID: nil, playbackMode: .finalReply),
            id: timerB
        )
        #expect(first.state.activeVisualNarrationIdentity == identity)
        #expect(first.state.pointer.target?.id == "pointer-a")
        #expect(PickyInteractionProjection(state: first.state).latestDisplayText == "첫 문장.")
        #expect(PickyInteractionProjection(state: first.state).hasActivePointVisualNarration)

        let second = reduce(
            first.state,
            .visualNarrationSegmentSentence(identity: identity, index: 1, text: "둘째 문장.", originSource: .text, replyKind: .main, sessionID: nil, playbackMode: .finalReply),
            id: UUID()
        )
        #expect(PickyInteractionProjection(state: second.state).latestDisplayText == "첫 문장. 둘째 문장.")
        #expect(second.state.finalNarrationSpeechContextIDs == ["visual-context"])
    }

    @Test func visualNarrationJoinsSentenceBeforePrepareAndIgnoresDuplicateOrMismatchedIdentity() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .quickInputText(inputID: inputA)
        let identity = visualIdentity(segmentID: "segment-race", ordinal: 0)
        let staleIdentity = PickyVisualNarrationSegmentIdentity(
            contextId: identity.contextId,
            contextGeneration: identity.contextGeneration,
            turnToken: "stale-turn",
            segmentId: identity.segmentId,
            ordinal: identity.ordinal
        )
        let sentence = PickyInteractionEvent.visualNarrationSegmentSentence(
            identity: identity,
            index: 0,
            text: "먼저 온 문장.",
            originSource: .text,
            replyKind: .main,
            sessionID: nil,
            playbackMode: .silent
        )

        state = reduce(state, sentence, id: timerA).state
        #expect(state.activeVisualNarrationIdentity == nil)
        let duplicate = reduce(state, sentence, id: timerB)
        #expect(duplicate.journalRecords.last?.kind == .staleEvent)

        let stale = reduce(
            duplicate.state,
            .visualNarrationSegmentPrepared(
                identity: staleIdentity,
                visual: .point(PickyPointerTarget(id: "stale", screenLocation: .zero, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 0.5))
            ),
            id: UUID()
        )
        #expect(stale.state.activeVisualNarrationIdentity == nil)
        #expect(stale.journalRecords.last?.kind == .staleEvent)

        let prepared = reduce(
            stale.state,
            .visualNarrationSegmentPrepared(
                identity: identity,
                visual: .point(PickyPointerTarget(id: "joined", screenLocation: .zero, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 0.5))
            ),
            id: UUID()
        )
        #expect(prepared.state.activeVisualNarrationIdentity == identity)
        #expect(PickyInteractionProjection(state: prepared.state).latestDisplayText == "먼저 온 문장.")
    }

    @Test func incrementalVisualNarrationWaitsForMatchingSpeechStartAndDoesNotRevealFutureSegmentEarly() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .voice(inputID: inputA)
        let identityA = visualIdentity(segmentID: "segment-a", ordinal: 0)
        let identityB = visualIdentity(segmentID: "segment-b", ordinal: 1)
        let targetA = PickyPointerTarget(id: "pointer-a", screenLocation: .zero, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 0.5)
        let targetB = PickyPointerTarget(id: "pointer-b", screenLocation: CGPoint(x: 50, y: 50), displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 0.5)

        state = reduce(state, .visualNarrationSegmentPrepared(identity: identityA, visual: .point(targetA)), id: UUID()).state
        state = reduce(state, .visualNarrationSegmentPrepared(identity: identityB, visual: .point(targetB)), id: UUID()).state
        let sentenceA = reduce(
            state,
            .visualNarrationSegmentSentence(identity: identityA, index: 0, text: "A 설명.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerA,
            correlation: .init(contextID: "visual-context", speechID: speechA, source: .agent)
        )
        #expect(sentenceA.state.activeVisualNarrationIdentity == nil)

        let startedA = reduce(sentenceA.state, .speechStarted(text: "A 설명.", speechID: speechA, sourceContextID: "visual-context"), id: UUID())
        #expect(startedA.state.activeVisualNarrationIdentity == identityA)
        #expect(PickyInteractionProjection(state: startedA.state).latestDisplayText == "A 설명.")

        let sentenceB = reduce(
            startedA.state,
            .visualNarrationSegmentSentence(identity: identityB, index: 0, text: "B 설명.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerB,
            correlation: .init(contextID: "visual-context", speechID: inputB, source: .agent)
        )
        #expect(sentenceB.state.activeVisualNarrationIdentity == identityA)
        #expect(PickyInteractionProjection(state: sentenceB.state).latestDisplayText == "A 설명.")

        let draining = reduce(sentenceB.state, .speechFinished(speechID: speechA), id: UUID(), offset: 1)
        #expect(draining.state.activeVisualNarrationIdentity == identityA)
        let startedB = reduce(draining.state, .speechStarted(text: "B 설명.", speechID: inputB, sourceContextID: "visual-context"), id: UUID(), offset: 1.1)
        #expect(startedB.state.activeVisualNarrationIdentity == identityB)
        #expect(PickyInteractionProjection(state: startedB.state).latestDisplayText == "B 설명.")
    }

    @Test func incrementalSentenceThatStartedSpeakingBeforePrepareActivatesOnPrepare() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .voice(inputID: inputA)
        let identity = visualIdentity(segmentID: "segment-late-prepare", ordinal: 0)

        // Sentence arrives and starts speaking before its geometry (prepare) lands.
        let sentence = reduce(
            state,
            .visualNarrationSegmentSentence(identity: identity, index: 0, text: "A 설명.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerA,
            correlation: .init(contextID: "visual-context", speechID: speechA, source: .agent)
        )
        let started = reduce(
            sentence.state,
            .speechStarted(text: "A 설명.", speechID: speechA, sourceContextID: "visual-context"),
            id: UUID()
        )
        // No geometry yet, so activation cannot happen.
        #expect(started.state.activeVisualNarrationIdentity == nil)

        let prepared = reduce(
            started.state,
            .visualNarrationSegmentPrepared(identity: identity, visual: .point(PickyPointerTarget(id: "late-pointer", screenLocation: .zero, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), duration: 0.5))),
            id: UUID()
        )

        #expect(prepared.state.activeVisualNarrationIdentity == identity)
        #expect(prepared.state.pointer.target?.id == "late-pointer")
        #expect(PickyInteractionProjection(state: prepared.state).latestDisplayText == "A 설명.")
    }

    @Test func emptyAnnotationSegmentsRevealInSourceOrderNotAllAtFirstCompletion() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .voice(inputID: inputA)
        let seg0 = visualIdentity(segmentID: "seg-0", ordinal: 0)
        let seg1 = visualIdentity(segmentID: "seg-1", ordinal: 1)
        let seg2 = visualIdentity(segmentID: "seg-2", ordinal: 2)
        let seg3 = visualIdentity(segmentID: "seg-3", ordinal: 3)

        // seg0 (non-empty) starts speaking and reveals its RECT.
        state = reduce(state, .visualNarrationSegmentPrepared(identity: seg0, visual: .annotations([annotation(id: "rect-0")])), id: UUID()).state
        state = reduce(
            state,
            .visualNarrationSegmentSentence(identity: seg0, index: 0, text: "설명 0.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerA,
            correlation: .init(contextID: "visual-context", speechID: speechA, source: .agent)
        ).state
        state = reduce(state, .speechStarted(text: "설명 0.", speechID: speechA, sourceContextID: "visual-context"), id: UUID()).state
        #expect(state.agentAnnotations.map(\.id) == ["rect-0"])

        // While seg0 is still speaking, an empty RECT (seg1), a non-empty RECT (seg2),
        // and another empty RECT (seg3) all arrive. Empty segments buffer.
        state = reduce(state, .visualNarrationSegmentPrepared(identity: seg1, visual: .annotations([annotation(id: "rect-1")])), id: UUID()).state
        state = reduce(state, .visualNarrationSegmentCommitted(identity: seg1, text: nil, sentenceCount: 0), id: UUID()).state
        state = reduce(state, .visualNarrationSegmentPrepared(identity: seg2, visual: .annotations([annotation(id: "rect-2")])), id: UUID()).state
        state = reduce(
            state,
            .visualNarrationSegmentSentence(identity: seg2, index: 0, text: "설명 2.", originSource: .voice, replyKind: .main, sessionID: nil, playbackMode: .incremental),
            id: timerB,
            correlation: .init(contextID: "visual-context", speechID: inputB, source: .agent)
        ).state
        state = reduce(state, .visualNarrationSegmentPrepared(identity: seg3, visual: .annotations([annotation(id: "rect-3")])), id: UUID()).state
        state = reduce(state, .visualNarrationSegmentCommitted(identity: seg3, text: nil, sentenceCount: 0), id: UUID()).state
        #expect(state.agentAnnotations.map(\.id) == ["rect-0"])

        // seg0's speech completes: only its immediate follower seg1 reveals. The
        // distant empty seg3 must NOT jump ahead of seg2.
        state = reduce(state, .speechFinished(speechID: speechA), id: UUID(), offset: 1).state
        #expect(state.agentAnnotations.map(\.id) == ["rect-0", "rect-1"])

        // seg2 speaks and reveals its RECT, then its completion flushes the trailing
        // empty seg3 last, preserving source order end to end.
        state = reduce(state, .speechStarted(text: "설명 2.", speechID: inputB, sourceContextID: "visual-context"), id: UUID(), offset: 1.1).state
        #expect(state.agentAnnotations.map(\.id) == ["rect-0", "rect-1", "rect-2"])
        state = reduce(state, .speechFinished(speechID: inputB), id: UUID(), offset: 2).state
        #expect(state.agentAnnotations.map(\.id) == ["rect-0", "rect-1", "rect-2", "rect-3"])
    }

    @Test func suspendedVisualAnnotationKeepsItsProgressiveBubbleWhileHidingGeometry() {
        var state = PickyInteractionState()
        state.contextOwnership["visual-context"] = .quickInputText(inputID: inputA)
        state.annotationScenePhase = .suspended
        let identity = visualIdentity(segmentID: "segment-annotation", ordinal: 0)
        state = reduce(
            state,
            .visualNarrationSegmentPrepared(identity: identity, visual: .annotations([annotation(id: "visual-rect")])),
            id: timerA
        ).state
        state = reduce(
            state,
            .visualNarrationSegmentSentence(identity: identity, index: 0, text: "숨겨진 설명.", originSource: .text, replyKind: .main, sessionID: nil, playbackMode: .silent),
            id: timerB
        ).state

        #expect(state.activeVisualNarrationIdentity == identity)
        #expect(PickyInteractionProjection(state: state).latestDisplayText == "숨겨진 설명.")
        #expect(PickyInteractionProjection(state: state).agentAnnotations.isEmpty)
        #expect(PickyInteractionProjection(state: state).hasActivePointVisualNarration == false)

        state.annotationScenePhase = .visible
        #expect(PickyInteractionProjection(state: state).latestDisplayText == "숨겨진 설명.")
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

    @Test func quickReplyMainStillSpeaksOnQuickInputOwnership() {
        // A regular main reply on Quick Input ownership MUST still trigger
        // TTS / speaking output. This pins the behaviour contract so a future
        // change can't accidentally short-circuit other replyKinds.
        var state = PickyInteractionState()
        state.contextOwnership["ctx-quick"] = .quickInputText(inputID: inputA)
        state.output = .waitingForAgent(inputID: inputA, contextID: "ctx-quick", promptPreview: "hello")

        let transition = reduce(
            state,
            .quickReply(contextID: "ctx-quick", text: "spoken reply", originSource: .text, replyKind: .main, sessionID: nil, inputID: inputA),
            id: timerA,
            correlation: .init(inputID: inputA, contextID: "ctx-quick", speechID: speechA, source: .agent)
        )

        #expect(transition.effects.contains(.speak(speechID: speechA, text: "spoken reply", contextID: "ctx-quick")))
    }

    @Test func narrationChunkPlaybackFlagRoundTripsAndDefaultsToSpeaking() throws {
        let legacyData = #"{"narrationChunk":{"contextID":"ctx","text":"legacy"}}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(PickyInteractionEvent.self, from: legacyData)
        #expect(legacy == .narrationChunk(
            contextID: "ctx",
            text: "legacy",
            originSource: nil,
            replyKind: nil,
            sessionID: nil,
            shouldSpeak: true,
            shouldSpeakFinalReply: false
        ))

        let timingOnly = PickyInteractionEvent.narrationChunk(
            contextID: "ctx",
            text: "timing",
            originSource: .text,
            replyKind: .main,
            sessionID: nil,
            shouldSpeak: false,
            shouldSpeakFinalReply: true
        )
        let roundTripped = try JSONDecoder().decode(PickyInteractionEvent.self, from: JSONEncoder().encode(timingOnly))
        #expect(roundTripped == timingOnly)
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

    // MARK: - sessionTerminated (HUD abort / agentd-side terminal status without quickReply)

    @Test func sessionTerminatedDropsWaitingForAgentForCliSubmission() {
        // CLI submission flips into .waitingForAgent via externalContextCaptured. When the
        // backing Pickle is aborted from HUD (or fails on agentd), no quickReply ever lands,
        // so the reducer must accept a synthetic .sessionTerminated event to drop the cursor
        // loading state. Otherwise the cursor stays yellow forever.
        let packet = context(id: "context-cli-aborted", source: "cli", transcript: "hello")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hello", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "context-cli-aborted", sessionID: "pickle-X", inputID: inputA), id: timerB).state
        #expect(state.output == .waitingForAgent(inputID: inputA, contextID: "context-cli-aborted", promptPreview: "hello"))

        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-X"), id: UUID())

        #expect(terminated.state.output == .idle, "cli waitingForAgent must transition to idle on terminal status")
        if case .visible(let reasons) = terminated.state.overlay {
            #expect(!reasons.contains(.waitingForVoiceResponse), "the waitingForVoiceResponse overlay reason must be released")
        }
    }

    @Test func sessionTerminatedDropsWaitingForAgentForQuickInputSubmission() {
        // quickInput-source text submission also drives .waitingForAgent + cursor presentation.
        var state = PickyInteractionState()
        state = reduce(state, .textSubmitted(text: "hi", inputID: inputA), id: timerA, correlation: .init(inputID: inputA, source: .quickInput)).state
        state = reduce(state, .textContextCaptured(inputID: inputA, context: context(id: "ctx-qi", source: "quickInput", transcript: "hi")), id: timerB).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "ctx-qi", sessionID: "pickle-Q", inputID: inputA), id: UUID()).state
        #expect(state.output == .waitingForAgent(inputID: inputA, contextID: "ctx-qi", promptPreview: "hi"))

        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-Q"), id: UUID())

        #expect(terminated.state.output == .idle)
    }

    @Test func sessionTerminatedIgnoresUnknownSession() {
        // A terminal status for a session the reducer never saw (e.g. another tab's session)
        // must be a no-op. The cursor must not be released for an unrelated session.
        let packet = context(id: "context-cli-other", source: "cli", transcript: "hello")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hello", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "context-cli-other", sessionID: "pickle-A", inputID: inputA), id: timerB).state
        let before = state

        let terminated = reduce(state, .sessionTerminated(sessionID: "some-other-session"), id: UUID())

        #expect(terminated.state.output == before.output)
        #expect(terminated.state.contextOwnership == before.contextOwnership)
        #expect(terminated.journalRecords.last?.kind == .staleEvent)
    }

    @Test func sessionTerminatedClearsExternalAcceptedRequestWithoutInputID() {
        // External CLI Pickle creation gets a client-side synthetic inputID when
        // context capture begins, but agentd's later accepted event only carries
        // contextID + sessionID. The terminal cleanup must still release the
        // cursor by matching the stable contextID.
        let packet = context(id: "context-cli-accepted", source: "cli", transcript: "hello")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hello", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "context-cli-accepted", sessionID: "pickle-external", inputID: nil), id: timerB).state
        #expect(state.output == .waitingForAgent(inputID: inputA, contextID: "context-cli-accepted", promptPreview: "hello"))

        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-external"), id: UUID())

        #expect(terminated.state.output == .idle)
        #expect(terminated.state.pendingAgentRequestsBySession["pickle-external"] == nil)
    }

    @Test func sessionTerminatedIsIdempotent() {
        // After quickReply already cleared .waitingForAgent, or after a previous
        // sessionTerminated already ran, another .sessionTerminated for the same
        // session must be a safe no-op (PTT interrupt + agentd-side cancel can both fire).
        let packet = context(id: "context-cli-idem", source: "cli", transcript: "hello")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hello", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "context-cli-idem", sessionID: "pickle-I", inputID: inputA), id: timerB).state

        state = reduce(state, .sessionTerminated(sessionID: "pickle-I"), id: UUID()).state
        #expect(state.output == .idle)

        let second = reduce(state, .sessionTerminated(sessionID: "pickle-I"), id: UUID())
        #expect(second.state.output == .idle)
        #expect(second.journalRecords.last?.kind == .staleEvent)
    }

    @Test func sessionTerminatedAfterQuickReplyDoesNotRevertReply() {
        // Race: quickReply arrives, then later sessionUpdated reports a terminal status.
        // The quickReply already moved output to .showingTextReply/.speaking; the late
        // .sessionTerminated must not yank that visible reply.
        let packet = context(id: "context-cli-race", source: "cli", transcript: "hello")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hello", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "context-cli-race", sessionID: "pickle-R", inputID: inputA), id: timerB).state
        state = reduce(state, .quickReply(contextID: "context-cli-race", text: "answer", originSource: .cli, replyKind: .main, sessionID: "pickle-R", inputID: inputA), id: UUID()).state
        let outputBefore = state.output

        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-R"), id: UUID())

        #expect(terminated.state.output == outputBefore, "a late terminal status must not clobber an already-displayed reply")
    }

    @Test func sessionTerminatedOnlyClearsWaitingForMatchingSession() {
        // Two CLI submissions, both still pending. The reducer overwrites the previous
        // .waitingForAgent so the visible cursor belongs to submission B. A late terminal
        // for session A must not touch B's cursor — the session-id mapping is what
        // distinguishes the two.
        let packetA = context(id: "ctx-A", source: "cli", transcript: "A")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "A", context: packetA), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "ctx-A", sessionID: "pickle-A", inputID: inputA), id: timerB).state

        let packetB = context(id: "ctx-B", source: "cli", transcript: "B")
        state = reduce(state, .externalContextCaptured(inputID: inputB, text: "B", context: packetB), id: UUID()).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "ctx-B", sessionID: "pickle-B", inputID: inputB), id: UUID()).state
        #expect(state.output == .waitingForAgent(inputID: inputB, contextID: "ctx-B", promptPreview: "B"))

        // Late terminal for A must not touch B's cursor (different inputID + contextID).
        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-A"), id: UUID())
        #expect(terminated.state.output == .waitingForAgent(inputID: inputB, contextID: "ctx-B", promptPreview: "B"))
        // Cleanup still happened for A's mapping entry.
        #expect(terminated.state.pendingAgentRequestsBySession["pickle-A"] == nil)
        #expect(terminated.state.pendingAgentRequestsBySession["pickle-B"] != nil, "B's mapping must survive A's termination")
    }

    @Test func sessionTerminatedClearsPendingInputStateForAbortedSession() {
        // After abort the pending input slot for that turn must also be released so the
        // input phase returns to idle. Otherwise the next user input would race with stale
        // pendingTextInputs/pendingVoiceInputs entries.
        let packet = context(id: "ctx-cleanup", source: "cli", transcript: "hi")
        var state = reduce(PickyInteractionState(), .externalContextCaptured(inputID: inputA, text: "hi", context: packet), id: timerA).state
        state = reduce(state, .agentSubmissionAccepted(contextID: "ctx-cleanup", sessionID: "pickle-C", inputID: inputA), id: timerB).state

        let terminated = reduce(state, .sessionTerminated(sessionID: "pickle-C"), id: UUID())

        #expect(terminated.state.pendingTextInputs[inputA] == nil)
        #expect(terminated.state.pendingVoiceInputs[inputA] == nil)
    }

    @Test func sessionTerminatedJSONRoundTripsViaProtocol() throws {
        // The event is part of the codable interaction protocol so journal persistence
        // and (potential future) cross-boundary replay must survive a roundtrip.
        let event = PickyInteractionEvent.sessionTerminated(sessionID: "pickle-J")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(PickyInteractionEvent.self, from: data)
        #expect(decoded == event)
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

    @Test func mainTurnSettledReleasesMatchingWaitingOutput() {
        var state = PickyInteractionState()
        state.output = .waitingForAgent(inputID: inputA, contextID: "ctx-overlay", promptPreview: "show me")

        let settled = reduce(state, .mainTurnSettled(contextID: "ctx-overlay"), id: timerA)
        #expect(settled.state.output == .idle)

        let duplicate = reduce(settled.state, .mainTurnSettled(contextID: "ctx-overlay"), id: timerB)
        #expect(duplicate.state.output == .idle)
    }

    @Test func annotationRequestsKeepDistinctNarrationOffsets() {
        var state = PickyInteractionState()
        state.contextOwnership["ctx"] = .voice(inputID: inputA)
        let firstText = "첫 번째 영역입니다."
        let secondText = "두 번째 영역입니다."

        state = reduce(
            state,
            .narrationChunk(contextID: "ctx", text: firstText, originSource: .voice, replyKind: .main, sessionID: nil, shouldSpeak: true, shouldSpeakFinalReply: false),
            id: timerA
        ).state
        state = reduce(
            state,
            .agentAnnotationsRequested(mode: .append, annotations: [annotation(id: "first")]),
            id: UUID()
        ).state
        state = reduce(
            state,
            .narrationChunk(contextID: "ctx", text: secondText, originSource: .voice, replyKind: .main, sessionID: nil, shouldSpeak: true, shouldSpeakFinalReply: false),
            id: timerB
        ).state
        state = reduce(
            state,
            .agentAnnotationsRequested(mode: .append, annotations: [annotation(id: "second")]),
            id: UUID()
        ).state

        #expect(state.pendingAgentAnnotations.map(\.precedingNarrationWeight) == [
            PickyNarrationPaceModel.weightedUnits(forNarration: firstText),
            PickyNarrationPaceModel.weightedUnits(forNarration: firstText)
                + PickyNarrationPaceModel.weightedUnits(forNarration: secondText),
        ])
    }

    @Test func outOfOrderAnnotationTimersRevealAndQueuePointersInArrivalOrder() {
        let requested = reduce(
            PickyInteractionState(),
            .agentAnnotationsRequested(mode: .append, annotations: [
                annotation(id: "first"),
                annotation(id: "second"),
                annotation(id: "third"),
            ]),
            id: timerA
        )
        let pendingIDs = requested.state.pendingAgentAnnotations.map(\.id)

        let thirdDue = reduce(requested.state, .agentAnnotationRevealDue(id: pendingIDs[2]), id: UUID())
        #expect(thirdDue.state.agentAnnotations.isEmpty)
        #expect(thirdDue.state.pendingAnnotationPointerTargets.isEmpty)

        let firstDue = reduce(thirdDue.state, .agentAnnotationRevealDue(id: pendingIDs[0]), id: UUID())
        #expect(firstDue.state.agentAnnotations.map(\.id) == ["first"])
        #expect(firstDue.state.activeAnnotationPointerID == "annotation-first")

        let secondDue = reduce(firstDue.state, .agentAnnotationRevealDue(id: pendingIDs[1]), id: UUID())
        #expect(secondDue.state.agentAnnotations.map(\.id) == ["first", "second", "third"])
        #expect(secondDue.state.activeAnnotationPointerID == "annotation-first")
        #expect(secondDue.state.pendingAnnotationPointerTargets.map(\.id) == ["annotation-second", "annotation-third"])
    }

    @Test func annotationPointerParksAcrossStreamGapThenHopsToNextShape() {
        let first = revealAnnotation(id: "rect", into: PickyInteractionState())
        let firstTarget = pointerTarget(from: first)
        #expect(firstTarget.id == "annotation-rect")
        #expect(firstTarget.returnsToCursor == false)
        #expect(firstTarget.parksAtTarget)

        let parked = reduce(first.state, .pointerAnimationParked(pointerID: firstTarget.id), id: timerB)
        #expect(parked.state.annotationPointerIsParked)
        #expect(parked.state.activeAnnotationPointerID == firstTarget.id)

        // A later shape reveals mid-park and converts the fly-back into a direct hop.
        let appended = revealAnnotation(id: "line", into: parked.state)
        #expect(appended.effects == [
            .setPointerParksAtTarget(pointerID: firstTarget.id, parksAtTarget: false),
            .advancePointerAnimation(pointerID: firstTarget.id),
        ])

        let hopped = reduce(appended.state, .pointerAnimationFinished(pointerID: firstTarget.id), id: UUID())
        let secondTarget = pointerTarget(from: hopped)
        #expect(secondTarget.id == "annotation-line")
        #expect(secondTarget.returnsToCursor == false)
        #expect(secondTarget.parksAtTarget)
    }

    @Test func annotationPointerReturnsOnlyWhenQuickReplyEndsParkedTurn() {
        let parked = parkedAnnotationPointerState()
        let ended = reduce(parked, .quickReply(contextID: "ctx", text: "Done", originSource: .text, replyKind: .main, sessionID: nil, inputID: inputA), id: timerA)

        #expect(ended.state.annotationPointerTurnActive == false)
        #expect(ended.state.activeAnnotationPointerReturnsToCursor)
        #expect(ended.effects.contains(.setPointerParksAtTarget(pointerID: "annotation-rect", parksAtTarget: false)))
        #expect(ended.effects.contains(.setPointerReturnsToCursor(pointerID: "annotation-rect", returnsToCursor: true)))
        #expect(!ended.effects.contains(.advancePointerAnimation(pointerID: "annotation-rect")))
    }

    @Test func annotationPointerReturnsOnlyWhenMainTurnSettledEndsParkedTurn() {
        let parked = parkedAnnotationPointerState()
        let ended = reduce(parked, .mainTurnSettled(contextID: "ctx"), id: timerA)

        #expect(ended.state.annotationPointerTurnActive == false)
        #expect(ended.state.activeAnnotationPointerReturnsToCursor)
        #expect(ended.effects.contains(.setPointerParksAtTarget(pointerID: "annotation-rect", parksAtTarget: false)))
        #expect(ended.effects.contains(.setPointerReturnsToCursor(pointerID: "annotation-rect", returnsToCursor: true)))
        #expect(!ended.effects.contains(.advancePointerAnimation(pointerID: "annotation-rect")))
    }

    @Test func annotationBuddyReturnsOnlyAfterSpeechDrainsWhenSettledMidSpeech() {
        let parked = parkedAnnotationPointerState()
        var speaking = parked
        let speechID = UUID()
        speaking.output = .speaking(contextID: "ctx", speechID: speechID, text: "narrating", minimumDisplayTimerID: nil, minimumDisplayUntil: nil, finishPending: false)

        // The turn settles while the last utterance is still playing: the buddy must NOT
        // fly back yet (regression: it used to fly back at reply time, before the buddy
        // even started, and then never returned).
        let settled = reduce(speaking, .mainTurnSettled(contextID: "ctx"), id: timerA)
        #expect(settled.state.annotationTurnSettled)
        #expect(!settled.effects.contains(.setPointerReturnsToCursor(pointerID: "annotation-rect", returnsToCursor: true)))

        // When speech drains, narration is over and the buddy flies back.
        let drained = reduce(settled.state, .speechFinished(speechID: speechID), id: timerB)
        #expect(drained.state.agentAnnotations.map(\.id) == ["rect"])
        #expect(drained.effects.contains(.setPointerReturnsToCursor(pointerID: "annotation-rect", returnsToCursor: true)))
    }

    @Test func turnEndKeepsShapesButDropsQueuedAnnotationVisitsAndReturnsToCursor() {
        let rectReveal = revealAnnotation(id: "rect", into: PickyInteractionState())
        let firstTarget = pointerTarget(from: rectReveal)
        let queued = revealAnnotation(id: "line", into: rectReveal.state)
        let settled = reduce(queued.state, .mainTurnSettled(contextID: "ctx"), id: timerB)

        #expect(settled.state.agentAnnotations.map(\.id) == ["rect", "line"])
        #expect(settled.state.pendingAnnotationPointerTargets.isEmpty)
        #expect(settled.effects == [
            .setPointerParksAtTarget(pointerID: firstTarget.id, parksAtTarget: false),
            .setPointerReturnsToCursor(pointerID: firstTarget.id, returnsToCursor: true),
        ])
    }

    @Test func turnEndWithoutActiveAnnotationPointerDoesNotRequestFlyBack() {
        let settled = reduce(PickyInteractionState(), .mainTurnSettled(contextID: "ctx"), id: timerA)

        #expect(!settled.effects.contains { effect in
            if case .setPointerReturnsToCursor = effect { return true }
            return false
        })
        #expect(!settled.effects.contains { effect in
            if case .setPointerParksAtTarget = effect { return true }
            return false
        })
    }

    @Test func sceneSuspensionImmediatelyCancelsAnActiveAnnotationPointer() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000010")!
        )
        let initial = PickyInteractionState(
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true
        )
        let revealed = revealAnnotation(id: "rect", into: initial)
        let target = pointerTarget(from: revealed)

        let suspended = reduce(
            revealed.state,
            .agentAnnotationSceneMismatched(identity: identity, reason: .scroll),
            id: timerA
        )

        #expect(suspended.state.annotationScenePhase == .suspended)
        #expect(suspended.state.agentAnnotations.map(\.id) == ["rect"])
        #expect(suspended.state.activeAnnotationPointerID == nil)
        #expect(suspended.state.pointer == .idle)
        #expect(suspended.effects == [.cancelPointerAnimation(pointerID: target.id)])
    }

    @Test func sceneSuspensionDoesNotClearAnUnrelatedStandalonePointer() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000011")!
        )
        let target = PickyPointerTarget(
            id: "standalone",
            screenLocation: CGPoint(x: 40, y: 50),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            duration: 1
        )
        let initial = PickyInteractionState(
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true
        )
        let pointed = reduce(initial, .pointerRequested(target), id: timerA)

        let suspended = reduce(
            pointed.state,
            .agentAnnotationSceneMismatched(identity: identity, reason: .visual),
            id: timerB
        )

        #expect(suspended.state.annotationScenePhase == .suspended)
        #expect(suspended.state.pointer == .requested(target))
        if case .visible(let reasons) = suspended.state.overlay {
            #expect(reasons.contains(.activePointerAnimation))
        } else {
            Issue.record("Expected the standalone pointer overlay to remain visible")
        }
        #expect(suspended.effects.isEmpty)
    }

    @Test func standalonePointerCompletionStartsAQueuedAnnotationPointer() throws {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000014")!
        )
        let standalone = PickyPointerTarget(
            id: "standalone",
            screenLocation: CGPoint(x: 40, y: 50),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            duration: 1
        )
        let initial = PickyInteractionState(
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true
        )
        let pointed = reduce(initial, .pointerRequested(standalone), id: timerA)
        let revealed = revealAnnotation(id: "rect", into: pointed.state)
        let queuedTarget = try #require(revealed.state.pendingAnnotationPointerTargets.first)

        let finished = reduce(
            revealed.state,
            .pointerAnimationFinished(pointerID: standalone.id),
            id: timerB
        )

        #expect(finished.state.activeAnnotationPointerID == queuedTarget.id)
        #expect(finished.state.pendingAnnotationPointerTargets.isEmpty)
        #expect(finished.effects.contains { effect in
            if case .startPointerAnimation(let target) = effect {
                return target.id == queuedTarget.id
            }
            return false
        })
    }

    @Test func sceneSuspensionKeepsActiveSpeechRunning() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000012")!
        )
        let speechID = UUID(uuidString: "A0000000-0000-0000-0000-000000000013")!
        var initial = PickyInteractionState(
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true
        )
        initial.output = .speaking(
            contextID: "ctx",
            speechID: speechID,
            text: "keep speaking",
            minimumDisplayTimerID: nil,
            minimumDisplayUntil: nil,
            finishPending: false
        )

        let suspended = reduce(
            initial,
            .agentAnnotationSceneMismatched(identity: identity, reason: .visual),
            id: timerA
        )

        #expect(suspended.state.output == initial.output)
        #expect(!suspended.effects.contains { effect in
            if case .stopSpeech = effect { return true }
            return false
        })
    }

    @Test func sceneMismatchAfterNarrationClearsImmediatelyWithoutRestore() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000015")!
        )
        let speechID = UUID(uuidString: "A0000000-0000-0000-0000-000000000016")!
        var initial = PickyInteractionState(
            agentAnnotations: [annotation(id: "rect")],
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true,
            annotationTurnSettled: true
        )
        initial.output = .speaking(
            contextID: "ctx",
            speechID: speechID,
            text: "final narration",
            minimumDisplayTimerID: nil,
            minimumDisplayUntil: nil,
            finishPending: false
        )

        // EXPERIMENT (usability): narration drains while visible -> recovery locks immediately
        // with no grace timer, so the drawing stays put but can no longer suspend/restore.
        let drained = reduce(initial, .speechFinished(speechID: speechID), id: timerA)
        #expect(drained.state.agentAnnotations.map(\.id) == ["rect"])
        #expect(drained.state.annotationScenePhase == .visible)
        #expect(drained.state.annotationSceneRecoveryAllowed == false)
        #expect(!drained.effects.contains { effect in
            if case .scheduleAnnotationRecoveryExpiry = effect { return true }
            return false
        })

        // A post-narration scene change now clears the drawings for good (no suspend/restore).
        let cleared = reduce(
            drained.state,
            .agentAnnotationSceneMismatched(identity: identity, reason: .visual),
            id: timerB
        )
        #expect(cleared.state.agentAnnotations.isEmpty)
        #expect(cleared.state.annotationSceneIdentity == nil)
        #expect(cleared.state.annotationScenePhase == .inactive)
    }

    @Test func finalSpeechDrainWhileSuspendedClearsImmediately() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "ctx",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000017")!
        )
        let speechID = UUID(uuidString: "A0000000-0000-0000-0000-000000000018")!
        var initial = PickyInteractionState(
            agentAnnotations: [annotation(id: "rect")],
            annotationSceneIdentity: identity,
            annotationScenePhase: .visible,
            annotationSceneRecoveryAllowed: true,
            annotationTurnSettled: true
        )
        initial.output = .speaking(
            contextID: "ctx",
            speechID: speechID,
            text: "final narration",
            minimumDisplayTimerID: nil,
            minimumDisplayUntil: nil,
            finishPending: false
        )

        // Suspended mid-narration (user switched away during playback).
        let suspended = reduce(
            initial,
            .agentAnnotationSceneMismatched(identity: identity, reason: .visual),
            id: timerA
        )
        #expect(suspended.state.annotationScenePhase == .suspended)

        // EXPERIMENT (usability): final speech drains while suspended -> recovery locks
        // immediately, clearing the drawings now instead of holding them through a grace window.
        let drained = reduce(suspended.state, .speechFinished(speechID: speechID), id: timerB)
        #expect(drained.state.agentAnnotations.isEmpty)
        #expect(drained.state.annotationSceneIdentity == nil)
        #expect(drained.state.annotationScenePhase == .inactive)
        #expect(!drained.effects.contains { effect in
            if case .scheduleAnnotationRecoveryExpiry = effect { return true }
            return false
        })
    }

    @Test func newTextInputClearsParkedAnnotationsAndRequestsFlyBack() {
        let parked = parkedAnnotationPointerState()
        let submitted = reduce(parked, .textSubmitted(text: "next", inputID: inputA), id: timerA)

        #expect(submitted.state.agentAnnotations.isEmpty)
        #expect(submitted.state.annotationPointerTurnActive == false)
        #expect(submitted.state.activeAnnotationPointerID == "annotation-rect")
        #expect(submitted.effects.contains(.setPointerReturnsToCursor(pointerID: "annotation-rect", returnsToCursor: true)))
        #expect(!submitted.effects.contains { effect in
            if case .cancelPointerAnimation = effect { return true }
            return false
        })
    }

    private func visualIdentity(segmentID: String, ordinal: Int) -> PickyVisualNarrationSegmentIdentity {
        PickyVisualNarrationSegmentIdentity(
            contextId: "visual-context",
            contextGeneration: 1,
            turnToken: "main-turn-1",
            segmentId: segmentID,
            ordinal: ordinal
        )
    }

    private func annotation(id: String) -> PickyAgentAnnotation {
        PickyAgentAnnotation(
            id: id,
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 10, y: 20, width: 20, height: 10),
            label: nil
        )
    }

    /// Requests, anchors, and reveals one annotation so its buddy choreography starts.
    private func revealAnnotation(id annotationID: String, into state: PickyInteractionState) -> PickyInteractionTransition {
        let requested = reduce(state, .agentAnnotationsRequested(mode: .append, annotations: [annotation(id: annotationID)]), id: UUID())
        var current = requested.state
        if current.annotationSpeechAnchor == nil {
            current = reduce(current, .speechStarted(text: "n", speechID: UUID(), sourceContextID: "ctx"), id: UUID()).state
        }
        let pendingID = current.pendingAgentAnnotations.first { $0.annotation.id == annotationID }!.id
        return reduce(current, .agentAnnotationRevealDue(id: pendingID), id: UUID())
    }

    private func parkedAnnotationPointerState() -> PickyInteractionState {
        let revealed = revealAnnotation(id: "rect", into: PickyInteractionState())
        let target = pointerTarget(from: revealed)
        return reduce(revealed.state, .pointerAnimationParked(pointerID: target.id), id: timerB).state
    }

    private func pointerTarget(from transition: PickyInteractionTransition) -> PickyPointerTarget {
        guard case .startPointerAnimation(let target) = transition.effects.first else {
            fatalError("Expected annotation pointer animation")
        }
        return target
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
