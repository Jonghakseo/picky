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
///
/// Both predicates read the daemon frame, never the card that was in the
/// registry before it. Local optimistic writes (`abort` marks the card
/// `.cancelled` right after sending the command) would otherwise make the
/// daemon's own terminal report look like a repeat, and the cursor would stay
/// in `.processing` forever. The only cross-frame memory needed for that is the
/// status the daemon last reported, which lives here.
///
/// A frame the view model never applies publishes nothing. Transactions the
/// recovery coordinator buffers behind a revision gap or an epoch change are
/// exactly that case: the cursor and the passive summary stay on the last
/// applied state until the correlated recovery snapshot lands and converges
/// them. The delay is bounded by the recovery deadline, after which the
/// projection owner reconnects and bootstraps.
@MainActor
final class PickySessionProjectionTransitionPublisher {
    let sessionBecameTerminal = PassthroughSubject<PickySessionTerminalTransition, Never>()
    let summaryPresentationChanged = PassthroughSubject<PickySessionSummaryPresentation, Never>()

    /// The status each session was last reported to hold *by the daemon*.
    private var lastDaemonReportedStatusBySessionID: [String: PickySessionStatus] = [:]

    /// A snapshot republishes the whole projection, so its summary is always
    /// re-announced and its status is always the daemon's current one.
    func publish(snapshot: PickySessionProjectionSnapshot, applied card: PickySessionCard) {
        noteDaemonReportedStatus(snapshot.projection.status, sessionID: card.id)
        sendSummaryPresentation(for: card)
    }

    /// A transaction carries a partial patch, so only the fields it actually
    /// sets count: status for the terminal rule, and title/status/lastSummary
    /// for the summary. Mutations are walked in order, matching the daemon's
    /// own application order.
    func publish(transaction: PickySessionProjectionTransaction, applied card: PickySessionCard) {
        var summaryFieldChanged = false
        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation else { continue }
            if case .set(let status) = patch.status {
                noteDaemonReportedStatus(status, sessionID: card.id)
                summaryFieldChanged = true
            }
            if case .set = patch.title { summaryFieldChanged = true }
            switch patch.lastSummary {
            case .unchanged: break
            case .clear, .set: summaryFieldChanged = true
            }
        }
        guard summaryFieldChanged else { return }
        sendSummaryPresentation(for: card)
    }

    /// Forgets sessions the daemon no longer has, so a later session reusing the
    /// same ID is judged from scratch. Call this only for authoritative removal
    /// (bootstrap-completion reconcile, permanent deletion); archived sessions
    /// still exist and must keep their remembered status.
    func forgetSessions(_ sessionIDs: some Sequence<String>) {
        for sessionID in sessionIDs { lastDaemonReportedStatusBySessionID.removeValue(forKey: sessionID) }
    }

    private func noteDaemonReportedStatus(_ status: PickySessionStatus, sessionID: String) {
        let previous = lastDaemonReportedStatusBySessionID[sessionID]
        lastDaemonReportedStatusBySessionID[sessionID] = status
        guard status.isTerminal, previous?.isTerminal != true else { return }
        sessionBecameTerminal.send(PickySessionTerminalTransition(sessionID: sessionID, status: status))
    }

    private func sendSummaryPresentation(for card: PickySessionCard) {
        // The applied card is the frame that was just folded in, so its fields
        // are the daemon's values, not a stale optimistic guess.
        summaryPresentationChanged.send(PickySessionSummaryPresentation(
            sessionID: card.id,
            title: card.title,
            status: card.status,
            lastSummary: card.lastSummary
        ))
    }
}
