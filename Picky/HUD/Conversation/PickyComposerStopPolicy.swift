//
//  PickyComposerStopPolicy.swift
//  Picky
//

import Foundation

/// When the composer's stop button acts and how long its failure message stays.
enum PickyComposerStopPolicy {
    static func canStop(_ status: PickySessionStatus) -> Bool {
        [.running, .queued, .waiting_for_input].contains(status)
    }

    /// A stop failure describes the run the user tried to stop. Once that run has ended,
    /// the message is outdated and no stop button remains to retry or dismiss it. This
    /// also applies to a failure that arrives after the run ended. `blocked` keeps the
    /// message: it is how a failed async cleanup surfaces.
    static func stopErrorExpires(at status: PickySessionStatus) -> Bool {
        [.completed, .failed, .cancelled].contains(status)
    }

    static func message(for error: Error, at status: PickySessionStatus) -> String? {
        stopErrorExpires(at: status) ? nil : error.localizedDescription
    }

    /// Whether a stop needs the user to decide what happens to running background tasks.
    /// Without background tasks a stop ends everything right away, as before.
    static func choice(activeBackgroundTaskCount: Int, agentPhase: PickyAgentCycle.Phase?) -> PickyStopChoice {
        guard activeBackgroundTaskCount > 0 else { return .immediate }
        switch agentPhase {
        case .responding, .compacting: return .responseOrAll
        case .idle, .settled, nil: return .backgroundOnly
        }
    }
}

enum PickyStopChoice: Equatable {
    /// No background tasks: stop everything without asking.
    case immediate
    /// A response is in flight and background tasks run: stop only the response, or both.
    case responseOrAll
    /// Only background tasks remain: confirm before stopping them.
    case backgroundOnly
}

struct PickyStopChoiceRequest: Equatable {
    let sessionID: String
    let choice: PickyStopChoice
}
