import Foundation

struct PickyInteractionTransition: Equatable {
    var state: PickyInteractionState
    var effects: [PickyInteractionEffect]
    var journalRecords: [PickyInteractionJournalRecord]
}

enum PickyInteractionReducer {
    static let minimumDisplayDuration: TimeInterval = 0.35

    static func reduce(
        state: PickyInteractionState,
        envelope: PickyInteractionEnvelope
    ) -> PickyInteractionTransition {
        var state = state
        var effects: [PickyInteractionEffect] = []
        var records: [PickyInteractionJournalRecord] = []

        func record(_ kind: PickyInteractionJournalRecord.Kind, _ message: String) {
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

        switch envelope.event {
        case .appStarted:
            record(.accepted, "App interaction model started")

        case .permissionsChanged, .cursorPreferenceChanged:
            record(.accepted, "Interaction environment changed")

        case .voicePressed(let targetSessionID):
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

        case .voiceStartFailed(let message, let inputID):
            guard state.pendingVoiceInputs[inputID] != nil else {
                record(.staleEvent, "Ignored stale voice start failure: \(message)")
                break
            }
            state.pendingVoiceInputs[inputID] = nil
            state.input = .idle
            state = state.removingOverlayReason(.activeVoiceInput)
            record(.stateChanged, "Voice start failed")

        case .voiceReleased(let inputID):
            guard case .voiceListening(inputID, let targetSessionID) = state.input else {
                record(.staleEvent, "Ignored stale voice release")
                break
            }
            state.input = .voiceFinalizing(inputID: inputID, targetSessionID: targetSessionID, transcriptPreview: nil)
            effects.append(.stopDictation(inputID: inputID))
            record(.stateChanged, "Voice input released")

        case .transcriptFinal(let text, let inputID):
            guard var voice = state.pendingVoiceInputs[inputID] else {
                record(.staleEvent, "Ignored transcript for unknown voice input")
                break
            }
            voice.transcript = text
            state.pendingVoiceInputs[inputID] = voice
            state.input = .voiceSubmitting(inputID: inputID, targetSessionID: voice.targetSessionID, transcript: text)
            state.output = .waitingForAgent(inputID: inputID, contextID: nil, promptPreview: text)
            state = state.addingOverlayReason(.waitingForVoiceResponse)
            effects.append(.captureVoiceContext(inputID: inputID, transcript: text, targetSessionID: voice.targetSessionID))
            record(.stateChanged, "Voice transcript finalized")

        case .transcriptFailed(let message, let inputID):
            state.queuedSpeechReplies.removeAll()
            guard state.pendingVoiceInputs[inputID] != nil else {
                record(.staleEvent, "Ignored stale transcript failure: \(message)")
                break
            }
            state.pendingVoiceInputs[inputID] = nil
            state.input = .idle
            preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
            state.output = .idle
            state = state.removingOverlayReason(.activeVoiceInput)
            state = state.removingOverlayReason(.waitingForVoiceResponse)
            record(.stateChanged, "Voice transcript failed")

        case .textSubmitted(let text, let inputID):
            let source = envelope.correlation.source
            state.queuedSpeechReplies.removeAll()
            state.input = .textSubmitting(inputID: inputID, text: text)
            state.pendingTextInputs[inputID] = PickyTextInputState(text: text, source: source)
            if source == .quickInput {
                preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
                state.output = .waitingForAgent(inputID: inputID, contextID: nil, promptPreview: text)
                state = state.addingOverlayReason(.waitingForVoiceResponse)
            }
            effects.append(.captureTextContext(inputID: inputID, text: text))
            record(.stateChanged, "Text input submitted")

        case .textContextCaptured(let inputID, let context):
            guard var pendingText = state.pendingTextInputs[inputID] else {
                record(.staleEvent, "Ignored text context for unknown input")
                break
            }
            pendingText.contextID = context.id
            state.pendingTextInputs[inputID] = pendingText
            let owner: PickyContextOwner = pendingText.source == .quickInput ? .quickInputText(inputID: inputID) : .text(inputID: inputID)
            state.contextOwnership[context.id] = owner
            state.queuedSpeechReplies.removeAll()
            preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
            state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: pendingText.text)
            if pendingText.source == .quickInput {
                state = state.addingOverlayReason(.waitingForVoiceResponse)
            }
            effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: owner))
            effects.append(.submitText(inputID: inputID, context: context, text: pendingText.text))
            record(.stateChanged, "Text context captured before submit")

        case .textSubmissionAccepted(_, let inputID):
            guard state.pendingTextInputs[inputID] != nil else {
                record(.staleEvent, "Ignored text submission receipt for unknown input")
                break
            }
            state.pendingTextInputs[inputID] = nil
            if case .textSubmitting(inputID, _) = state.input {
                state.input = .idle
            }
            record(.accepted, "Text submission accepted")

