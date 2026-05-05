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
            if case .speaking = state.output {
                state.output = .idle
                state = state.removingOverlayReason(.speakingResponse)
            }
            state.input = .voiceListening(inputID: inputID, targetSessionID: targetSessionID)
            state.pendingVoiceInputs[inputID] = PickyVoiceInputState(targetSessionID: targetSessionID)
            state = state.addingOverlayReason(.activeVoiceInput)
            effects.append(.stopSpeech(reason: .userInterrupted))
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
            guard state.pendingVoiceInputs[inputID] != nil else {
                record(.staleEvent, "Ignored stale transcript failure: \(message)")
                break
            }
            state.pendingVoiceInputs[inputID] = nil
            state.input = .idle
            state.output = .idle
            state = state.removingOverlayReason(.activeVoiceInput)
            state = state.removingOverlayReason(.waitingForVoiceResponse)
            record(.stateChanged, "Voice transcript failed")

        case .textSubmitted(let text, let inputID):
            state.input = .textSubmitting(inputID: inputID, text: text)
            state.pendingTextInputs[inputID] = PickyTextInputState(text: text)
            effects.append(.captureTextContext(inputID: inputID, text: text))
            record(.stateChanged, "Text input submitted")

        case .textContextCaptured(let inputID, let context):
            guard var pendingText = state.pendingTextInputs[inputID] else {
                record(.staleEvent, "Ignored text context for unknown input")
                break
            }
            pendingText.contextID = context.id
            state.pendingTextInputs[inputID] = pendingText
            state.contextOwnership[context.id] = .text(inputID: inputID)
            state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: pendingText.text)
            effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: .text(inputID: inputID)))
            effects.append(.submitText(inputID: inputID, context: context, text: pendingText.text))
            record(.stateChanged, "Text context captured before submit")

        case .textSubmissionAccepted(let contextID, let inputID):
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
            guard state.pendingTextInputs[inputID] != nil else {
                record(.staleEvent, "Ignored text submission failure: \(message)")
                break
            }
            state.pendingTextInputs[inputID] = nil
            if case .textSubmitting(inputID, _) = state.input { state.input = .idle }
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
            state.output = .waitingForAgent(inputID: inputID, contextID: context.id, promptPreview: transcript)
            effects.append(.recordContextOwnership(inputID: inputID, contextID: context.id, owner: .voice(inputID: inputID)))
            if let targetSessionID {
                effects.append(.followUpSide(inputID: inputID, sessionID: targetSessionID, transcript: transcript, context: context))
            } else {
                effects.append(.submitMain(inputID: inputID, transcript: transcript, context: context))
            }
            record(.stateChanged, "Voice context captured before submit")

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
                if case .voiceSubmitting(inputID, _, _) = state.input {
                    state.input = .idle
                }
                state = state.removingOverlayReason(.activeVoiceInput)
                if pendingVoice.targetSessionID != nil {
                    state = state.removingOverlayReason(.waitingForVoiceResponse)
                }
            }
            record(.accepted, "Agent submission accepted for \(sessionID)")

        case .quickReply(let contextID, let text, let originSource, let replyKind, let sessionID, let inputID):
            let timerID = envelope.id
            let deadline = envelope.occurredAt.addingTimeInterval(minimumDisplayDuration)
            let owner = state.contextOwnership[contextID] ?? ownerFromMetadata(originSource)
            let hasActiveVoiceInput = state.hasActiveVoiceInput
            if hasActiveVoiceInput, replyKind == .sideCompletion {
                state.output = .suppressedReply(
                    contextID: contextID,
                    text: text,
                    reason: .activeVoiceInput,
                    minimumDisplayTimerID: timerID,
                    minimumDisplayUntil: deadline
                )
                effects.append(.scheduleMinimumDisplay(timerID: timerID, speechID: nil, inputID: inputID, delay: minimumDisplayDuration))
                state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: .suppressed, updatedAt: envelope.occurredAt)
                record(.stateChanged, "Suppressed side completion quick reply while voice input is active")
            } else if owner.isVoiceOwned, !hasActiveVoiceInput {
                let speechID = envelope.correlation.speechID ?? envelope.id
                state.output = .speaking(
                    contextID: contextID,
                    speechID: speechID,
                    text: text,
                    minimumDisplayTimerID: timerID,
                    minimumDisplayUntil: deadline,
                    finishPending: false
                )
                state = state.removingOverlayReason(.waitingForVoiceResponse)
                state = state.addingOverlayReason(.speakingResponse)
                state.lastDisplayMessage = PickyDisplayMessage(id: contextID, contextID: contextID, text: text, source: .voiceReply, updatedAt: envelope.occurredAt)
                effects.append(.scheduleMinimumDisplay(timerID: timerID, speechID: speechID, inputID: inputID, delay: minimumDisplayDuration))
                effects.append(.speak(speechID: speechID, text: text, contextID: contextID))
                record(.stateChanged, "Voice quick reply is speaking")
            } else {
                state = state.removingOverlayReason(.waitingForVoiceResponse)
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
                    source: replyKind == .sideCompletion ? .sideCompletion : .textReply,
                    updatedAt: envelope.occurredAt
                )
                effects.append(.scheduleMinimumDisplay(timerID: timerID, speechID: nil, inputID: inputID, delay: minimumDisplayDuration))
                record(.stateChanged, "Text quick reply is visible")
            }
            _ = sessionID

        case .passiveAgentSummary(let sessionID, let text):
            state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: text, source: .passiveSummary, updatedAt: envelope.occurredAt)
            record(.stateChanged, "Passive agent summary updated")

        case .sideAgentCompleted(let sessionID, let summary):
            if let summary {
                state.lastDisplayMessage = PickyDisplayMessage(id: sessionID, contextID: nil, text: summary, source: .sideCompletion, updatedAt: envelope.occurredAt)
            }
            record(.accepted, "Side agent completed")

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
                    state.output = .idle
                    state = state.removingOverlayReason(.speakingResponse)
                    record(.stateChanged, "Speaking reply minimum display completed")
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

    private static func ownerFromMetadata(_ origin: PickyQuickReplyOriginSource?) -> PickyContextOwner {
        switch origin {
        case .voice, .voiceFollowUp:
            .metadataVoice
        case .text, .textFollowUp:
            .metadataText
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
