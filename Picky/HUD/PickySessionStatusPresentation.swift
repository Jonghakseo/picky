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

}
