import CoreGraphics
import Foundation

private enum PickyAnnotationPointerTarget {
    /// Matches the existing rough draw-on duration closely enough for the buddy to hover
    /// while each annotation appears, without adding a second animation system.
    static let hoverDuration: TimeInterval = 0.5

    static func make(_ annotation: PickyAgentAnnotation) -> PickyPointerTarget? {
        let anchor: CGPoint
        switch annotation.shape {
        case .rect:
            guard let rect = annotation.rect else { return nil }
            anchor = CGPoint(x: rect.midX, y: rect.midY)
        case .line:
            guard let start = annotation.point, let end = annotation.endPoint else { return nil }
            anchor = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        }
        return PickyPointerTarget(
            id: "annotation-\(annotation.id)",
            source: .agent,
            screenLocation: anchor,
            displayFrame: annotation.displayFrame,
            // Shape labels remain on the annotation itself; suppress the pointer's
            // conversational bubble so it only acts as a transient drawing guide.
            bubbleText: "",
            duration: hoverDuration,
            returnsToCursor: true
        )
    }

    static func settingHoldBehavior(
        _ target: PickyPointerTarget,
        returnsToCursor: Bool,
        parksAtTarget: Bool
    ) -> PickyPointerTarget {
        PickyPointerTarget(
            id: target.id,
            source: target.source,
            screenLocation: target.screenLocation,
            displayFrame: target.displayFrame,
            bubbleText: target.bubbleText,
            duration: target.duration,
            returnsToCursor: returnsToCursor,
            parksAtTarget: parksAtTarget
        )
    }
}

struct PickyInteractionTransition: Equatable {
    var state: PickyInteractionState
    var effects: [PickyInteractionEffect]
    var journalRecords: [PickyInteractionJournalRecord]
}

enum PickyInteractionReducer {
    static let minimumDisplayDuration: TimeInterval = 0.35
    static let maximumAgentAnnotationCount = 24
    static let maximumInvalidatedVisualNarrationTurnCount = 16
    /// After narration ends, annotations stay recoverable (hide on scene change, restore
    /// when the original pixels return) for this window before the next mismatch clears
    /// them permanently. Covers a brief context switch without leaving stale drawings.
    static let annotationRecoveryGraceAfterNarration: TimeInterval = 30

    static func reduce(
        state: PickyInteractionState,
        envelope: PickyInteractionEnvelope
    ) -> PickyInteractionTransition {
        var reducing = PickyInteractionReducing(state: state, envelope: envelope)
        reducing.apply(envelope.event)
        return PickyInteractionTransition(
            state: reducing.state,
            effects: reducing.effects,
            journalRecords: reducing.records
        )
    }
}

/// Single reduction pass over one envelope. Each event has a dedicated pure
/// handler so the dispatch switch below stays a flat routing table.
private struct PickyInteractionReducing {
    var state: PickyInteractionState
    let envelope: PickyInteractionEnvelope
    var effects: [PickyInteractionEffect] = []
    var records: [PickyInteractionJournalRecord] = []

    private var minimumDisplayDuration: TimeInterval { PickyInteractionReducer.minimumDisplayDuration }

