//
//  PickyFeedbackSendStateMachine.swift
//  Picky
//
//  Pure feedback-send state transitions and their draft-retention effects.
//

import Foundation

enum PickyFeedbackSendStatus: Equatable, Sendable {
    case idle
    case sending
    case sent
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum PickyFeedbackDraftDisposition: Equatable, Sendable {
    case preserve
    case clear
}

struct PickyFeedbackSendFailure: Error, Equatable, Sendable {
    var message: String
}

struct PickyFeedbackSendStateMachine: Equatable, Sendable {
    private(set) var status: PickyFeedbackSendStatus = .idle

    /// Starts one send operation. A second submit while the first is in flight
    /// is ignored so a single draft cannot be delivered twice.
    mutating func beginSending() -> Bool {
        guard status != .sending else { return false }
        status = .sending
        return true
    }

    /// Applies the result for the active send. Only a confirmed success clears
    /// the draft; errors retain it so the user can inspect or retry unchanged.
    mutating func finish(_ result: Result<Void, PickyFeedbackSendFailure>) -> PickyFeedbackDraftDisposition {
        guard status == .sending else { return .preserve }

        switch result {
        case .success:
            status = .sent
            return .clear
        case .failure(let failure):
            status = .failed(failure.message)
            return .preserve
        }
    }

    mutating func resetSentStatus() {
        guard status == .sent else { return }
        status = .idle
    }
}
