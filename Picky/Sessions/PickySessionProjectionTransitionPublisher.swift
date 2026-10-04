//
//  PickySessionProjectionTransitionPublisher.swift
//  Picky
//

import Combine
import Foundation

/// A session arriving in a terminal status for the first time.
struct PickySessionTerminalTransition: Equatable {
    let sessionID: String
    let status: PickySessionStatus
}

/// The three projection fields a passive cursor summary is composed from.
/// Composition and the speaking guard stay with the Companion surface that
/// renders the text; this value only reports what the applied card now holds.
struct PickySessionSummaryPresentation: Equatable {
    let sessionID: String
    let title: String
    let status: PickySessionStatus
    /// Empty when the projection carries no summary, matching `SessionCard`.
    let lastSummary: String
}

/// Publishes session-projection transitions that non-session surfaces react to.
///
/// The view model applies a projection frame and only then publishes what
/// changed, so every consumer observes transitions against state that is
/// already committed. Keeping this here, rather than letting each consumer
/// subscribe to the raw event stream, means the "first terminal arrival"
/// predicate exists exactly once and no consumer needs its own previous-status
/// cache. Sends are synchronous, so a consumer's reaction completes inside the
/// same call stack that applied the frame.
@MainActor
final class PickySessionProjectionTransitionPublisher {
    /// Which application path produced the frame. A snapshot republishes the
    /// whole projection, so its summary is always re-announced; a transaction
    /// carries a partial patch and only announces a real field change.
    enum Frame {
        case snapshot
        case transaction
    }

    let sessionBecameTerminal = PassthroughSubject<PickySessionTerminalTransition, Never>()
    let summaryPresentationChanged = PassthroughSubject<PickySessionSummaryPresentation, Never>()

    func publish(previous: PickySessionCard?, applied card: PickySessionCard, frame: Frame) {
        // `previous` is read from the registry, which keeps a store for archived
        // sessions too, so a terminal republish for an archived session is still
        // recognized as a repeat rather than a first arrival.
        if card.status.isTerminal, previous?.status.isTerminal != true {
            sessionBecameTerminal.send(
                PickySessionTerminalTransition(sessionID: card.id, status: card.status)
            )
        }
        guard frame == .snapshot || summaryFieldsChanged(previous: previous, card: card) else { return }
        summaryPresentationChanged.send(PickySessionSummaryPresentation(
            sessionID: card.id,
            title: card.title,
            status: card.status,
            lastSummary: card.lastSummary
        ))
    }

    private func summaryFieldsChanged(previous: PickySessionCard?, card: PickySessionCard) -> Bool {
        guard let previous else { return true }
        return previous.title != card.title
            || previous.status != card.status
            || previous.lastSummary != card.lastSummary
    }
}
