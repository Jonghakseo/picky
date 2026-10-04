//
//  CompanionManager+SessionProjectionTransitions.swift
//  Picky
//

import Combine
import Foundation

extension CompanionManager {
    /// Subscribes to the session stack's published projection transitions.
    ///
    /// Companion deliberately does not fold raw projection frames itself. The
    /// session view model applies a frame and then publishes what changed, so
    /// the "first terminal arrival" rule lives in one place and Companion keeps
    /// no previous-status or presentation cache of its own. Sends are
    /// synchronous, so cursor release happens inside the same call stack that
    /// applied the frame.
    ///
    /// Call this before the session view model starts consuming events;
    /// projection frames are not replayed to late subscribers.
    func bindSessionProjectionTransitions(to publisher: PickySessionProjectionTransitionPublisher) {
        guard sessionProjectionTransitionCancellables.isEmpty else { return }
        publisher.sessionBecameTerminal
            .sink { [weak self] transition in
                self?.handleSessionBecameTerminal(transition)
            }
            .store(in: &sessionProjectionTransitionCancellables)
        publisher.summaryPresentationChanged
            .sink { [weak self] presentation in
                self?.handleSessionSummaryPresentationChanged(presentation)
            }
            .store(in: &sessionProjectionTransitionCancellables)
    }

    func handleSessionBecameTerminal(_ transition: PickySessionTerminalTransition) {
        releaseCursorForTerminatedSession(sessionID: transition.sessionID, status: transition.status)
    }

    /// Composition of the visible text stays here: the passive summary is a
    /// Companion presentation concern, and the status fallback is what the
    /// cursor shows for a session that has no summary yet.
    func handleSessionSummaryPresentationChanged(_ presentation: PickySessionSummaryPresentation) {
        let summary = presentation.lastSummary.isEmpty
            ? "\(presentation.title) · \(presentation.status.rawValue)"
            : presentation.lastSummary
        updatePassiveAgentSummary(summary)
    }
}
