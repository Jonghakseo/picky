//
//  CompanionManager+SessionProjectionTransitions.swift
//  Picky
//

import Combine
import Foundation

extension CompanionManager {
    /// Injects the session stack's transition publisher and subscribes.
    ///
    /// Companion does not fold raw projection frames itself: the view model
    /// applies a frame and then publishes what changed, so the "first terminal
    /// arrival" rule lives in one place and Companion keeps no status cache.
    /// Sends are synchronous, so cursor release happens inside the same call
    /// stack that applied the frame. Call this before the view model consumes
    /// its first event (frames are not replayed to late subscribers); the
    /// reference is kept so `start()` can re-subscribe.
    func bindSessionProjectionTransitions(to publisher: PickySessionProjectionTransitionPublisher) {
        sessionProjectionTransitionSource = publisher
        subscribeToSessionProjectionTransitions()
    }

    /// Subscription half, re-run by `start()` because `stop()` cancels it.
    func subscribeToSessionProjectionTransitions() {
        guard sessionProjectionTransitionCancellables.isEmpty,
              let publisher = sessionProjectionTransitionSource else { return }
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
    /// cursor shows for a session with no summary yet.
    func handleSessionSummaryPresentationChanged(_ presentation: PickySessionSummaryPresentation) {
        let summary = presentation.lastSummary.isEmpty
            ? "\(presentation.title) · \(presentation.status.rawValue)"
            : presentation.lastSummary
        updatePassiveAgentSummary(summary)
    }
}
