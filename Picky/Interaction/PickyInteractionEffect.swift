import Foundation

enum PickyInteractionEffect: Equatable {
    case startDictation(inputID: UUID)
    case stopDictation(inputID: UUID)
    case captureVoiceContext(inputID: UUID, transcript: String, targetSessionID: String?)
    case recordContextOwnership(inputID: UUID, contextID: String, owner: PickyContextOwner)
    case submitMain(inputID: UUID, transcript: String, context: PickyContextPacket)
    case followUpPickle(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket)
    case captureTextContext(inputID: UUID, text: String)
    case submitText(inputID: UUID, context: PickyContextPacket, text: String)
    case speak(speechID: UUID, text: String, contextID: String?)
    /// Stops any in-flight TTS playback. `speechID` carries the utterance the
    /// reducer is preempting; nil means "stop whatever is playing without
    /// dispatching a synthetic .speechFailed" (used for voicePressed when no
    /// interaction speech was active). When set, the effect runner dispatches
    /// `.speechFailed(speechID)` so the reducer can settle its state machine
    /// even if the speech provider's onFinish callback is racing the new
    /// effect that just preempted it.
    case stopSpeech(reason: PickySpeechStopReason, speechID: UUID?)
    case scheduleMinimumDisplay(timerID: UUID, speechID: UUID?, inputID: UUID?, delay: TimeInterval)
    case showOverlay(reason: PickyOverlayReason)
    case scheduleTransientHide(timerID: UUID, delay: TimeInterval)
    case cancelTransientHide(timerID: UUID?)
    case startPointerAnimation(target: PickyPointerTarget)
    case setPointerReturnsToCursor(pointerID: String, returnsToCursor: Bool)
    case cancelPointerAnimation(pointerID: String?)
}
