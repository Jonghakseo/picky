//
//  PickyVoiceInputTarget.swift
//  Picky
//
//  Immutable routing intent captured once when a voice input begins.
//

import Foundation

struct PickyPTTPressObservation: Equatable {
    enum Source: Equatable {
        case keyboardShortcut
        case externalControl
        case direct
    }

    let screenPoint: CGPoint
    let observedAt: Date
    let source: Source
}

enum PickyGlobalPushToTalkEvent: Equatable {
    case pressed(PickyPTTPressObservation)
    case released
}

struct PickyScreenContextTargetSnapshot: Equatable {
    let sessionID: String
    let sticky: Bool
    let revision: UInt64
}

struct PickyVoiceInputTargetSnapshot: Equatable {
    enum PickleOrigin: Equatable {
        case pointer
        case armed(
            dispatchMode: PickyArmedPickleDispatchMode,
            sticky: Bool,
            revision: UInt64
        )
    }

    enum Target: Equatable {
        case main
        case pickle(sessionID: String, origin: PickleOrigin)
    }

    let inputID: UUID
    let target: Target

    var sessionID: String? {
        guard case .pickle(let sessionID, _) = target else { return nil }
        return sessionID
    }
}

enum PickyVoiceInputTargetPolicy {
    static func resolve(
        inputID: UUID,
        armedTarget: PickyScreenContextTargetSnapshot?,
        pointerSessionID: String?,
        armedDispatchMode: PickyArmedPickleDispatchMode
    ) -> PickyVoiceInputTargetSnapshot {
        if let armedTarget,
           let sessionID = PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(armedTarget.sessionID) {
            return PickyVoiceInputTargetSnapshot(
                inputID: inputID,
                target: .pickle(
                    sessionID: sessionID,
                    origin: .armed(
                        dispatchMode: armedDispatchMode,
                        sticky: armedTarget.sticky,
                        revision: armedTarget.revision
                    )
                )
            )
        }
        if let sessionID = PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(pointerSessionID) {
            return PickyVoiceInputTargetSnapshot(
                inputID: inputID,
                target: .pickle(sessionID: sessionID, origin: .pointer)
            )
        }
        return PickyVoiceInputTargetSnapshot(inputID: inputID, target: .main)
    }
}
