//
//  PickyVoiceInteractionMachine.swift
//  Picky
//
//  Single voice interaction state machine for cursor voice input, loading,
//  response speaking, and queued spoken replies.
//

import Foundation

enum PickyVoiceInteractionPhase: Equatable {
    case idle
    case pttInput
    case loading
    case speaking
}

enum PickyVoiceInteractionMode: Equatable {
    case standard
    case realtime
}

struct PickyVoiceSpeechQueueItem: Equatable {
    let text: String
    let speechID: UUID
    let timerID: UUID
    let inputID: UUID?
}

enum PickyVoicePromptBubbleVisibility: Equatable {
    case visible
    case hidden
}

struct PickyVoiceInteractionContext: Equatable {
    var inputID: UUID?
    var targetSessionID: String?
    var transcript: String?
    var promptBubbleText: String?
    var promptBubbleVisibility: PickyVoicePromptBubbleVisibility = .visible
    var responseBubbleText: String?
    var pendingSince: Date?
    var activeSpeechID: UUID?
    var activeSpeechTimerID: UUID?
    var minimumDisplayUntil: Date?
    var isSpeechFinishPending = false
    var speechQueue: [PickyVoiceSpeechQueueItem] = []
    var mode: PickyVoiceInteractionMode = .standard

    var isAbortable: Bool {
        switch (inputID, activeSpeechID, pendingSince, targetSessionID) {
        case (.some, _, _, _), (_, .some, _, _), (_, _, .some, _), (_, _, _, .some): true
        default: false
        }
    }
}

struct PickyVoiceInteractionState: Equatable {
    var phase: PickyVoiceInteractionPhase
    var context: PickyVoiceInteractionContext
    var effectsToRun: [PickyVoiceInteractionEffect]

    init(
        phase: PickyVoiceInteractionPhase = .idle,
        context: PickyVoiceInteractionContext = PickyVoiceInteractionContext(),
        effectsToRun: [PickyVoiceInteractionEffect] = []
    ) {
        self.phase = phase
        self.context = context
        self.effectsToRun = effectsToRun
    }

    var projection: CompanionVoicePresentationState {
        switch phase {
        case .idle:
            return CompanionVoicePresentationState(voiceState: .idle, promptBubbleState: .hidden)
        case .pttInput:
            let prompt = context.promptBubbleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CompanionVoicePresentationState(
                voiceState: .listening,
                promptBubbleState: prompt.isEmpty ? .hidden : .recognized(prompt)
            )
        case .loading:
            let prompt = context.promptBubbleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CompanionVoicePresentationState(
                voiceState: .processing,
                promptBubbleState: prompt.isEmpty ? .hidden : .recognized(prompt)
            )
        case .speaking:
            return CompanionVoicePresentationState(voiceState: .responding, promptBubbleState: .hidden)
        }
    }
}

enum PickyVoiceInteractionEvent: Equatable {
    case pttPressed(inputID: UUID, targetSessionID: String?, mode: PickyVoiceInteractionMode)
    case pttReleased(inputID: UUID)
    case sttPartial(inputID: UUID, text: String)
    case sttFinal(inputID: UUID, text: String, now: Date)
    case sttFailed(inputID: UUID, message: String)
    case loadingStarted(inputID: UUID?, transcript: String?, targetSessionID: String?, mode: PickyVoiceInteractionMode, now: Date, promptBubbleVisibility: PickyVoicePromptBubbleVisibility)
    case agentReply(text: String, shouldSpeak: Bool, speechID: UUID, timerID: UUID, inputID: UUID?, now: Date)
    case textReply(text: String)
    case speechFinished(speechID: UUID, now: Date)
    case speechFailed(speechID: UUID, now: Date)
    case minimumDisplayTimerFired(timerID: UUID, now: Date)
    case promptBubbleAutoHide
    case realtimeStateChanged(PickyMainRealtimeState)
    case realtimeAudioStarted
    case realtimeTurnDone
    case abort
    case reset
}

