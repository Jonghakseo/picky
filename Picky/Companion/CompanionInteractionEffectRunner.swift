//
//  CompanionInteractionEffectRunner.swift
//  Picky
//
//  Executes explicit interaction reducer effects through injected adapters.
//

import Foundation

@MainActor
final class CompanionInteractionEffectRunner: PickyInteractionEffectRunning {
    private weak var manager: CompanionManager?
    private let captureTextContext: (UUID, String) -> Void
    private let submitText: (UUID, PickyContextPacket, String) -> Void
    private let captureVoiceContext: (UUID, String, String?) -> Void
    private let submitMain: (UUID, String, PickyContextPacket) -> Void
    private let followUpPickle: (UUID, String, String, PickyContextPacket) -> Void
    private let scheduleMinimumDisplay: (UUID, UUID?, UUID?, TimeInterval) -> Void
    private let speak: (UUID, String, String?) -> Void
    private let prefetchSpeech: (String) -> Void
    private let stopSpeech: (UUID?) -> Void
    private let scheduleAnnotationReveal: (UUID, TimeInterval) -> Void
    private let scheduleAnnotationRecoveryExpiry: (PickyAnnotationSceneIdentity, TimeInterval) -> Void

    init(
        manager: CompanionManager,
        captureTextContext: @escaping (UUID, String) -> Void,
        submitText: @escaping (UUID, PickyContextPacket, String) -> Void,
        captureVoiceContext: @escaping (UUID, String, String?) -> Void,
        submitMain: @escaping (UUID, String, PickyContextPacket) -> Void,
        followUpPickle: @escaping (UUID, String, String, PickyContextPacket) -> Void,
        scheduleMinimumDisplay: @escaping (UUID, UUID?, UUID?, TimeInterval) -> Void,
        speak: @escaping (UUID, String, String?) -> Void,
        prefetchSpeech: @escaping (String) -> Void,
        stopSpeech: @escaping (UUID?) -> Void,
        scheduleAnnotationReveal: @escaping (UUID, TimeInterval) -> Void,
        scheduleAnnotationRecoveryExpiry: @escaping (PickyAnnotationSceneIdentity, TimeInterval) -> Void
    ) {
        self.manager = manager
        self.captureTextContext = captureTextContext
        self.submitText = submitText
        self.captureVoiceContext = captureVoiceContext
        self.submitMain = submitMain
        self.followUpPickle = followUpPickle
        self.scheduleMinimumDisplay = scheduleMinimumDisplay
        self.speak = speak
        self.prefetchSpeech = prefetchSpeech
        self.stopSpeech = stopSpeech
        self.scheduleAnnotationReveal = scheduleAnnotationReveal
        self.scheduleAnnotationRecoveryExpiry = scheduleAnnotationRecoveryExpiry
    }

    func run(_ effects: [PickyInteractionEffect]) {
        for effect in effects {
            switch effect {
            case .captureTextContext(let inputID, let text):
                captureTextContext(inputID, text)
            case .submitText(let inputID, let context, let text):
                submitText(inputID, context, text)
            case .captureVoiceContext(let inputID, let transcript, let targetSessionID):
                captureVoiceContext(inputID, transcript, targetSessionID)
            case .submitMain(let inputID, let transcript, let context):
                submitMain(inputID, transcript, context)
            case .followUpPickle(let inputID, let sessionID, let transcript, let context):
                followUpPickle(inputID, sessionID, transcript, context)
            case .scheduleMinimumDisplay(let timerID, let speechID, let inputID, let delay):
                scheduleMinimumDisplay(timerID, speechID, inputID, delay)
            case .speak(let speechID, let text, let contextID):
                speak(speechID, text, contextID)
            case .prefetchSpeech(let text):
                prefetchSpeech(text)
            case .stopSpeech(_, let speechID):
                stopSpeech(speechID)
            case .recordContextOwnership, .startDictation, .stopDictation:
                break
            case .startPointerAnimation(let target):
                manager?.startPointerAnimation(target: target)
            case .setPointerReturnsToCursor(let pointerID, let returnsToCursor):
                manager?.setPointerReturnsToCursor(pointerID: pointerID, returnsToCursor: returnsToCursor)
            case .setPointerParksAtTarget(let pointerID, let parksAtTarget):
                manager?.setPointerParksAtTarget(pointerID: pointerID, parksAtTarget: parksAtTarget)
            case .advancePointerAnimation(let pointerID):
                manager?.advancePointerAnimation(pointerID: pointerID)
            case .cancelPointerAnimation(let pointerID):
                manager?.cancelPointerAnimation(pointerID: pointerID)
            case .scheduleAnnotationReveal(let id, let delay):
                scheduleAnnotationReveal(id, delay)
            case .scheduleAnnotationRecoveryExpiry(let identity, let delay):
                scheduleAnnotationRecoveryExpiry(identity, delay)
            case .showOverlay, .scheduleTransientHide, .cancelTransientHide:
                break
            }
        }
    }
}