    mutating func apply(_ event: PickyInteractionEvent) {
        switch event {
        case .appStarted:
            record(.accepted, "App interaction model started")
        case .permissionsChanged, .cursorPreferenceChanged:
            record(.accepted, "Interaction environment changed")
        case .voicePressed(let targetSessionID):
            applyVoicePressed(targetSessionID: targetSessionID)
        case .voiceStartFailed(let message, let inputID):
            applyVoiceStartFailed(message: message, inputID: inputID)
        case .voiceReleased(let inputID):
            applyVoiceReleased(inputID: inputID)
        case .transcriptFinal(let text, let inputID):
            applyTranscriptFinal(text: text, inputID: inputID)
        case .transcriptFailed(let message, let inputID):
            applyTranscriptFailed(message: message, inputID: inputID)
        case .textSubmitted(let text, let inputID):
            applyTextSubmitted(text: text, inputID: inputID)
        case .textContextCaptured(let inputID, let context):
            applyTextContextCaptured(inputID: inputID, context: context)
        case .textSubmissionAccepted(_, let inputID):
            applyTextSubmissionAccepted(inputID: inputID)
        case .textSubmissionFailed(let message, let inputID):
            applyTextSubmissionFailed(message: message, inputID: inputID)
        case .voiceContextCaptured(let inputID, let transcript, let context, let targetSessionID):
            applyVoiceContextCaptured(inputID: inputID, transcript: transcript, context: context, targetSessionID: targetSessionID)
        case .externalContextCaptured(let inputID, let text, let context):
            applyExternalContextCaptured(inputID: inputID, text: text, context: context)
        case .agentSubmissionAccepted(let contextID, let sessionID, let inputID):
            applyAgentSubmissionAccepted(contextID: contextID, sessionID: sessionID, inputID: inputID)
        case .quickReply(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            applyQuickReply(contextID: contextID, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, inputID: inputID)
        case .narrationChunk(let contextID, let text, let originSource, let replyKind, let sessionID, let shouldSpeak, let shouldSpeakFinalReply):
            applyNarrationChunk(contextID: contextID, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, shouldSpeak: shouldSpeak, shouldSpeakFinalReply: shouldSpeakFinalReply)
        case .visualNarrationSegmentPrepared(let identity, let visual):
            applyVisualNarrationSegmentPrepared(identity: identity, visual: visual)
        case .visualNarrationSegmentSentence(let identity, let index, let text, let originSource, let replyKind, let sessionID, let playbackMode):
            applyVisualNarrationSegmentSentence(identity: identity, index: index, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, playbackMode: playbackMode)
        case .visualNarrationSegmentCommitted(let identity, let text, let sentenceCount):
            applyVisualNarrationSegmentCommitted(identity: identity, text: text, sentenceCount: sentenceCount)
        case .streamedQuickReplyFinal(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            applyStreamedQuickReplyFinal(contextID: contextID, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, inputID: inputID)
        case .passiveAgentSummary(let sessionID, let text):
            applyPassiveAgentSummary(sessionID: sessionID, text: text)
        case .pickleCompleted(let sessionID, let summary):
            applyPickleCompleted(sessionID: sessionID, summary: summary)
        case .mainTurnSettled(let contextID):
            applyMainTurnSettled(contextID: contextID)
        case .mainAgentSessionReset:
            applyMainAgentSessionReset()
        case .sessionTerminated(let sessionID):
            applySessionTerminated(sessionID: sessionID)
        case .pointerRequested(let target):
            applyPointerRequested(target: target)
        case .pointerCancelled(let pointerID, _):
            applyPointerCancelled(pointerID: pointerID)
        case .pointerAnimationParked(let pointerID):
            applyPointerAnimationParked(pointerID: pointerID)
        case .pointerAnimationFinished(let pointerID):
            applyPointerAnimationFinished(pointerID: pointerID)
        case .agentAnnotationsRequested(let mode, let annotations):
            applyAgentAnnotationsRequested(mode: mode, annotations: annotations)
        case .agentAnnotationScenePrepared(let identity):
            applyAgentAnnotationScenePrepared(identity: identity)
        case .agentAnnotationSceneMatched(let identity):
            applyAgentAnnotationSceneMatched(identity: identity)
        case .agentAnnotationSceneMismatched(let identity, let reason):
            applyAgentAnnotationSceneMismatched(identity: identity, reason: reason)
        case .agentAnnotationRecoveryExpired(let identity):
            applyAnnotationRecoveryExpired(identity: identity)
        case .agentAnnotationRevealDue(let id):
            applyAnnotationRevealDue(id: id)
        case .agentAnnotationsClearedForUserInput:
            clearAgentAnnotationsForUserInput()
        case .speechStarted(_, let speechID, _):
            applyAnnotationSpeechStarted(now: envelope.occurredAt)
            applyVisualNarrationBarrierSpeechStarted(speechID: speechID)
            applyVisualNarrationSpeechStarted(speechID: speechID)
            record(.accepted, "Speech provider started")
        case .speechFinished(let speechID), .speechFailed(let speechID):
            applySpeechCompleted(speechID: speechID)
        case .minimumDisplayTimerFired(let timerID, _, _):
            applyMinimumDisplayTimerFired(timerID: timerID)
        case .overlayShown(let reason):
            state = state.addingOverlayReason(reason)
            record(.stateChanged, "Overlay reason shown")
        case .overlayHidden(let reason):
            state = state.removingOverlayReason(reason)
            record(.stateChanged, "Overlay reason hidden")
        case .transientHideTimerFired(let timerID):
            applyTransientHideTimerFired(timerID: timerID)
        }
    }

    private mutating func record(_ kind: PickyInteractionJournalRecord.Kind, _ message: String) {
        records.append(
            PickyInteractionJournalRecord(
                id: envelope.id,
                envelopeID: envelope.id,
                occurredAt: envelope.occurredAt,
                event: envelope.event,
                kind: kind,
                message: message
            )
        )
    }

    // MARK: - Voice input lifecycle

    private mutating func applyVoicePressed(targetSessionID: String?) {
        clearAgentAnnotationsForUserInput()
        let inputID = envelope.correlation.inputID ?? envelope.id
        state.queuedSpeechReplies.removeAll()
        state.streamedNarrationContextIDs.removeAll()
        var preemptedSpeechID: UUID?
        if case .speaking(_, let speechID, _, _, _, _) = state.output {
            preemptedSpeechID = speechID
            state.output = .idle
            state = state.removingOverlayReason(.speakingResponse)
        }
        state.input = .voiceListening(inputID: inputID, targetSessionID: targetSessionID)
        state.pendingVoiceInputs[inputID] = PickyVoiceInputState(targetSessionID: targetSessionID)
        state = state.addingOverlayReason(.activeVoiceInput)
        effects.append(.stopSpeech(reason: .userInterrupted, speechID: preemptedSpeechID))
        // An annotation turn has already been asked to fly back by
        // clearAgentAnnotationsForUserInput(); do not snap it away mid-flight.
        if state.activeAnnotationPointerID == nil {
            effects.append(.cancelPointerAnimation(pointerID: state.pointer.target?.id))
        }
        effects.append(.showOverlay(reason: .activeVoiceInput))
        effects.append(.startDictation(inputID: inputID))
        record(.stateChanged, "Voice input started")
    }

    private mutating func applyVoiceStartFailed(message: String, inputID: UUID) {
        guard state.pendingVoiceInputs[inputID] != nil else {
            record(.staleEvent, "Ignored stale voice start failure: \(message)")
            return
        }
        state.pendingVoiceInputs[inputID] = nil
        state.input = .idle
        state = state.removingOverlayReason(.activeVoiceInput)
        record(.stateChanged, "Voice start failed")
    }

    private mutating func applyVoiceReleased(inputID: UUID) {
        guard case .voiceListening(inputID, let targetSessionID) = state.input else {
            record(.staleEvent, "Ignored stale voice release")
            return
        }
        state.input = .voiceFinalizing(inputID: inputID, targetSessionID: targetSessionID, transcriptPreview: nil)
        effects.append(.stopDictation(inputID: inputID))
        record(.stateChanged, "Voice input released")
    }

    private mutating func applyTranscriptFinal(text: String, inputID: UUID) {
        guard var voice = state.pendingVoiceInputs[inputID] else {
            record(.staleEvent, "Ignored transcript for unknown voice input")
            return
        }
        voice.transcript = text
        state.pendingVoiceInputs[inputID] = voice
        state.input = .voiceSubmitting(inputID: inputID, targetSessionID: voice.targetSessionID, transcript: text)
        state.output = .waitingForAgent(inputID: inputID, contextID: nil, promptPreview: text)
        state = state.addingOverlayReason(.waitingForVoiceResponse)
        effects.append(.captureVoiceContext(inputID: inputID, transcript: text, targetSessionID: voice.targetSessionID))
        record(.stateChanged, "Voice transcript finalized")
    }

    private mutating func applyTranscriptFailed(message: String, inputID: UUID) {
        state.queuedSpeechReplies.removeAll()
        guard state.pendingVoiceInputs[inputID] != nil else {
            record(.staleEvent, "Ignored stale transcript failure: \(message)")
            return
        }
        state.pendingVoiceInputs[inputID] = nil
        state.input = .idle
        preemptSpeakingOutputIfNeeded()
        state.output = .idle
        state = state.removingOverlayReason(.activeVoiceInput)
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        record(.stateChanged, "Voice transcript failed")
    }

    private mutating func applyVoiceContextCaptured(
        inputID: UUID,
        transcript: String,
        context: PickyContextPacket,
        targetSessionID: String?
    ) {
        guard var pendingVoice = state.pendingVoiceInputs[inputID] else {
            record(.staleEvent, "Ignored voice context for unknown input")
            return
        }
        pendingVoice.contextID = context.id
        pendingVoice.transcript = transcript
        state.pendingVoiceInputs[inputID] = pendingVoice
        state.contextOwnership[context.id] = .voice(inputID: inputID)
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: transcript)
        effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: .voice(inputID: inputID)))
        if let targetSessionID {
            effects.append(.followUpPickle(inputID: inputID, sessionID: targetSessionID, transcript: transcript, context: context))
        } else {
            effects.append(.submitMain(inputID: inputID, transcript: transcript, context: context))
        }
        record(.stateChanged, "Voice context captured before submit")
    }

    // MARK: - Text input lifecycle

    private mutating func applyTextSubmitted(text: String, inputID: UUID) {
        clearAgentAnnotationsForUserInput()
        let source = envelope.correlation.source
        state.queuedSpeechReplies.removeAll()
        state.streamedNarrationContextIDs.removeAll()
        state.input = .textSubmitting(inputID: inputID, text: text)
        state.pendingTextInputs[inputID] = PickyTextInputState(text: text, source: source)
        if source == .quickInput {
            preemptSpeakingOutputIfNeeded()
            state.output = .waitingForAgent(inputID: inputID, contextID: nil, promptPreview: text)
            state = state.addingOverlayReason(.waitingForVoiceResponse)
        }
        effects.append(.captureTextContext(inputID: inputID, text: text))
        record(.stateChanged, "Text input submitted")
    }

    private mutating func applyTextContextCaptured(inputID: UUID, context: PickyContextPacket) {
        guard var pendingText = state.pendingTextInputs[inputID] else {
            record(.staleEvent, "Ignored text context for unknown input")
            return
        }
        pendingText.contextID = context.id
        state.pendingTextInputs[inputID] = pendingText
        let owner: PickyContextOwner = pendingText.source == .quickInput ? .quickInputText(inputID: inputID) : .text(inputID: inputID)
        state.contextOwnership[context.id] = owner
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: pendingText.text)
        if pendingText.source == .quickInput {
            state = state.addingOverlayReason(.waitingForVoiceResponse)
        }
        effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: owner))
        effects.append(.submitText(inputID: inputID, context: context, text: pendingText.text))
        record(.stateChanged, "Text context captured before submit")
    }

    private mutating func applyTextSubmissionAccepted(inputID: UUID) {
        guard state.pendingTextInputs[inputID] != nil else {
            record(.staleEvent, "Ignored text submission receipt for unknown input")
            return
        }
        state.pendingTextInputs[inputID] = nil
        if case .textSubmitting(inputID, _) = state.input {
            state.input = .idle
        }
        record(.accepted, "Text submission accepted")
    }

    private mutating func applyTextSubmissionFailed(message: String, inputID: UUID) {
        guard let pendingText = state.pendingTextInputs[inputID] else {
            record(.staleEvent, "Ignored text submission failure: \(message)")
            return
        }
        state.pendingTextInputs[inputID] = nil
        if case .textSubmitting(inputID, _) = state.input { state.input = .idle }
        // Preempt any in-flight TTS regardless of source so
        // `failDirectMessage`'s direct mutation of `latestAgentSessionSummary`
        // doesn't visually clash with a still-playing utterance. We only
        // collapse the output to .idle if it was actually .speaking before
        // (or if the failure came from a quickInput submission whose
        // .waitingForAgent overlay also has to be torn down) — leaving
        // unrelated outputs (.showingTextReply, .waitingForAgent for
        // background text, .suppressedReply) untouched.
        let preemptedSpeaking: Bool
        if case .speaking = state.output {
            preemptedSpeaking = true
        } else {
            preemptedSpeaking = false
        }
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        if pendingText.source == .quickInput {
            state.output = .idle
            state = state.removingOverlayReason(.waitingForVoiceResponse)
        } else if preemptedSpeaking {
            state.output = .idle
        }
        record(.stateChanged, "Text submission failed")
    }

    // MARK: - External (CLI) input

    private mutating func applyExternalContextCaptured(inputID: UUID, text: String, context: PickyContextPacket) {
        clearAgentAnnotationsForUserInput()
        // Always register the cursor owner so the eventual quickReply matches the
        // .cli presentation policy (bubble + TTS when idle).
        state.contextOwnership[context.id] = .cli
        effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: .cli))

        // Policy:
        //  - voice in progress (PTT held / finalizing / submitting) -> user input is
        //    the priority. Do not preëmpt anything; let the running voice turn
        //    finish first. When CLI's quickReply lands, the reducer's quickReply
        //    branch sees hasActiveVoiceInput == true and renders the answer as a
        //    silent text reply (no TTS interruption of the user's utterance).
        //  - currently speaking the previous reply -> queue the CLI submission
        //    behind the running TTS. Leaving state.output == .speaking is enough:
        //    when CLI's quickReply lands, the existing
        //    `if case .speaking = state.output { state.queuedSpeechReplies.append }`
        //    branch picks it up and the queue drains in FIFO order.
        //  - otherwise (idle / waitingForAgent for an unrelated submission) ->
        //    behave like a regular voice/text submission: clear queued replies,
        //    preëmpt any leftover speaking output, and flip into .waitingForAgent
        //    so the cursor shows the loading state.
        if state.hasActiveVoiceInput {
            record(.stateChanged, "External CLI context captured while voice input is active; ownership only")
            return
        }
        if case .speaking = state.output {
            record(.stateChanged, "External CLI context captured while another reply is speaking; queued behind it")
            return
        }
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: text)
        record(.stateChanged, "External CLI context captured before submit")
    }

    // MARK: - Agent replies

    private mutating func applyAgentSubmissionAccepted(contextID: String?, sessionID: String, inputID: UUID?) {
        if let contextID, state.contextOwnership[contextID] == nil, let inputID {
            if state.pendingVoiceInputs[inputID] != nil {
                state.contextOwnership[contextID] = .voice(inputID: inputID)
            } else if state.pendingTextInputs[inputID] != nil {
                state.contextOwnership[contextID] = .text(inputID: inputID)
            }
        }
        if let inputID, let pendingVoice = state.pendingVoiceInputs[inputID] {
            state.pendingVoiceInputs[inputID] = nil
            switch state.input {
            case .voiceSubmitting(let currentInputID, _, _) where currentInputID == inputID,
                 .voiceFinalizing(let currentInputID, _, _) where currentInputID == inputID,
                 .voiceListening(let currentInputID, _) where currentInputID == inputID:
                state.input = .idle
            default:
                break
            }
            state = state.removingOverlayReason(.activeVoiceInput)
            if pendingVoice.targetSessionID != nil {
                state = state.removingOverlayReason(.waitingForVoiceResponse)
            }
        }
        // Remember the sessionID -> (inputID, contextID) link so a later
        // `.sessionTerminated` for the same session can release the cursor's
        // `.waitingForAgent` output without waiting for a `quickReply` that
        // will never arrive (HUD abort / runtime cancel).
        state.pendingAgentRequestsBySession[sessionID] = PickyPendingAgentRequest(inputID: inputID, contextID: contextID)
        record(.accepted, "Agent submission accepted for \(sessionID)")
    }

    private mutating func applyQuickReply(
        contextID: String,
        text: String,
        originSource: PickyQuickReplyOriginSource?,
        replyKind: PickyQuickReplyKind?,
        sessionID: String?,
        inputID: UUID?
    ) {
        if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }
        let timerID = envelope.id
        let deadline = envelope.occurredAt.addingTimeInterval(minimumDisplayDuration)
        let owner = state.contextOwnership[contextID] ?? ownerFromMetadata(originSource)
        let hasActiveVoiceInput = state.hasActiveVoiceInput
        let shouldSpeakReply = owner.isVoiceOwned || owner.usesCursorResponsePresentation || replyKind == .pickleCompletion
        if hasActiveVoiceInput, replyKind == .pickleCompletion {
            suppressPickleCompletionReply(contextID: contextID, text: text, timerID: timerID, deadline: deadline, inputID: inputID)
        } else if shouldSpeakReply, !hasActiveVoiceInput {
            enqueueOrSpeakQuickReply(contextID: contextID, text: text, replyKind: replyKind, owner: owner, timerID: timerID, inputID: inputID)
        } else {
            showTextQuickReply(contextID: contextID, text: text, replyKind: replyKind, timerID: timerID, deadline: deadline, inputID: inputID)
        }
        markAnnotationTurnSettled()
    }

    private mutating func applyNarrationChunk(
        contextID: String,
        text: String,
        originSource: PickyQuickReplyOriginSource?,
        replyKind: PickyQuickReplyKind?,
        sessionID: String?,
        shouldSpeak: Bool,
        shouldSpeakFinalReply: Bool
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            record(.staleEvent, "Ignored empty narration chunk")
            return
        }
        let owner = state.contextOwnership[contextID] ?? ownerFromMetadata(originSource)
        let resolvedReplyKind = replyKind ?? .main
        guard !state.hasActiveVoiceInput,
              owner.isVoiceOwned || owner.usesCursorResponsePresentation || resolvedReplyKind == .pickleCompletion else {
            record(.accepted, "Narration chunk did not require presentation")
            return
        }

        state.annotationNarrationWeight += PickyNarrationPaceModel.weightedUnits(forNarration: trimmed)
        if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }
        appendStreamedResponse(
            contextID: contextID,
            text: trimmed,
            source: displaySource(replyKind: resolvedReplyKind, owner: owner)
        )
        if shouldSpeakFinalReply { state.finalNarrationSpeechContextIDs.insert(contextID) }
        guard shouldSpeak else {
            clearActiveVisualNarration()
            record(.accepted, "Narration chunk displayed without incremental speech")
            return
        }

        let speechID = envelope.correlation.speechID ?? envelope.id
        if state.activeVisualNarrationIdentity != nil {
            state.visualNarrationClearSpeechIDs.insert(speechID)
        }
        enqueueOrSpeakQuickReply(
            contextID: contextID,
            text: trimmed,
            replyKind: resolvedReplyKind,
            owner: owner,
            timerID: envelope.id,
            inputID: nil
        )
        state.streamedNarrationContextIDs.insert(contextID)
        record(.accepted, "Narration chunk queued for speech")
    }

    private mutating func applyVisualNarrationSegmentPrepared(
        identity: PickyVisualNarrationSegmentIdentity,
        visual: PickyResolvedVisualNarrationVisual
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration prepare")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        segment.visual = visual
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
            state.visualNarrationOrder.sort {
                (state.visualNarrationSegments[$0]?.identity.ordinal ?? .max)
                    < (state.visualNarrationSegments[$1]?.identity.ordinal ?? .max)
            }
        }
        trimVisualNarrationSegmentsIfNeeded()
        if segment.expectedSentenceCount == 0 {
            queueOrActivateVisualOnlyNarration(identity)
        } else if let playbackMode = segment.sentences.first?.playbackMode,
                  playbackMode != .incremental {
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        } else if let startedSentenceIndex = state.visualNarrationSpeechMarkers.values
            .filter({ $0.identity == identity })
            .map(\.sentenceIndex).max() {
            // Incremental race: a sentence began speaking before its geometry
            // arrived, so its speechStarted activation no-op'd. Now that the
            // visual exists, activate up to the highest already-started sentence.
            activateVisualNarration(identity: identity, sentenceCount: startedSentenceIndex + 1)
        }
        record(.accepted, "Visual narration segment prepared")
    }

    private mutating func applyVisualNarrationSegmentSentence(
        identity: PickyVisualNarrationSegmentIdentity,
        index: Int,
        text: String,
        originSource: PickyQuickReplyOriginSource?,
        replyKind: PickyQuickReplyKind?,
        sessionID: String?,
        playbackMode: PickyVisualNarrationPlaybackMode
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard index >= 0, !trimmed.isEmpty else {
            record(.staleEvent, "Ignored invalid visual narration sentence")
            return
        }
        let owner = state.contextOwnership[identity.contextId] ?? ownerFromMetadata(originSource)
        let resolvedReplyKind = replyKind ?? .main
        guard !state.hasActiveVoiceInput,
              owner.isVoiceOwned || owner.usesCursorResponsePresentation || resolvedReplyKind == .pickleCompletion else {
            record(.accepted, "Visual narration sentence did not require presentation")
            return
        }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration sentence")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        guard !segment.sentences.contains(where: { $0.index == index }) else {
            record(.staleEvent, "Ignored duplicate visual narration sentence")
            return
        }
        let sentence = PickyVisualNarrationSentenceState(
            index: index,
            text: trimmed,
            precedingNarrationWeight: state.annotationNarrationWeight,
            playbackMode: playbackMode,
            originSource: originSource,
            replyKind: resolvedReplyKind,
            sessionID: sessionID
        )
        segment.sentences.append(sentence)
        segment.sentences.sort { $0.index < $1.index }
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
        }
        state.annotationNarrationWeight += PickyNarrationPaceModel.weightedUnits(forNarration: trimmed)
        if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }

        switch playbackMode {
        case .incremental:
            let marker = PickyVisualNarrationSpeechMarker(identity: identity, sentenceIndex: index)
            enqueueOrSpeakQuickReply(
                contextID: identity.contextId,
                text: trimmed,
                replyKind: resolvedReplyKind,
                owner: owner,
                timerID: envelope.id,
                inputID: nil,
                visualNarrationMarker: marker
            )
            state.streamedNarrationContextIDs.insert(identity.contextId)
        case .finalReply:
            state.finalNarrationSpeechContextIDs.insert(identity.contextId)
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        case .silent:
            activateVisualNarration(identity: identity, sentenceCount: contiguousSentenceCount(in: segment))
        }
        record(.accepted, "Visual narration sentence received")
    }

    private mutating func applyVisualNarrationSegmentCommitted(
        identity: PickyVisualNarrationSegmentIdentity,
        text: String?,
        sentenceCount: Int
    ) {
        guard acceptVisualNarrationTurn(identity) else { return }
        guard sentenceCount >= 0 else {
            record(.staleEvent, "Ignored invalid visual narration commit")
            return
        }
        if let existing = state.visualNarrationSegments[identity.segmentId], existing.identity != identity {
            record(.staleEvent, "Ignored mismatched visual narration commit")
            return
        }
        var segment = state.visualNarrationSegments[identity.segmentId] ?? PickyVisualNarrationSegmentState(
            identity: identity,
            visual: nil,
            sentences: [],
            committedText: nil,
            expectedSentenceCount: nil
        )
        segment.committedText = text
        segment.expectedSentenceCount = sentenceCount
        state.visualNarrationSegments[identity.segmentId] = segment
        if !state.visualNarrationOrder.contains(identity.segmentId) {
            state.visualNarrationOrder.append(identity.segmentId)
        }
        trimVisualNarrationSegmentsIfNeeded()
        if sentenceCount == 0 {
            queueOrActivateVisualOnlyNarration(identity)
        }
        record(.accepted, "Visual narration segment committed")
    }

    private mutating func applyVisualNarrationBarrierSpeechStarted(speechID: UUID) {
        guard state.visualNarrationClearSpeechIDs.remove(speechID) != nil else { return }
        clearActiveVisualNarration()
    }

    private mutating func applyVisualNarrationSpeechStarted(speechID: UUID) {
        guard let marker = state.visualNarrationSpeechMarkers[speechID],
              let segment = state.visualNarrationSegments[marker.identity.segmentId],
              segment.identity == marker.identity else { return }
        let contiguous = contiguousSentenceCount(in: segment)
        guard marker.sentenceIndex < contiguous else { return }
        activateVisualNarration(identity: marker.identity, sentenceCount: marker.sentenceIndex + 1)
    }

    private mutating func activateVisualNarration(
        identity: PickyVisualNarrationSegmentIdentity,
        sentenceCount: Int
    ) {
        guard sentenceCount >= 0,
              let segment = state.visualNarrationSegments[identity.segmentId],
              segment.identity == identity,
              let visual = segment.visual,
              sentenceCount > 0 || segment.expectedSentenceCount == 0 else { return }
        if state.activeVisualNarrationIdentity != identity {
            state.activeVisualNarrationIdentity = identity
            state.activeVisualNarrationSentenceCount = 0
            switch visual {
            case .point(let target):
                applyPointerRequested(target: target)
            case .annotations(let annotations):
                if let pointerID = state.pointer.target?.id,
                   state.activeAnnotationPointerID == nil {
                    effects.append(.cancelPointerAnimation(pointerID: pointerID))
                    state.pointer = .idle
                    state = state.removingOverlayReason(.activePointerAnimation)
                }
                for annotation in annotations { revealAnnotation(annotation) }
            }
        }
        state.activeVisualNarrationSentenceCount = max(
            state.activeVisualNarrationSentenceCount,
            min(sentenceCount, contiguousSentenceCount(in: segment))
        )
    }

    private mutating func clearActiveVisualNarration() {
        state.activeVisualNarrationIdentity = nil
        state.activeVisualNarrationSentenceCount = 0
    }

    private mutating func queueOrActivateVisualOnlyNarration(_ identity: PickyVisualNarrationSegmentIdentity) {
        guard let segment = state.visualNarrationSegments[identity.segmentId],
              segment.identity == identity,
              segment.expectedSentenceCount == 0,
              segment.visual != nil else { return }
        if annotationSpeechActive {
            if !state.pendingVisualOnlyNarrationIdentities.contains(identity) {
                state.pendingVisualOnlyNarrationIdentities.append(identity)
            }
        } else {
            activateVisualNarration(identity: identity, sentenceCount: 0)
        }
    }

    private func contiguousSentenceCount(in segment: PickyVisualNarrationSegmentState) -> Int {
        var expected = 0
        for sentence in segment.sentences {
            guard sentence.index == expected else { break }
            expected += 1
        }
        return expected
    }

    private mutating func trimVisualNarrationSegmentsIfNeeded() {
        while state.visualNarrationOrder.count > PickyInteractionReducer.maximumAgentAnnotationCount {
            let removedID = state.visualNarrationOrder.removeFirst()
            if state.activeVisualNarrationIdentity?.segmentId == removedID { continue }
            state.visualNarrationSegments[removedID] = nil
        }
    }

    private mutating func acceptVisualNarrationTurn(_ identity: PickyVisualNarrationSegmentIdentity) -> Bool {
        let turnIdentity = PickyVisualNarrationTurnIdentity(segmentIdentity: identity)
        guard !state.invalidatedVisualNarrationTurnIdentities.contains(turnIdentity) else {
            record(.staleEvent, "Ignored visual narration event from invalidated turn")
            return false
        }
        if let activeTurn = state.activeVisualNarrationTurnIdentity,
           activeTurn != turnIdentity {
            record(.staleEvent, "Ignored visual narration event from non-active turn")
            return false
        }
        state.activeVisualNarrationTurnIdentity = turnIdentity
        return true
    }

    private mutating func invalidateActiveVisualNarrationTurn(contextID: String? = nil) {
        guard let activeTurn = state.activeVisualNarrationTurnIdentity,
              contextID == nil || activeTurn.contextId == contextID else { return }
        if !state.invalidatedVisualNarrationTurnIdentities.contains(activeTurn) {
            state.invalidatedVisualNarrationTurnIdentities.append(activeTurn)
            let overflow = max(
                0,
                state.invalidatedVisualNarrationTurnIdentities.count
                    - PickyInteractionReducer.maximumInvalidatedVisualNarrationTurnCount
            )
            if overflow > 0 {
                state.invalidatedVisualNarrationTurnIdentities.removeFirst(overflow)
            }
        }
        state.activeVisualNarrationTurnIdentity = nil
    }

    private mutating func applyStreamedQuickReplyFinal(
        contextID: String,
        text: String,
        originSource: PickyQuickReplyOriginSource?,
        replyKind: PickyQuickReplyKind?,
        sessionID: String?,
        inputID: UUID?
    ) {
        if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }
        defer { invalidateActiveVisualNarrationTurn(contextID: contextID) }
        if !state.streamedNarrationContextIDs.contains(contextID) {
            let shouldSpeakFinal = state.finalNarrationSpeechContextIDs.remove(contextID) != nil
            let hasProgressiveDisplay = state.streamedResponseContextID == contextID
                || state.activeVisualNarrationIdentity?.contextId == contextID
            if shouldSpeakFinal {
                concludeProgressiveNarrationSpeech(contextID: contextID)
                applyQuickReply(contextID: contextID, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, inputID: inputID)
                return
            }
            if !hasProgressiveDisplay {
                applyQuickReply(contextID: contextID, text: text, originSource: originSource, replyKind: replyKind, sessionID: sessionID, inputID: inputID)
                return
            }

            // TTS-off replies still use the normal text-reply terminal state so the
            // waiting cursor and progressive bubble cannot remain active indefinitely.
            concludeProgressiveNarrationSpeech(contextID: contextID)
            let timerID = envelope.id
            showTextQuickReply(
                contextID: contextID,
                text: text,
                replyKind: replyKind,
                timerID: timerID,
                deadline: envelope.occurredAt.addingTimeInterval(minimumDisplayDuration),
                inputID: inputID
            )
            markAnnotationTurnSettled()
            record(.stateChanged, "Final quick reply settled silent streamed narration")
            return
        }
        let owner = state.contextOwnership[contextID] ?? ownerFromMetadata(originSource)
        let source = displaySource(replyKind: replyKind, owner: owner)
        state.streamedResponseContextID = contextID
        state.streamedResponseText = text
        state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: source, updatedAt: envelope.occurredAt)
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        markAnnotationTurnSettled()
        record(.accepted, "Final quick reply retained streamed narration queue")
    }

    private mutating func suppressPickleCompletionReply(
        contextID: String,
        text: String,
        timerID: UUID,
        deadline: Date,
        inputID: UUID?
    ) {
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        state.output = .suppressedReply(
            contextID: contextID,
            text: text,
            reason: .activeVoiceInput,
            minimumDisplayTimerID: timerID,
            minimumDisplayUntil: deadline
        )
        effects.append(.scheduleMinimumDisplay(timerID: timerID, speechID: nil, inputID: inputID, delay: minimumDisplayDuration))
        state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: .suppressed, updatedAt: envelope.occurredAt)
        record(.stateChanged, "Suppressed Pickle completion quick reply while voice input is active")
    }

    private mutating func enqueueOrSpeakQuickReply(
        contextID: String,
        text: String,
        replyKind: PickyQuickReplyKind?,
        owner: PickyContextOwner,
        timerID: UUID,
        inputID: UUID?,
        visualNarrationMarker: PickyVisualNarrationSpeechMarker? = nil
    ) {
        let speechID = envelope.correlation.speechID ?? envelope.id
        let displaySource: PickyDisplaySource = replyKind == .pickleCompletion ? .pickleCompletion : (owner.usesCursorResponsePresentation ? .textReply : .voiceReply)
        let queuedReply = PickyQueuedSpeechReply(
            contextID: contextID,
            text: text,
            timerID: timerID,
            speechID: speechID,
            inputID: inputID,
            displaySource: displaySource,
            visualNarrationMarker: visualNarrationMarker
        )
        if case .speaking = state.output {
            state.queuedSpeechReplies.append(queuedReply)
            // Warm this sentence's audio now so it is ready before the currently
            // playing sentence finishes (no-op for non-incremental providers).
            effects.append(.prefetchSpeech(text: text))
            record(.accepted, "Voice quick reply queued")
        } else {
            startSpeakingReply(queuedReply, occurredAt: envelope.occurredAt)
            record(.stateChanged, "Voice quick reply is speaking")
        }
    }

    private mutating func showTextQuickReply(
        contextID: String,
        text: String,
        replyKind: PickyQuickReplyKind?,
        timerID: UUID,
        deadline: Date,
        inputID: UUID?
    ) {
        state.queuedSpeechReplies.removeAll()
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        preemptSpeakingOutputIfNeeded()
        state.output = .showingTextReply(
            contextID: contextID,
            text: text,
            minimumDisplayTimerID: timerID,
            minimumDisplayUntil: deadline
        )
        state.lastDisplayMessage = PickyDisplayMessage(
            id: contextID,
            contextID: contextID,
            text: text,
            source: replyKind == .pickleCompletion ? .pickleCompletion : .textReply,
            updatedAt: envelope.occurredAt
        )
        effects.append(.scheduleMinimumDisplay(timerID: timerID, speechID: nil, inputID: inputID, delay: minimumDisplayDuration))
        record(.stateChanged, "Text quick reply is visible")
    }

    private mutating func applyPassiveAgentSummary(sessionID: String, text: String) {
        state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: text, source: .passiveSummary, updatedAt: envelope.occurredAt)
        record(.stateChanged, "Passive agent summary updated")
    }

    private mutating func applyPickleCompleted(sessionID: String, summary: String?) {
        if let summary {
            state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: summary, source: .pickleCompletion, updatedAt: envelope.occurredAt)
        }
        record(.accepted, "Pickle completed")
    }

    /// Synthetic signal from CompanionManager when an agentd session reaches a
    /// terminal status (cancelled/failed) without emitting `quickReply` — the
    /// canonical case is a HUD abort. We must release any matching cursor
    /// `.waitingForAgent` output here; otherwise the projection keeps reporting
    /// `isWaitingForCursorResponse = true` and the cursor stays yellow forever.
    private mutating func applyMainTurnSettled(contextID: String) {
        // A DSL-only main turn has no quickReply and no audio, so narration is over now.
        invalidateActiveVisualNarrationTurn(contextID: contextID)
        markAnnotationTurnSettled()
        guard case .waitingForAgent(_, let waitingContextID, _) = state.output,
              waitingContextID == contextID else {
            record(.accepted, "Main turn settled; cursor output already moved on for \(contextID)")
            return
        }
        state.output = .idle
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        record(.stateChanged, "Main turn settled; released cursor waitingForAgent for \(contextID)")
    }

    private mutating func applyMainAgentSessionReset() {
        clearAgentAnnotationsForUserInput()
        state.queuedSpeechReplies.removeAll()
        preemptSpeakingOutputIfNeeded()
        state.output = .idle
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        state = state.removingOverlayReason(.speakingResponse)
        record(.stateChanged, "Main agent session reset locally")
    }

    private mutating func applySessionTerminated(sessionID: String) {
        guard let pending = state.pendingAgentRequestsBySession.removeValue(forKey: sessionID) else {
            record(.staleEvent, "Ignored sessionTerminated for unknown session \(sessionID)")
            return
        }
        // Drop pending input slots tied to this aborted submission so a subsequent
        // user input does not race against stale entries. Safe when the keys are
        // already gone (e.g. `agentSubmissionAccepted` removed the voice input).
        if let inputID = pending.inputID {
            state.pendingTextInputs[inputID] = nil
            state.pendingVoiceInputs[inputID] = nil
        }
        // Only collapse output if it is the .waitingForAgent for THIS request. A
        // quickReply that already moved output to .showingTextReply/.speaking, or a
        // newer submission's .waitingForAgent for a different inputID/contextID,
        // must not be clobbered by a late terminal signal.
        if case .waitingForAgent(let waitingInputID, let waitingContextID, _) = state.output,
           waitingContextID == pending.contextID,
           pending.inputID == nil || waitingInputID == pending.inputID {
            state.output = .idle
            state = state.removingOverlayReason(.waitingForVoiceResponse)
            record(.stateChanged, "Session terminated; released cursor waitingForAgent for \(sessionID)")
        } else {
            record(.accepted, "Session terminated; cursor output already moved on for \(sessionID)")
        }
    }

    // MARK: - Pointer

    private mutating func applyPointerRequested(target: PickyPointerTarget) {
        state.pendingAnnotationPointerTargets = []
        state.activeAnnotationPointerID = nil
        state.activeAnnotationPointerReturnsToCursor = true
        state.annotationPointerTurnActive = false
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        if let previous = state.pointer.target?.id, previous != target.id {
            effects.append(.cancelPointerAnimation(pointerID: previous))
        }
        state.pointer = .requested(target)
        state = state.addingOverlayReason(.activePointerAnimation)
        effects.append(.startPointerAnimation(target: target))
        record(.stateChanged, "Pointer requested")
    }

    private mutating func applyPointerCancelled(pointerID: String) {
        guard state.pointer.target?.id == pointerID else {
            record(.staleEvent, "Ignored stale pointer cancel")
            return
        }
        state.pointer = .idle
        state.pendingAnnotationPointerTargets = []
        state.activeAnnotationPointerID = nil
        state.activeAnnotationPointerReturnsToCursor = true
        state.annotationPointerTurnActive = false
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        state = state.removingOverlayReason(.activePointerAnimation)
        effects.append(.cancelPointerAnimation(pointerID: pointerID))
        record(.stateChanged, "Pointer cancelled")
    }

    private mutating func applyPointerAnimationParked(pointerID: String) {
        guard state.activeAnnotationPointerID == pointerID,
              state.activeAnnotationPointerParksAtTarget,
              state.annotationPointerTurnActive else {
            record(.staleEvent, "Ignored stale annotation pointer park")
            return
        }
        state.annotationPointerIsParked = true
        record(.stateChanged, "Annotation pointer parked")
    }

    private mutating func applyPointerAnimationFinished(pointerID: String) {
        guard state.pointer.target?.id == pointerID else {
            record(.staleEvent, "Ignored stale pointer finish")
            return
        }
        if state.activeAnnotationPointerID == pointerID {
            state.activeAnnotationPointerID = nil
            state.activeAnnotationPointerReturnsToCursor = true
            state.annotationPointerIsParked = false
            state.activeAnnotationPointerParksAtTarget = false
            state.pointer = .idle
            startNextAnnotationPointerIfPossible()
            if state.activeAnnotationPointerID != nil {
                record(.stateChanged, "Annotation pointer advanced")
                return
            }
        } else {
            state.pointer = .idle
            startNextAnnotationPointerIfPossible()
            if state.activeAnnotationPointerID != nil {
                record(.stateChanged, "Standalone pointer finished; annotation pointer started")
                return
            }
        }
        state = state.removingOverlayReason(.activePointerAnimation)
        record(.stateChanged, "Pointer animation finished")
    }

    // MARK: - Agent annotations

    private mutating func applyAgentAnnotationsRequested(mode: PickyAnnotationOverlayMode, annotations: [PickyAgentAnnotation]) {
        switch mode {
        case .clear:
            clearAgentAnnotations(resetNarration: true)
        case .replace:
            state.pendingAgentAnnotations = []
            state.dueAgentAnnotationIDs = []
            state.agentAnnotations = []
            state.agentAnnotationsDismissible = false
            state = state.removingOverlayReason(.activeAgentAnnotations)
            for annotation in annotations { bufferOrRevealAnnotation(annotation) }
        case .append:
            if !annotations.isEmpty { state.agentAnnotationsDismissible = false }
            for annotation in annotations { bufferOrRevealAnnotation(annotation) }
        }
        record(.stateChanged, "Agent annotations \(mode.rawValue)")
    }

    private mutating func applyAgentAnnotationScenePrepared(identity: PickyAnnotationSceneIdentity) {
        if state.annotationSceneIdentity != identity {
            state.pendingAgentAnnotations = []
            state.dueAgentAnnotationIDs = []
            state.agentAnnotations = []
            clearVisualAnnotationNarrationState()
            endAnnotationPointerTurn(discardingPendingTargets: true)
        }
        state.annotationSceneIdentity = identity
        state.annotationScenePhase = .validating
        state.annotationSceneRecoveryAllowed = true
        state.agentAnnotationsDismissible = false
        state = state.removingOverlayReason(.activeAgentAnnotations)
        record(.stateChanged, "Agent annotation scene validating")
    }

    private mutating func applyAgentAnnotationSceneMatched(identity: PickyAnnotationSceneIdentity) {
        guard state.annotationSceneIdentity == identity else {
            record(.staleEvent, "Ignored stale annotation scene match")
            return
        }
        let wasValidating = state.annotationScenePhase == .validating
        state.annotationScenePhase = .visible
        if !state.agentAnnotations.isEmpty {
            state = state.addingOverlayReason(.activeAgentAnnotations)
            if wasValidating, annotationSpeechActive {
                enqueueAnnotationPointerTargets(state.agentAnnotations)
            }
        }
        record(.stateChanged, wasValidating ? "Agent annotation scene validated" : "Agent annotations resumed")
    }

    private mutating func applyAgentAnnotationSceneMismatched(
        identity: PickyAnnotationSceneIdentity,
        reason: PickyAnnotationSceneMismatchReason
    ) {
        guard state.annotationSceneIdentity == identity else {
            record(.staleEvent, "Ignored stale annotation scene mismatch")
            return
        }
        guard state.annotationSceneRecoveryAllowed else {
            cancelAnnotationPointerForSceneSuspension()
            clearAgentAnnotations(resetNarration: true)
            record(.stateChanged, "Agent annotations cleared after narration: \(reason.rawValue)")
            return
        }
        state.annotationScenePhase = .suspended
        state = state.removingOverlayReason(.activeAgentAnnotations)
        cancelAnnotationPointerForSceneSuspension()
        record(.stateChanged, "Agent annotations suspended: \(reason.rawValue)")
    }

    /// Buffers a streamed annotation so the overlay cannot show it before narration
    /// reaches its position. Once narration has ended it reveals immediately instead.
    private mutating func bufferOrRevealAnnotation(_ annotation: PickyAgentAnnotation) {
        let pending = PickyPendingAgentAnnotation(
            id: UUID(),
            annotation: annotation,
            precedingNarrationWeight: state.annotationNarrationWeight,
            silentTurnSequence: state.annotationArrivalSequence
        )
        state.annotationArrivalSequence += 1
        state.pendingAgentAnnotations.append(pending)
        let overflow = max(0, state.pendingAgentAnnotations.count - PickyInteractionReducer.maximumAgentAnnotationCount)
        if overflow > 0 {
            let removedIDs = state.pendingAgentAnnotations.prefix(overflow).map(\.id)
            state.pendingAgentAnnotations.removeFirst(overflow)
            state.dueAgentAnnotationIDs.subtract(removedIDs)
        }
        if let anchor = state.annotationSpeechAnchor {
            scheduleAnnotationReveal(pending, anchor: anchor)
        }
    }

    /// First accepted TTS start anchors reveal timing; schedule every buffered reveal.
    private mutating func applyAnnotationSpeechStarted(now: Date) {
        guard state.annotationSpeechAnchor == nil else { return }
        state.agentAnnotationsDismissible = false
        state.annotationSpeechAnchor = now
        for pending in state.pendingAgentAnnotations {
            scheduleAnnotationReveal(pending, anchor: now)
        }
    }

    private mutating func scheduleAnnotationReveal(_ pending: PickyPendingAgentAnnotation, anchor: Date) {
        let revealAt = anchor.addingTimeInterval(
            PickyNarrationPaceModel.speechPrerollSeconds
                + pending.precedingNarrationWeight * PickyNarrationPaceModel.secondsPerWeightUnit
        )
        let delay = max(0, revealAt.timeIntervalSince(envelope.occurredAt))
        effects.append(.scheduleAnnotationReveal(id: pending.id, delay: delay))
    }

    private mutating func applyAnnotationRevealDue(id: UUID) {
        guard state.pendingAgentAnnotations.contains(where: { $0.id == id }) else {
            record(.staleEvent, "Ignored stale annotation reveal")
            return
        }
        state.dueAgentAnnotationIDs.insert(id)

        // Equal/overdue Task.sleep deadlines can resume in arbitrary order. Only
        // drain a due annotation after every earlier stream item is also due so
        // both drawing appearance and buddy traversal remain source-order FIFO.
        while let pending = state.pendingAgentAnnotations.first,
              state.dueAgentAnnotationIDs.remove(pending.id) != nil {
            state.pendingAgentAnnotations.removeFirst()
            revealAnnotation(pending.annotation)
        }
    }

    /// Stores an annotation and, when its original scene is visible, sends the buddy
    /// to it. Scene validation may keep the geometry resident but absent from projection.
    private mutating func revealAnnotation(_ annotation: PickyAgentAnnotation, animatePointer: Bool = true) {
        if let index = state.agentAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            state.agentAnnotations[index] = annotation
        } else {
            state.agentAnnotations.append(annotation)
        }
        let overflow = max(0, state.agentAnnotations.count - PickyInteractionReducer.maximumAgentAnnotationCount)
        if overflow > 0 { state.agentAnnotations.removeFirst(overflow) }
        if state.annotationScenePhase.presentsAnnotations {
            state = state.addingOverlayReason(.activeAgentAnnotations)
            if animatePointer {
                enqueueAnnotationPointerTargets([annotation])
            }
        }
        record(.stateChanged, "Annotation revealed")
    }

    /// True while the turn still has audio playing or queued.
    private var annotationSpeechActive: Bool {
        if case .speaking = state.output { return true }
        return !state.queuedSpeechReplies.isEmpty
    }

    /// The turn produced its terminal reply/settlement. If no audio is (or will be)
    /// playing, narration is over now, so conclude immediately; otherwise wait for the
    /// speech to drain (handled in `concludeAnnotationTurnIfSettled`).
    private mutating func markAnnotationTurnSettled() {
        state.annotationTurnSettled = true
        if !annotationSpeechActive {
            concludeAnnotationTurn()
        }
    }

    /// Narration is over: a scene that disappeared during speech is no longer useful,
    /// so discard it rather than polling for a later restoration. A still-matching scene
    /// keeps its drawings, but the next mismatch clears them permanently.
    private mutating func concludeAnnotationTurn() {
        // Narration ended, but keep the scene recoverable for a grace window so a brief
        // context switch hides and then restores the drawings instead of clearing them
        // outright. If the scene was suspended when narration ended, hold it suspended
        // rather than clearing immediately. A timer lapses the window later.
        while !state.pendingAgentAnnotations.isEmpty {
            revealAnnotation(state.pendingAgentAnnotations.removeFirst().annotation, animatePointer: false)
        }
        state.dueAgentAnnotationIDs = []
        state.annotationNarrationWeight = 0
        state.annotationSpeechAnchor = nil
        state.annotationTurnSettled = false
        state.annotationArrivalSequence = 0
        state.agentAnnotationsDismissible = state.annotationScenePhase != .suspended && !state.agentAnnotations.isEmpty
        endAnnotationPointerTurn(discardingPendingTargets: true)
        if state.annotationSceneRecoveryAllowed, let identity = state.annotationSceneIdentity {
            effects.append(.scheduleAnnotationRecoveryExpiry(
                identity: identity,
                delay: PickyInteractionReducer.annotationRecoveryGraceAfterNarration
            ))
        }
    }

    /// The post-narration recovery grace has elapsed. A scene the user never returned to
    /// (still suspended) is cleared for good; a restored/kept scene simply stops
    /// recovering, so the next mismatch clears it.
    private mutating func applyAnnotationRecoveryExpired(identity: PickyAnnotationSceneIdentity) {
        guard state.annotationSceneIdentity == identity, state.annotationSceneRecoveryAllowed else {
            record(.staleEvent, "Ignored stale annotation recovery expiry")
            return
        }
        if state.annotationScenePhase == .suspended {
            clearAgentAnnotations(resetNarration: true)
            record(.stateChanged, "Suspended agent annotations cleared after recovery grace")
            return
        }
        state.annotationSceneRecoveryAllowed = false
        state.agentAnnotationsDismissible = !state.agentAnnotations.isEmpty
        record(.stateChanged, "Annotation recovery grace elapsed; scene locked")
    }

    private mutating func concludeAnnotationTurnIfSettled() {
        guard state.annotationTurnSettled, !annotationSpeechActive else { return }
        concludeAnnotationTurn()
    }

    private mutating func clearAgentAnnotationsForUserInput() {
        clearAgentAnnotations(resetNarration: true)
        clearProgressiveNarrationState()
        record(.stateChanged, "Agent annotations cleared for user input")
    }

    private mutating func clearAgentAnnotations(resetNarration: Bool) {
        state.pendingAgentAnnotations = []
        state.dueAgentAnnotationIDs = []
        state.agentAnnotations = []
        state.annotationSceneIdentity = nil
        state.annotationScenePhase = .inactive
        state.annotationSceneRecoveryAllowed = false
        state.agentAnnotationsDismissible = false
        if resetNarration {
            state.annotationNarrationWeight = 0
            state.annotationSpeechAnchor = nil
            state.annotationTurnSettled = false
            state.annotationArrivalSequence = 0
            clearVisualAnnotationNarrationState()
        }
        state = state.removingOverlayReason(.activeAgentAnnotations)
        endAnnotationPointerTurn(discardingPendingTargets: true)
    }

    private mutating func clearVisualAnnotationNarrationState() {
        let annotationSegmentIDs = Set(state.visualNarrationSegments.compactMap { id, segment in
            if case .annotations = segment.visual { return id }
            return nil
        })
        guard !annotationSegmentIDs.isEmpty else { return }
        for id in annotationSegmentIDs { state.visualNarrationSegments[id] = nil }
        state.visualNarrationOrder.removeAll { annotationSegmentIDs.contains($0) }
        state.visualNarrationSpeechMarkers = state.visualNarrationSpeechMarkers.filter {
            !annotationSegmentIDs.contains($0.value.identity.segmentId)
        }
        state.pendingVisualOnlyNarrationIdentities.removeAll {
            annotationSegmentIDs.contains($0.segmentId)
        }
        if let activeID = state.activeVisualNarrationIdentity?.segmentId,
           annotationSegmentIDs.contains(activeID) {
            state.activeVisualNarrationIdentity = nil
            state.activeVisualNarrationSentenceCount = 0
        }
    }

    private mutating func clearProgressiveNarrationState() {
        invalidateActiveVisualNarrationTurn()
        state.streamedResponseContextID = nil
        state.streamedResponseText = nil
        state.finalNarrationSpeechContextIDs = []
        state.visualNarrationSegments = [:]
        state.visualNarrationOrder = []
        state.activeVisualNarrationIdentity = nil
        state.activeVisualNarrationSentenceCount = 0
        state.visualNarrationSpeechMarkers = [:]
        state.visualNarrationClearSpeechIDs = []
        state.pendingVisualOnlyNarrationIdentities = []
        state.streamedNarrationContextIDs = []
    }

    private mutating func cancelAnnotationPointerForSceneSuspension() {
        state.pendingAnnotationPointerTargets = []
        state.annotationPointerTurnActive = false
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        state.activeAnnotationPointerReturnsToCursor = true
        guard let activeID = state.activeAnnotationPointerID else { return }
        effects.append(.cancelPointerAnimation(pointerID: activeID))
        state.activeAnnotationPointerID = nil
        state.pointer = .idle
        state = state.removingOverlayReason(.activePointerAnimation)
    }

    private mutating func enqueueAnnotationPointerTargets(_ annotations: [PickyAgentAnnotation]) {
        let targets = annotations.compactMap(PickyAnnotationPointerTarget.make)
        guard !targets.isEmpty else { return }
        state.annotationPointerTurnActive = true
        state.pendingAnnotationPointerTargets.append(contentsOf: targets)
        if let activeID = state.activeAnnotationPointerID {
            // A final target may still be approaching or hovering when another DSL tag
            // arrives. Convert it into a direct hop instead of allowing a fly-back.
            state.activeAnnotationPointerParksAtTarget = false
            effects.append(.setPointerParksAtTarget(pointerID: activeID, parksAtTarget: false))
            if state.activeAnnotationPointerReturnsToCursor {
                state.activeAnnotationPointerReturnsToCursor = false
                effects.append(.setPointerReturnsToCursor(pointerID: activeID, returnsToCursor: false))
            }
            if state.annotationPointerIsParked {
                state.annotationPointerIsParked = false
                effects.append(.advancePointerAnimation(pointerID: activeID))
            }
        }
        startNextAnnotationPointerIfPossible()
    }

    private mutating func startNextAnnotationPointerIfPossible() {
        guard case .idle = state.pointer,
              !state.pendingAnnotationPointerTargets.isEmpty else { return }
        var target = state.pendingAnnotationPointerTargets.removeFirst()
        let isFinalTarget = state.pendingAnnotationPointerTargets.isEmpty
        let parksAtTarget = state.annotationPointerTurnActive && isFinalTarget
        target = PickyAnnotationPointerTarget.settingHoldBehavior(
            target,
            returnsToCursor: !state.annotationPointerTurnActive && isFinalTarget,
            parksAtTarget: parksAtTarget
        )
        state.pointer = .requested(target)
        state.activeAnnotationPointerID = target.id
        state.activeAnnotationPointerReturnsToCursor = target.returnsToCursor
        state.activeAnnotationPointerParksAtTarget = target.parksAtTarget
        state.annotationPointerIsParked = false
        state = state.addingOverlayReason(.activePointerAnimation)
        effects.append(.startPointerAnimation(target: target))
    }

    /// Ends the current annotation stream without interrupting the buddy's current flight.
    /// Normal turn endings finish queued shapes before returning; user input/clear drops
    /// not-yet-visited anchors but still lets the active target spring back naturally.
    private mutating func endAnnotationPointerTurn(discardingPendingTargets: Bool = false) {
        guard state.annotationPointerTurnActive || state.activeAnnotationPointerID != nil else { return }
        state.annotationPointerTurnActive = false
        if discardingPendingTargets {
            state.pendingAnnotationPointerTargets = []
        }
        guard let activeID = state.activeAnnotationPointerID else {
            state.annotationPointerIsParked = false
            state.activeAnnotationPointerParksAtTarget = false
            return
        }

        let shouldReturnAfterCurrentTarget = state.pendingAnnotationPointerTargets.isEmpty
        state.annotationPointerIsParked = false
        state.activeAnnotationPointerParksAtTarget = false
        state.activeAnnotationPointerReturnsToCursor = shouldReturnAfterCurrentTarget
        effects.append(.setPointerParksAtTarget(pointerID: activeID, parksAtTarget: false))
        effects.append(.setPointerReturnsToCursor(pointerID: activeID, returnsToCursor: shouldReturnAfterCurrentTarget))
    }

    // MARK: - Speech output lifecycle

    private mutating func applySpeechCompleted(speechID: UUID) {
        let completedOrdinal = state.visualNarrationSpeechMarkers[speechID]?.identity.ordinal
        state.visualNarrationSpeechMarkers[speechID] = nil
        state.visualNarrationClearSpeechIDs.remove(speechID)
        guard case .speaking(let contextID, speechID, let text, let timerID, let minimumDisplayUntil, _) = state.output else {
            record(.staleEvent, "Ignored stale speech completion")
            return
        }
        activatePendingVisualOnlyNarration(contextID: contextID, afterOrdinal: completedOrdinal)
        if let timerID, let minimumDisplayUntil, envelope.occurredAt < minimumDisplayUntil {
            state.output = .speaking(
                contextID: contextID,
                speechID: speechID,
                text: text,
                minimumDisplayTimerID: timerID,
                minimumDisplayUntil: minimumDisplayUntil,
                finishPending: true
            )
            record(.stateChanged, "Speech completed before minimum display")
        } else if startNextQueuedSpeechIfAvailable(occurredAt: envelope.occurredAt) {
            record(.stateChanged, "Queued voice quick reply started")
        } else {
            state.output = .idle
            if let contextID {
                state.streamedNarrationContextIDs.remove(contextID)
                concludeProgressiveNarrationSpeech(contextID: contextID)
            }
            state = state.removingOverlayReason(.speakingResponse)
            concludeAnnotationTurnIfSettled()
            record(.stateChanged, "Speech completed")
        }
    }



    private mutating func applyMinimumDisplayTimerFired(timerID: UUID) {
        switch state.output {
        case .showingTextReply(let contextID, let text, let currentTimerID, let minimumDisplayUntil) where currentTimerID == timerID:
            state.output = .idle
            state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: .textReply, updatedAt: envelope.occurredAt)
            _ = minimumDisplayUntil
            record(.stateChanged, "Text reply minimum display completed")
        case .suppressedReply(let contextID, let text, let reason, let currentTimerID, _) where currentTimerID == timerID:
            state.output = .idle
            state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: .suppressed, updatedAt: envelope.occurredAt)
            _ = reason
            record(.stateChanged, "Suppressed reply minimum display completed")
        case .speaking(let contextID, let speechID, let text, let currentTimerID, _, let finishPending) where currentTimerID == timerID:
            if finishPending {
                if startNextQueuedSpeechIfAvailable(occurredAt: envelope.occurredAt) {
                    record(.stateChanged, "Queued voice quick reply started")
                } else {
                    state.output = .idle
                    if let contextID { concludeProgressiveNarrationSpeech(contextID: contextID) }
                    state = state.removingOverlayReason(.speakingResponse)
                    concludeAnnotationTurnIfSettled()
                    record(.stateChanged, "Speaking reply minimum display completed")
                }
            } else {
                state.output = .speaking(
                    contextID: contextID,
                    speechID: speechID,
                    text: text,
                    minimumDisplayTimerID: nil,
                    minimumDisplayUntil: nil,
                    finishPending: false
                )
                record(.stateChanged, "Speaking reply minimum display is satisfied")
            }
        default:
            record(.staleEvent, "Ignored stale minimum display timer")
        }
    }

    private mutating func applyTransientHideTimerFired(timerID: UUID) {
        guard case .hiding(timerID, let reason) = state.overlay else {
            record(.staleEvent, "Ignored stale transient hide timer")
            return
        }
        state = state.removingOverlayReason(reason)
        record(.stateChanged, "Transient hide timer fired")
    }

    // MARK: - Shared speech helpers

    private mutating func concludeProgressiveNarrationSpeech(contextID: String) {
        state.finalNarrationSpeechContextIDs.remove(contextID)
        // Narration is over: reveal any empty visual-only segments that never reached
        // their turn, in source order, before tearing down the narration bookkeeping.
        activatePendingVisualOnlyNarration(contextID: contextID, afterOrdinal: nil)
        if state.activeVisualNarrationIdentity?.contextId == contextID {
            clearActiveVisualNarration()
        }
        if state.streamedResponseContextID == contextID {
            state.streamedResponseContextID = nil
            state.streamedResponseText = nil
        }
        state.visualNarrationSpeechMarkers = state.visualNarrationSpeechMarkers.filter {
            $0.value.identity.contextId != contextID
        }
    }

    /// Reveals buffered empty (prose-less) visual-only segments in source order.
    ///
    /// When `afterOrdinal` is set, only the segments that immediately follow the one
    /// whose narration just finished are revealed, contiguously in ordinal order. This
    /// keeps a later empty RECT from drawing before an earlier one that is still waiting
    /// for its own segment's speech. When `afterOrdinal` is nil the narration has fully
    /// concluded, so every remaining empty segment is flushed in order.
    private mutating func activatePendingVisualOnlyNarration(contextID: String?, afterOrdinal: Int?) {
        let candidates = state.pendingVisualOnlyNarrationIdentities
            .filter { contextID == nil || $0.contextId == contextID }
            .sorted { $0.ordinal < $1.ordinal }
        guard !candidates.isEmpty else { return }
        var due: [PickyVisualNarrationSegmentIdentity] = []
        if let afterOrdinal {
            var expected = afterOrdinal + 1
            for identity in candidates {
                guard identity.ordinal == expected else { break }
                due.append(identity)
                expected += 1
            }
        } else {
            due = candidates
        }
        guard !due.isEmpty else { return }
        state.pendingVisualOnlyNarrationIdentities.removeAll { due.contains($0) }
        for identity in due {
            activateVisualNarration(identity: identity, sentenceCount: 0)
        }
    }

    private mutating func startSpeakingReply(_ reply: PickyQueuedSpeechReply, occurredAt: Date) {
        let deadline = occurredAt.addingTimeInterval(minimumDisplayDuration)
        state = state.removingOverlayReason(.waitingForVoiceResponse)
        state = state.addingOverlayReason(.speakingResponse)
        state.output = .speaking(
            contextID: reply.contextID,
            speechID: reply.speechID,
            text: reply.text,
            minimumDisplayTimerID: reply.timerID,
            minimumDisplayUntil: deadline,
            finishPending: false
        )
        if let marker = reply.visualNarrationMarker {
            state.visualNarrationSpeechMarkers[reply.speechID] = marker
        }
        if reply.visualNarrationMarker == nil
            && (!state.streamedNarrationContextIDs.contains(reply.contextID) || state.lastDisplayMessage?.contextID != reply.contextID) {
            state.lastDisplayMessage = PickyDisplayMessage(
                id: reply.contextID,
                contextID: reply.contextID,
                text: reply.text,
                source: reply.displaySource,
                updatedAt: occurredAt
            )
        }
        effects.append(.scheduleMinimumDisplay(timerID: reply.timerID, speechID: reply.speechID, inputID: reply.inputID, delay: minimumDisplayDuration))
        effects.append(.speak(speechID: reply.speechID, text: reply.text, contextID: reply.contextID))
    }

    private mutating func startNextQueuedSpeechIfAvailable(occurredAt: Date) -> Bool {
        guard !state.queuedSpeechReplies.isEmpty else { return false }
        let reply = state.queuedSpeechReplies.removeFirst()
        startSpeakingReply(reply, occurredAt: occurredAt)
        return true
    }

    /// Cleans up a `.speaking` output when an event must replace it with a non-`.speaking`
    /// output (text reply, suppressed reply, waiting-for-agent, idle). Without this guard
    /// the in-flight TTS keeps playing after the projection state has moved on, the
    /// `.speakingResponse` overlay reason stays asserted, and any subsequent
    /// `.speechFinished`/`.speechFailed` event becomes stale and never fires the
    /// `.speaking → .idle` cleanup branch — leaving `voiceState` stuck at `.responding`.
    /// Idempotent: a no-op when `state.output` is not `.speaking`, and harmless to call
    /// when the next output will itself be `.speaking` (the new `.speak` effect will run
    /// after this `.stopSpeech` and replace the playing utterance).
    private mutating func preemptSpeakingOutputIfNeeded() {
        guard case .speaking(_, let speechID, _, _, _, _) = state.output else { return }
        effects.append(.stopSpeech(reason: .superseded, speechID: speechID))
        state = state.removingOverlayReason(.speakingResponse)
    }

    private mutating func appendStreamedResponse(
        contextID: String,
        text: String,
        source: PickyDisplaySource
    ) {
        let accumulated: String
        if state.streamedResponseContextID == contextID,
           let previous = state.streamedResponseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previous.isEmpty {
            accumulated = "\(previous) \(text)"
        } else {
            accumulated = text
        }
        state.streamedResponseContextID = contextID
        state.streamedResponseText = accumulated
        state.lastDisplayMessage = PickyDisplayMessage(
            id: contextID,
            contextID: contextID,
            text: accumulated,
            source: source,
            updatedAt: envelope.occurredAt
        )
    }

    private func displaySource(
        replyKind: PickyQuickReplyKind?,
        owner: PickyContextOwner
    ) -> PickyDisplaySource {
        if replyKind == .pickleCompletion { return .pickleCompletion }
        return owner.usesCursorResponsePresentation ? .textReply : .voiceReply
    }

    private func ownerFromMetadata(_ origin: PickyQuickReplyOriginSource?) -> PickyContextOwner {
        switch origin {
        case .voice, .voiceFollowUp:
            .metadataVoice
        case .text, .textFollowUp:
            .metadataText
        case .cli:
            .cli
        case .system:
            .system
        case .unknown, nil:
            .unknown
        }
    }
}

private extension PickyInteractionState {
    var hasActiveVoiceInput: Bool {
        switch input {
        case .voiceListening, .voiceFinalizing, .voiceSubmitting:
            true
        case .idle, .textSubmitting:
            false
        }
    }

    func addingOverlayReason(_ reason: PickyOverlayReason) -> Self {
        var copy = self
        switch copy.overlay {
        case .hidden:
            copy.overlay = .visible(reason: [reason])
        case .visible(let reasons):
            var updated = reasons
            updated.insert(reason)
            copy.overlay = .visible(reason: updated)
        case .hiding:
            copy.overlay = .visible(reason: [reason])
        }
        return copy
    }

    func removingOverlayReason(_ reason: PickyOverlayReason) -> Self {
        var copy = self
        switch copy.overlay {
        case .hidden:
            break
        case .visible(let reasons):
            var updated = reasons
            updated.remove(reason)
            copy.overlay = updated.isEmpty ? .hidden : .visible(reason: updated)
        case .hiding(_, let hidingReason):
            if hidingReason == reason { copy.overlay = .hidden }
        }
        return copy
    }
}
