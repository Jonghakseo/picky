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

struct PickyVoiceInteractionContext: Equatable {
    var inputID: UUID?
    var targetSessionID: String?
    var transcript: String?
    var promptBubbleText: String?
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
    case loadingStarted(inputID: UUID?, transcript: String?, targetSessionID: String?, mode: PickyVoiceInteractionMode, now: Date)
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
        var state = state
        var effects: [PickyVoiceInteractionEffect] = []
        state.effectsToRun = []

        func normalized(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        func beginInput(inputID: UUID, targetSessionID: String?, mode: PickyVoiceInteractionMode) {
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

        func clearToIdle(scheduleHide: Bool = false) {
            state.phase = .idle
            state.context = PickyVoiceInteractionContext()
            if scheduleHide { effects.append(.scheduleTransientHide) }
        }

        func startSpeaking(_ item: PickyVoiceSpeechQueueItem, now: Date) {
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

        func startNextQueuedSpeechIfAvailable(now: Date) -> Bool {
            guard !state.context.speechQueue.isEmpty else { return false }
            let next = state.context.speechQueue.removeFirst()
            startSpeaking(next, now: now)
            return true
        }

        func completeCurrentSpeech(now: Date) {
            guard state.phase == .speaking else { return }
            if let until = state.context.minimumDisplayUntil, now < until {
                state.context.isSpeechFinishPending = true
                return
            }
            if startNextQueuedSpeechIfAvailable(now: now) { return }
            clearToIdle(scheduleHide: true)
        }

        switch event {
        case .pttPressed(let inputID, let targetSessionID, let mode):
            beginInput(inputID: inputID, targetSessionID: targetSessionID, mode: mode)

        case .pttReleased(let inputID):
            guard state.context.inputID == inputID else { break }
            state.phase = .loading
            if state.context.mode == .realtime {
                effects.append(.commitRealtimeTurn(inputID: inputID))
            } else {
                effects.append(.stopDictation(inputID: inputID))
            }

        case .sttPartial(let inputID, let text):
            guard state.context.inputID == inputID else { break }
            state.context.transcript = text
            state.context.promptBubbleText = normalized(text)

        case .sttFinal(let inputID, let text, let now):
            guard state.context.inputID == inputID else { break }
            let transcript = normalized(text)
            state.phase = .loading
            state.context.transcript = transcript
            state.context.promptBubbleText = transcript
            state.context.pendingSince = now
            if let transcript {
                effects.append(.schedulePromptBubbleAutoHide)
                effects.append(.captureContext(inputID: inputID, transcript: transcript, targetSessionID: state.context.targetSessionID))
            }

        case .sttFailed(let inputID, _):
            guard state.context.inputID == inputID else { break }
            clearToIdle(scheduleHide: true)

        case .loadingStarted(let inputID, let transcript, let targetSessionID, let mode, let now):
            state.phase = .loading
            state.context.inputID = inputID
            state.context.targetSessionID = targetSessionID
            state.context.transcript = normalized(transcript)
            state.context.promptBubbleText = normalized(transcript)
            state.context.pendingSince = now
            state.context.responseBubbleText = nil
            state.context.activeSpeechID = nil
            state.context.activeSpeechTimerID = nil
            state.context.minimumDisplayUntil = nil
            state.context.isSpeechFinishPending = false
            state.context.speechQueue.removeAll()
            state.context.mode = mode
            if normalized(transcript) != nil {
                effects.append(.schedulePromptBubbleAutoHide)
            }

        case .agentReply(let text, let shouldSpeak, let speechID, let timerID, let inputID, let now):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
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

        case .textReply(let text):
            state.phase = .idle
            state.context.responseBubbleText = normalized(text)
            state.context.promptBubbleText = nil
            state.context.activeSpeechID = nil
            state.context.speechQueue.removeAll()

        case .speechFinished(let speechID, let now), .speechFailed(let speechID, let now):
            guard state.context.activeSpeechID == speechID else { break }
            completeCurrentSpeech(now: now)

        case .minimumDisplayTimerFired(let timerID, let now):
            guard state.context.activeSpeechTimerID == timerID else { break }
            state.context.minimumDisplayUntil = nil
            if state.context.isSpeechFinishPending {
                state.context.isSpeechFinishPending = false
                if startNextQueuedSpeechIfAvailable(now: now) { break }
                clearToIdle(scheduleHide: true)
            }

        case .promptBubbleAutoHide:
            state.context.promptBubbleText = nil

        case .realtimeStateChanged(let realtimeState):
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

        case .realtimeAudioStarted:
            state.phase = .speaking
            state.context.mode = .realtime
            state.context.pendingSince = nil
            state.context.promptBubbleText = nil

        case .realtimeTurnDone:
            clearToIdle(scheduleHide: true)

        case .abort:
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

        case .reset:
            clearToIdle(scheduleHide: false)
        }

        state.effectsToRun = effects
        return PickyVoiceInteractionTransition(state: state, effects: effects)
    }
}