enum PickyVoiceInteractionEffect: Equatable {
    case startDictation(inputID: UUID)
    case stopDictation(inputID: UUID)
    case startRealtimeTurn(inputID: UUID)
    case commitRealtimeTurn(inputID: UUID)
    case cancelRealtimeTurn(inputID: UUID?)
    case captureContext(inputID: UUID, transcript: String, targetSessionID: String?)
    case submitMain(inputID: UUID, transcript: String)
    case followUpPickle(inputID: UUID, sessionID: String, transcript: String)
    case steerPickle(inputID: UUID, sessionID: String, transcript: String)
    case speak(speechID: UUID, text: String)
    case stopSpeech(speechID: UUID?)
    case abortMainAgent
    case abortPickle(sessionID: String)
    case scheduleMinimumDisplay(timerID: UUID, speechID: UUID, inputID: UUID?, delay: TimeInterval)
    case schedulePromptBubbleAutoHide
    case scheduleTransientHide
}

struct PickyVoiceInteractionTransition: Equatable {
    let state: PickyVoiceInteractionState
    let effects: [PickyVoiceInteractionEffect]
}

enum PickyVoiceInteractionMachine {
    static let minimumDisplayDuration: TimeInterval = 0.35

    static func reduce(
        state: PickyVoiceInteractionState,
        event: PickyVoiceInteractionEvent
    ) -> PickyVoiceInteractionTransition {
        var reducing = PickyVoiceInteractionReducing(state: state)
        reducing.state.effectsToRun = []
        reducing.apply(event)
        reducing.state.effectsToRun = reducing.effects
        return PickyVoiceInteractionTransition(state: reducing.state, effects: reducing.effects)
    }
}

/// Single reduction pass over one event. Each event has a dedicated handler so
/// the dispatch switch stays a flat routing table and the shared transitions
/// (begin input, start/complete speech, clear to idle) live in one place.
private struct PickyVoiceInteractionReducing {
    var state: PickyVoiceInteractionState
    var effects: [PickyVoiceInteractionEffect] = []

    private var minimumDisplayDuration: TimeInterval { PickyVoiceInteractionMachine.minimumDisplayDuration }

    mutating func apply(_ event: PickyVoiceInteractionEvent) {
        switch event {
        case .pttPressed(let inputID, let targetSessionID, let mode):
            beginInput(inputID: inputID, targetSessionID: targetSessionID, mode: mode)
        case .pttReleased(let inputID):
            applyPTTReleased(inputID: inputID)
        case .sttPartial(let inputID, let text):
            applySTTPartial(inputID: inputID, text: text)
        case .sttFinal(let inputID, let text, let now):
            applySTTFinal(inputID: inputID, text: text, now: now)
        case .sttFailed(let inputID, _):
            applySTTFailed(inputID: inputID)
        case .loadingStarted(let inputID, let transcript, let targetSessionID, let mode, let now, let promptBubbleVisibility):
            applyLoadingStarted(
                inputID: inputID,
                transcript: transcript,
                targetSessionID: targetSessionID,
                mode: mode,
                now: now,
                promptBubbleVisibility: promptBubbleVisibility
            )
        case .agentReply(let text, let shouldSpeak, let speechID, let timerID, let inputID, let now):
            applyAgentReply(text: text, shouldSpeak: shouldSpeak, speechID: speechID, timerID: timerID, inputID: inputID, now: now)
        case .textReply(let text):
            applyTextReply(text: text)
        case .speechFinished(let speechID, let now), .speechFailed(let speechID, let now):
            applySpeechCompleted(speechID: speechID, now: now)
        case .minimumDisplayTimerFired(let timerID, let now):
            applyMinimumDisplayTimerFired(timerID: timerID, now: now)
        case .promptBubbleAutoHide:
            state.context.promptBubbleText = nil
        case .realtimeStateChanged(let realtimeState):
            applyRealtimeStateChanged(realtimeState)
        case .realtimeAudioStarted:
            applyRealtimeAudioStarted()
        case .realtimeTurnDone:
            clearToIdle(scheduleHide: true)
        case .abort:
            applyAbort()
        case .reset:
            clearToIdle(scheduleHide: false)
        }
    }

    // MARK: - Event handlers

