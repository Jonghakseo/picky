import Foundation

enum PickyInteractionEffect: Equatable {
    case startDictation(inputID: UUID)
    case stopDictation(inputID: UUID)
    case captureVoiceContext(inputID: UUID, transcript: String, targetSessionID: String?)
    case recordContextOwnership(inputID: UUID, contextID: String, owner: PickyContextOwner)
    case submitMain(inputID: UUID, transcript: String, context: PickyContextPacket)
    case followUpSide(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket)
    case captureTextContext(inputID: UUID, text: String)
    case submitText(inputID: UUID, context: PickyContextPacket, text: String)
    case speak(speechID: UUID, text: String, contextID: String?)
    case stopSpeech(reason: PickySpeechStopReason)
    case scheduleMinimumDisplay(timerID: UUID, speechID: UUID?, inputID: UUID?, delay: TimeInterval)
    case showOverlay(reason: PickyOverlayReason)
    case scheduleTransientHide(timerID: UUID, delay: TimeInterval)
    case cancelTransientHide(timerID: UUID?)
    case startPointerAnimation(target: PickyPointerTarget)
    case cancelPointerAnimation(pointerID: String?)
}
