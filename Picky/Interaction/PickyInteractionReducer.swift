import Foundation

struct PickyInteractionTransition: Equatable {
    var state: PickyInteractionState
    var effects: [PickyInteractionEffect]
    var journalRecords: [PickyInteractionJournalRecord]
}

enum PickyInteractionReducer {
    static let minimumDisplayDuration: TimeInterval = 0.35
    static let maximumAgentAnnotationCount = 24

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
        case .passiveAgentSummary(let sessionID, let text):
            applyPassiveAgentSummary(sessionID: sessionID, text: text)
        case .pickleCompleted(let sessionID, let summary):
            applyPickleCompleted(sessionID: sessionID, summary: summary)
        case .sessionTerminated(let sessionID):
            applySessionTerminated(sessionID: sessionID)
        case .pointerRequested(let target):
            applyPointerRequested(target: target)
        case .pointerCancelled(let pointerID, _):
            applyPointerCancelled(pointerID: pointerID)
        case .pointerAnimationFinished(let pointerID):
            applyPointerAnimationFinished(pointerID: pointerID)
        case .agentAnnotationsRequested(let mode, let annotations):
            applyAgentAnnotationsRequested(mode: mode, annotations: annotations)
        case .agentAnnotationsExpired(let now):
            applyAgentAnnotationsExpired(now: now)
        case .agentAnnotationsClearedForUserInput:
            clearAgentAnnotationsForUserInput()
        case .speechStarted:
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
        effects.append(.cancelPointerAnimation(pointerID: state.pointer.target?.id))
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
        inputID: UUID?
    ) {
        let speechID = envelope.correlation.speechID ?? envelope.id
        let displaySource: PickyDisplaySource = replyKind == .pickleCompletion ? .pickleCompletion : (owner.usesCursorResponsePresentation ? .textReply : .voiceReply)
        let queuedReply = PickyQueuedSpeechReply(
            contextID: contextID,
            text: text,
            timerID: timerID,
            speechID: speechID,
            inputID: inputID,
            displaySource: displaySource
        )
        if case .speaking = state.output {
            state.queuedSpeechReplies.append(queuedReply)
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
        state = state.removingOverlayReason(.activePointerAnimation)
        effects.append(.cancelPointerAnimation(pointerID: pointerID))
        record(.stateChanged, "Pointer cancelled")
    }

    private mutating func applyPointerAnimationFinished(pointerID: String) {
        guard state.pointer.target?.id == pointerID else {
            record(.staleEvent, "Ignored stale pointer finish")
            return
        }
        state.pointer = .idle
        state = state.removingOverlayReason(.activePointerAnimation)
        record(.stateChanged, "Pointer animation finished")
    }

    // MARK: - Agent annotations

    private mutating func applyAgentAnnotationsRequested(mode: PickyAnnotationOverlayMode, annotations: [PickyAgentAnnotation]) {
        switch mode {
        case .clear:
            state.agentAnnotations = []
        case .replace:
            state.agentAnnotations = uniqueAnnotations(annotations)
        case .append:
            var merged = state.agentAnnotations
            for annotation in annotations {
                if let index = merged.firstIndex(where: { $0.id == annotation.id }) {
                    merged[index] = annotation
                } else {
                    merged.append(annotation)
                }
            }
            let overflow = max(0, merged.count - PickyInteractionReducer.maximumAgentAnnotationCount)
            if overflow > 0 {
                let expiredIndexes = merged.enumerated()
                    .sorted { left, right in
                        left.element.zOrder == right.element.zOrder
                            ? left.offset < right.offset
                            : left.element.zOrder < right.element.zOrder
                    }
                    .prefix(overflow)
                    .map(\.offset)
                    .sorted(by: >)
                for index in expiredIndexes { merged.remove(at: index) }
            }
            state.agentAnnotations = sortedAnnotations(merged)
        }
        state = state.agentAnnotations.isEmpty
            ? state.removingOverlayReason(.activeAgentAnnotations)
            : state.addingOverlayReason(.activeAgentAnnotations)
        record(.stateChanged, "Agent annotations \(mode.rawValue)")
    }

    private mutating func applyAgentAnnotationsExpired(now: Date) {
        let previousCount = state.agentAnnotations.count
        state.agentAnnotations.removeAll { $0.expiresAt <= now }
        guard state.agentAnnotations.count != previousCount else {
            record(.staleEvent, "No agent annotations expired")
            return
        }
        if state.agentAnnotations.isEmpty {
            state = state.removingOverlayReason(.activeAgentAnnotations)
        }
        record(.stateChanged, "Expired agent annotations removed")
    }

    private mutating func clearAgentAnnotationsForUserInput() {
        guard !state.agentAnnotations.isEmpty else { return }
        state.agentAnnotations = []
        state = state.removingOverlayReason(.activeAgentAnnotations)
        record(.stateChanged, "Agent annotations cleared for user input")
    }

    private func uniqueAnnotations(_ annotations: [PickyAgentAnnotation]) -> [PickyAgentAnnotation] {
        var indexed: [String: PickyAgentAnnotation] = [:]
        for annotation in annotations { indexed[annotation.id] = annotation }
        return sortedAnnotations(Array(indexed.values))
    }

    private func sortedAnnotations(_ annotations: [PickyAgentAnnotation]) -> [PickyAgentAnnotation] {
        annotations.sorted {
            $0.zOrder == $1.zOrder ? $0.id < $1.id : $0.zOrder < $1.zOrder
        }
    }

    // MARK: - Speech output lifecycle

    private mutating func applySpeechCompleted(speechID: UUID) {
        guard case .speaking(let contextID, speechID, let text, let timerID, let minimumDisplayUntil, _) = state.output else {
            record(.staleEvent, "Ignored stale speech completion")
            return
        }
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
            state = state.removingOverlayReason(.speakingResponse)
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
                    state = state.removingOverlayReason(.speakingResponse)
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
        state.lastDisplayMessage = PickyDisplayMessage(
            id: reply.contextID,
            contextID: reply.contextID,
            text: reply.text,
            source: reply.displaySource,
            updatedAt: occurredAt
        )
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