        case .textSubmissionFailed(let message, let inputID):
            guard let pendingText = state.pendingTextInputs[inputID] else {
                record(.staleEvent, "Ignored text submission failure: \(message)")
                break
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
            preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
            if pendingText.source == .quickInput {
                state.output = .idle
                state = state.removingOverlayReason(.waitingForVoiceResponse)
            } else if preemptedSpeaking {
                state.output = .idle
            }
            record(.stateChanged, "Text submission failed")

        case .voiceContextCaptured(let inputID, let transcript, let context, let targetSessionID):
            guard var pendingVoice = state.pendingVoiceInputs[inputID] else {
                record(.staleEvent, "Ignored voice context for unknown input")
                break
            }
            pendingVoice.contextID = context.id
            pendingVoice.transcript = transcript
            state.pendingVoiceInputs[inputID] = pendingVoice
            state.contextOwnership[context.id] = .voice(inputID: inputID)
            state.queuedSpeechReplies.removeAll()
            preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
            state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: transcript)
            effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: .voice(inputID: inputID)))
            if let targetSessionID {
                effects.append(.followUpPickle(inputID: inputID, sessionID: targetSessionID, transcript: transcript, context: context))
            } else {
                effects.append(.submitMain(inputID: inputID, transcript: transcript, context: context))
            }
            record(.stateChanged, "Voice context captured before submit")

        case .externalContextCaptured(let inputID, let text, let context):
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
                break
            }
            if case .speaking = state.output {
                record(.stateChanged, "External CLI context captured while another reply is speaking; queued behind it")
                break
            }
            state.queuedSpeechReplies.removeAll()
            preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
            state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: text)
            record(.stateChanged, "External CLI context captured before submit")

        case .agentSubmissionAccepted(let contextID, let sessionID, let inputID):
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

        case .quickReply(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            if let sessionID { state.pendingAgentRequestsBySession[sessionID] = nil }
            // Realtime ack: OpenAI Realtime already delivered the audio reply
            // (and its transcript via output_transcript). This signal exists
            // purely to release the reducer's `.waitingForAgent` output so the
            // cursor returns to idle. Do NOT replay the text through TTS and
            // do NOT replace the visible bubble - just clean up state for the
            // matching inputID/contextID. Skip the rest of the .quickReply
            // body (which would startSpeakingReply or set .showingTextReply).
            if replyKind == .realtimeAck {
                if let inputID { state.pendingTextInputs[inputID] = nil }
                state.queuedSpeechReplies.removeAll()
                state = state.removingOverlayReason(.waitingForVoiceResponse)
                if case .waitingForAgent(let waitingInputID, let waitingContextID, _) = state.output,
                   waitingInputID == inputID,
                   waitingContextID == contextID {
                    state.output = .idle
                    record(.stateChanged, "Realtime ack received; cursor cleared")
                } else {
                    record(.accepted, "Realtime ack received; output already moved on")
                }
                break
            }
            let timerID = envelope.id
            let deadline = envelope.occurredAt.addingTimeInterval(minimumDisplayDuration)
            let owner = state.contextOwnership[contextID] ?? ownerFromMetadata(originSource)
            let hasActiveVoiceInput = state.hasActiveVoiceInput
            let shouldSpeakReply = owner.isVoiceOwned || owner.usesCursorResponsePresentation || replyKind == .pickleCompletion
            if hasActiveVoiceInput, replyKind == .pickleCompletion {
                state.queuedSpeechReplies.removeAll()
                preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
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
            } else if shouldSpeakReply, !hasActiveVoiceInput {
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
                    startSpeakingReply(queuedReply, occurredAt: envelope.occurredAt, state: &state, effects: &effects)
                    record(.stateChanged, "Voice quick reply is speaking")
                }
            } else {
                state.queuedSpeechReplies.removeAll()
                state = state.removingOverlayReason(.waitingForVoiceResponse)
                preemptSpeakingOutputIfNeeded(state: &state, effects: &effects)
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
            _ = sessionID

        case .passiveAgentSummary(let sessionID, let text):
            state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: text, source: .passiveSummary, updatedAt: envelope.occurredAt)
            record(.stateChanged, "Passive agent summary updated")

        case .pickleCompleted(let sessionID, let summary):
            if let summary {
                state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: summary, source: .pickleCompletion, updatedAt: envelope.occurredAt)
            }
            record(.accepted, "Pickle completed")

        case .sessionTerminated(let sessionID):
            // Synthetic signal from CompanionManager when an agentd session reaches a
            // terminal status (cancelled/failed) without emitting `quickReply` — the
            // canonical case is a HUD abort. We must release any matching cursor
            // `.waitingForAgent` output here; otherwise the projection keeps reporting
            // `isWaitingForCursorResponse = true` and the cursor stays yellow forever.
            guard let pending = state.pendingAgentRequestsBySession.removeValue(forKey: sessionID) else {
                record(.staleEvent, "Ignored sessionTerminated for unknown session \(sessionID)")
                break
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
               waitingInputID == pending.inputID,
               waitingContextID == pending.contextID {
                state.output = .idle
                state = state.removingOverlayReason(.waitingForVoiceResponse)
                record(.stateChanged, "Session terminated; released cursor waitingForAgent for \(sessionID)")
            } else {
                record(.accepted, "Session terminated; cursor output already moved on for \(sessionID)")
            }

        case .pointerRequested(let target):
            if let previous = state.pointer.target?.id, previous != target.id {
                effects.append(.cancelPointerAnimation(pointerID: previous))
            }
            state.pointer = .requested(target)
            state = state.addingOverlayReason(.activePointerAnimation)
            effects.append(.startPointerAnimation(target: target))
            record(.stateChanged, "Pointer requested")

        case .pointerCancelled(let pointerID, _):
            guard state.pointer.target?.id == pointerID else {
                record(.staleEvent, "Ignored stale pointer cancel")
                break
            }
            state.pointer = .idle
            state = state.removingOverlayReason(.activePointerAnimation)
            effects.append(.cancelPointerAnimation(pointerID: pointerID))
            record(.stateChanged, "Pointer cancelled")

        case .pointerAnimationFinished(let pointerID):
            guard state.pointer.target?.id == pointerID else {
                record(.staleEvent, "Ignored stale pointer finish")
                break
            }
            state.pointer = .idle
            state = state.removingOverlayReason(.activePointerAnimation)
            record(.stateChanged, "Pointer animation finished")

        case .speechStarted:
            record(.accepted, "Speech provider started")

        case .speechFinished(let speechID), .speechFailed(let speechID):
            guard case .speaking(let contextID, speechID, let text, let timerID, let minimumDisplayUntil, _) = state.output else {
                record(.staleEvent, "Ignored stale speech completion")
                break
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
            } else if startNextQueuedSpeechIfAvailable(occurredAt: envelope.occurredAt, state: &state, effects: &effects) {
                record(.stateChanged, "Queued voice quick reply started")
            } else {
                state.output = .idle
                state = state.removingOverlayReason(.speakingResponse)
                record(.stateChanged, "Speech completed")
            }

        case .minimumDisplayTimerFired(let timerID, _, _):
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
                    if startNextQueuedSpeechIfAvailable(occurredAt: envelope.occurredAt, state: &state, effects: &effects) {
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

        case .overlayShown(let reason):
            state = state.addingOverlayReason(reason)
            record(.stateChanged, "Overlay reason shown")

        case .overlayHidden(let reason):
            state = state.removingOverlayReason(reason)
            record(.stateChanged, "Overlay reason hidden")

        case .transientHideTimerFired(let timerID):
            guard case .hiding(timerID, let reason) = state.overlay else {
                record(.staleEvent, "Ignored stale transient hide timer")
                break
            }
            state = state.removingOverlayReason(reason)
            record(.stateChanged, "Transient hide timer fired")
        }

        return PickyInteractionTransition(state: state, effects: effects, journalRecords: records)
    }

    private static func startSpeakingReply(
        _ reply: PickyQueuedSpeechReply,
        occurredAt: Date,
        state: inout PickyInteractionState,
        effects: inout [PickyInteractionEffect]
    ) {
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

    private static func startNextQueuedSpeechIfAvailable(
        occurredAt: Date,
        state: inout PickyInteractionState,
        effects: inout [PickyInteractionEffect]
    ) -> Bool {
        guard !state.queuedSpeechReplies.isEmpty else { return false }
        let reply = state.queuedSpeechReplies.removeFirst()
        startSpeakingReply(reply, occurredAt: occurredAt, state: &state, effects: &effects)
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
    private static func preemptSpeakingOutputIfNeeded(
        state: inout PickyInteractionState,
        effects: inout [PickyInteractionEffect]
    ) {
        guard case .speaking(_, let speechID, _, _, _, _) = state.output else { return }
        effects.append(.stopSpeech(reason: .superseded, speechID: speechID))
        state = state.removingOverlayReason(.speakingResponse)
    }

    private static func ownerFromMetadata(_ origin: PickyQuickReplyOriginSource?) -> PickyContextOwner {
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
