//
//  PickyMainCancelPillPolicy.swift
//  Picky
//
//  Pure state and presentation policy for the main-turn cancel control.
//

import CoreGraphics
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
        hasLiveActivities: Bool,
        hasActiveFollowUpTurn: Bool = false
    ) -> Bool {
        if hasPendingAgentResponse || isWaitingForCursorResponse || hasLiveActivities || hasActiveFollowUpTurn {
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

    /// Escape confirmation must be two physical presses: key-repeat events from
    /// a held key never advance the state machine.
    static func shouldHandleEscape(
        eventType: CGEventType,
        keyCode: UInt16,
        isAutorepeat: Bool
    ) -> Bool {
        eventType == .keyDown && keyCode == 53 && !isAutorepeat
    }

    /// Pickle-scoped aborts retain the pre-pill voice semantics. The broader
    /// in-flight projection governs visibility only; it must not let a late PTT
    /// press cancel a completed Pickle with a stale target ID.
    static func shouldAbortFollowUpPickle(
        hasPendingAgentResponse: Bool,
        voiceState: CompanionVoiceState
    ) -> Bool {
        hasPendingAgentResponse || voiceState == .responding
    }

    static func stateAfterCancellationAttempt(succeeded: Bool) -> PickyMainCancelPillState {
        succeeded ? .cancelled : .rest
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