    private mutating func applyPTTReleased(inputID: UUID) {
        guard state.context.inputID == inputID else { return }
        state.phase = .loading
        if state.context.mode == .realtime {
            effects.append(.commitRealtimeTurn(inputID: inputID))
        } else {
            effects.append(.stopDictation(inputID: inputID))
        }
    }

    private mutating func applySTTPartial(inputID: UUID, text: String) {
        guard state.context.inputID == inputID else { return }
        state.context.transcript = text
        state.context.promptBubbleText = promptBubbleTextIfVisible(text)
    }

    private mutating func applySTTFinal(inputID: UUID, text: String, now: Date) {
        guard state.context.inputID == inputID else { return }
        let transcript = normalized(text)
        state.phase = .loading
        state.context.transcript = transcript
        state.context.promptBubbleText = promptBubbleTextIfVisible(text)
        state.context.pendingSince = now
        if let transcript {
            if state.context.promptBubbleVisibility == .visible {
                effects.append(.schedulePromptBubbleAutoHide)
            }
            effects.append(.captureContext(inputID: inputID, transcript: transcript, targetSessionID: state.context.targetSessionID))
        }
    }

    private mutating func applySTTFailed(inputID: UUID) {
        guard state.context.inputID == inputID else { return }
        clearToIdle(scheduleHide: true)
    }

    private mutating func applyLoadingStarted(
        inputID: UUID?,
        transcript: String?,
        targetSessionID: String?,
        mode: PickyVoiceInteractionMode,
        now: Date,
        promptBubbleVisibility: PickyVoicePromptBubbleVisibility
    ) {
        let normalizedTranscript = normalized(transcript)
        state.phase = .loading
        state.context.inputID = inputID
        state.context.targetSessionID = targetSessionID
        state.context.transcript = normalizedTranscript
        state.context.promptBubbleVisibility = promptBubbleVisibility
        state.context.promptBubbleText = promptBubbleTextIfVisible(transcript)
        state.context.pendingSince = now
        state.context.responseBubbleText = nil
        state.context.activeSpeechID = nil
        state.context.activeSpeechTimerID = nil
        state.context.minimumDisplayUntil = nil
        state.context.isSpeechFinishPending = false
        state.context.speechQueue.removeAll()
        state.context.mode = mode
        if promptBubbleVisibility == .visible, normalizedTranscript != nil {
            effects.append(.schedulePromptBubbleAutoHide)
        }
    }

    private mutating func applyAgentReply(text: String, shouldSpeak: Bool, speechID: UUID, timerID: UUID, inputID: UUID?, now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.context.pendingSince = nil
        if shouldSpeak {
            let item = PickyVoiceSpeechQueueItem(text: trimmed, speechID: speechID, timerID: timerID, inputID: inputID)
            if state.phase == .speaking {
                state.context.speechQueue.append(item)
            } else {
                startSpeaking(item, now: now)
            }
        } else {
            state.phase = .idle
            state.context.responseBubbleText = trimmed
            state.context.promptBubbleText = nil
            state.context.activeSpeechID = nil
            state.context.activeSpeechTimerID = nil
            state.context.minimumDisplayUntil = nil
            state.context.isSpeechFinishPending = false
            state.context.speechQueue.removeAll()
            effects.append(.scheduleTransientHide)
        }
    }

    private mutating func applyTextReply(text: String) {
        state.phase = .idle
        state.context.responseBubbleText = normalized(text)
        state.context.promptBubbleText = nil
        state.context.activeSpeechID = nil
        state.context.speechQueue.removeAll()
    }

    private mutating func applySpeechCompleted(speechID: UUID, now: Date) {
        guard state.context.activeSpeechID == speechID else { return }
        completeCurrentSpeech(now: now)
    }

    private mutating func applyMinimumDisplayTimerFired(timerID: UUID, now: Date) {
        guard state.context.activeSpeechTimerID == timerID else { return }
        state.context.minimumDisplayUntil = nil
        if state.context.isSpeechFinishPending {
            state.context.isSpeechFinishPending = false
            if startNextQueuedSpeechIfAvailable(now: now) { return }
            clearToIdle(scheduleHide: true)
        }
    }

