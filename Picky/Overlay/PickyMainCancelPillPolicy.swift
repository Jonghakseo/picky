//
//  PickyMainCancelPillPolicy.swift
//  Picky
//
//  Pure state and presentation policy for the main-turn cancel control.
//

import Foundation

/// Visual states for the main-turn cancellation control.
enum PickyMainCancelPillState: Equatable {
    case rest
    case hover
    case escapeArmed
    case cancelled
}

enum PickyMainCancelPillPolicy {
    static let escapeConfirmationWindow: TimeInterval = 0.8
    static let cancellationConfirmationDuration: TimeInterval = 1.2

    /// A main turn can be cancelled while it is waiting for a reply, narrating,
    /// or reporting live activity. The inputs deliberately cover typed Quick
    /// Input turns as well as voice-originated turns.
    static func isMainTurnInFlight(
        hasPendingAgentResponse: Bool,
        voiceState: CompanionVoiceState,
        isWaitingForCursorResponse: Bool,
        hasLiveActivities: Bool
    ) -> Bool {
        if hasPendingAgentResponse || isWaitingForCursorResponse || hasLiveActivities {
            return true
        }
        switch voiceState {
        case .processing, .responding:
            return true
        case .idle, .listening:
            return false
        }
    }

    static func shouldPresent(isMainTurnInFlight: Bool, isPickyPanelKeyWindow: Bool) -> Bool {
        isMainTurnInFlight && !isPickyPanelKeyWindow
    }

    static func stateAfterHover(_ isHovering: Bool, currentState: PickyMainCancelPillState) -> PickyMainCancelPillState {
        switch currentState {
        case .rest, .hover:
            return isHovering ? .hover : .rest
        case .escapeArmed, .cancelled:
            return currentState
        }
    }

    static func stateAfterEscape(currentState: PickyMainCancelPillState) -> PickyMainCancelPillState {
        switch currentState {
        case .cancelled:
            return .cancelled
        case .rest, .hover:
            return .escapeArmed
        case .escapeArmed:
            return .cancelled
        }
    }
}
