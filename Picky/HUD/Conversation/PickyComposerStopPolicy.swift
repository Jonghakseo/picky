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
}