    private mutating func applyRealtimeStateChanged(_ realtimeState: PickyMainRealtimeState) {
        switch realtimeState {
        case .connecting, .thinking:
            state.phase = .loading
            state.context.pendingSince = state.context.pendingSince ?? Date()
            state.context.mode = .realtime
        case .ready:
            if state.context.activeSpeechID == nil {
                clearToIdle(scheduleHide: true)
            }
        case .listening:
            state.phase = .pttInput
            state.context.mode = .realtime
        case .speaking:
            state.phase = .speaking
            state.context.mode = .realtime
            state.context.promptBubbleText = nil
        case .failed:
            clearToIdle(scheduleHide: true)
        }
    }

    private mutating func applyRealtimeAudioStarted() {
        state.phase = .speaking
        state.context.mode = .realtime
        state.context.pendingSince = nil
        state.context.promptBubbleText = nil
    }

    private mutating func applyAbort() {
        if state.context.activeSpeechID != nil {
            effects.append(.stopSpeech(speechID: state.context.activeSpeechID))
        }
        if state.context.mode == .realtime {
            effects.append(.cancelRealtimeTurn(inputID: state.context.inputID))
        } else if state.phase == .loading || state.phase == .speaking {
            effects.append(.abortMainAgent)
        }
        if let targetSessionID = state.context.targetSessionID,
           state.phase == .loading || state.phase == .speaking {
            effects.append(.abortPickle(sessionID: targetSessionID))
        }
        clearToIdle(scheduleHide: true)
    }

    // MARK: - Shared transitions

    private func normalized(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func promptBubbleTextIfVisible(_ text: String?) -> String? {
        state.context.promptBubbleVisibility == .visible ? normalized(text) : nil
    }

    private mutating func beginInput(inputID: UUID, targetSessionID: String?, mode: PickyVoiceInteractionMode) {
        if state.phase == .speaking || state.phase == .loading {
            if state.context.activeSpeechID != nil {
                effects.append(.stopSpeech(speechID: state.context.activeSpeechID))
            }
            if state.context.mode == .realtime {
                effects.append(.cancelRealtimeTurn(inputID: state.context.inputID))
            } else {
                effects.append(.abortMainAgent)
            }
            if let previousTarget = state.context.targetSessionID {
                effects.append(.abortPickle(sessionID: previousTarget))
            }
        }

        state.phase = .pttInput
        state.context = PickyVoiceInteractionContext(
            inputID: inputID,
            targetSessionID: targetSessionID,
            mode: mode
        )
        if mode == .realtime {
            effects.append(.startRealtimeTurn(inputID: inputID))
        } else {
            effects.append(.startDictation(inputID: inputID))
        }
    }

    private mutating func clearToIdle(scheduleHide: Bool = false) {
        state.phase = .idle
        state.context = PickyVoiceInteractionContext()
        if scheduleHide { effects.append(.scheduleTransientHide) }
    }

    private mutating func startSpeaking(_ item: PickyVoiceSpeechQueueItem, now: Date) {
        state.phase = .speaking
        state.context.activeSpeechID = item.speechID
        state.context.activeSpeechTimerID = item.timerID
        state.context.responseBubbleText = item.text
        state.context.promptBubbleText = nil
        state.context.minimumDisplayUntil = now.addingTimeInterval(minimumDisplayDuration)
        state.context.isSpeechFinishPending = false
        effects.append(.scheduleMinimumDisplay(
            timerID: item.timerID,
            speechID: item.speechID,
            inputID: item.inputID,
            delay: minimumDisplayDuration
        ))
        effects.append(.speak(speechID: item.speechID, text: item.text))
    }

    private mutating func startNextQueuedSpeechIfAvailable(now: Date) -> Bool {
        guard !state.context.speechQueue.isEmpty else { return false }
        let next = state.context.speechQueue.removeFirst()
        startSpeaking(next, now: now)
        return true
    }

    private mutating func completeCurrentSpeech(now: Date) {
        guard state.phase == .speaking else { return }
        if let until = state.context.minimumDisplayUntil, now < until {
            state.context.isSpeechFinishPending = true
            return
        }
        if startNextQueuedSpeechIfAvailable(now: now) { return }
        clearToIdle(scheduleHide: true)
    }
}
