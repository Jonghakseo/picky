import Foundation

enum PickyHUDStatusTone: Equatable {
    case inProgress
    case error
    case completed
    case other
}

extension PickySessionStatus {
    var hudTone: PickyHUDStatusTone {
        switch self {
        case .running:
            return .inProgress
        case .blocked, .failed:
            return .error
        case .completed:
            return .completed
        case .queued, .waiting_for_input, .cancelled:
            return .other
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running, .waiting_for_input, .blocked: false
        }
    }

    var hudPriority: Int {
        switch self {
        case .waiting_for_input: 0
        case .running: 1
        case .queued: 2
        case .blocked: 3
        case .failed: 4
        case .completed: 5
        case .cancelled: 6
        }
    }

    func canTransition(to next: PickySessionStatus) -> Bool {
        if self == next { return true }
        switch self {
        case .failed, .cancelled:
            // Terminal sync recovery: when the user finishes the work in the Pi terminal
            // overlay after a failed/cancelled turn, the daemon imports the new assistant
            // answer and patches the session to `completed` (or `blocked` when recovery
            // surfaces a structural issue). Without allowing this transition the HUD would
            // keep showing the stale failed/cancelled status and recovery composer copy even
            // after the terminal sync banner reports imported messages. The reverse direction
            // (`completed -> failed`) is still gated so a delayed failure snapshot can't
            // undo a real completion.
            return next == .queued || next == .running || next == .completed || next == .blocked
        case .completed:
            return next == .queued || next == .running
        case .queued:
            return true
        case .running:
            return next != .queued
        case .waiting_for_input:
            return next != .queued
        case .blocked:
            return next != .queued
        }
    }
}
