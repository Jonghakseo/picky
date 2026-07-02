//
//  PickyVoiceTranscriptRoutingPolicy.swift
//  Picky
//
//  Pure routing decisions for finalized voice transcripts.
//

import Foundation

enum PickyVoiceTranscriptRoutingPolicy {
    enum Route: Equatable {
        case submitToMain
        case steerPickle(sessionID: String)
        case followUpPickle(sessionID: String)
    }

    static func route(
        voiceFollowUpSessionID: String?,
        screenContextTargetSessionID: String?,
        armedDispatchMode: PickyArmedPickleDispatchMode = .followUp
    ) -> Route {
        guard let targetSessionID = normalizedSessionID(voiceFollowUpSessionID) else {
            return .submitToMain
        }
        if screenContextTargetSessionID == targetSessionID {
            switch armedDispatchMode {
            case .followUp:
                return .followUpPickle(sessionID: targetSessionID)
            case .steer:
                return .steerPickle(sessionID: targetSessionID)
            }
        }
        return .followUpPickle(sessionID: targetSessionID)
    }

    static func normalizedSessionID(_ sessionID: String?) -> String? {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
