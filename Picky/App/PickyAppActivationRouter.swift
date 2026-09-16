//
//  PickyAppActivationRouter.swift
//  Picky
//
//  Keeps notification-driven activation on its Pickle HUD route. AppKit can
//  deliver more than one reopen around a notification response, independently
//  of the response's hop to the main actor.
//

import Foundation
import os

@MainActor
final class PickyAppActivationRouter {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    struct NotificationResponse: Sendable {
        let sessionID: String
        fileprivate let generation: UInt64
    }

    private struct NotificationState: Sendable {
        var generation: UInt64 = 0
        var suppressReopens = false
    }

    private let schedule: Schedule
    private var reopenGeneration: UInt64 = 0
    private nonisolated let notificationState = OSAllocatedUnfairLock(initialState: NotificationState())

    init(schedule: @escaping Schedule = PickyAppActivationRouter.scheduleAfterDelay) {
        self.schedule = schedule
    }

    func handleReopen(showHub: @escaping @MainActor () -> Void) {
        reopenGeneration &+= 1
        let notification = notificationState.withLock { $0 }
        guard !notification.suppressReopens else { return }

        let requestGeneration = reopenGeneration
        schedule(0.1) { [weak self] in
            guard let self, reopenGeneration == requestGeneration else { return }
            let currentNotification = notificationState.withLock { $0 }
            guard !currentNotification.suppressReopens,
                  currentNotification.generation == notification.generation else { return }
            showHub()
        }
    }

    /// Record the source on UserNotifications' callback queue, before hopping to
    /// MainActor. A queued Hub presentation must see it even if HUD work is delayed.
    nonisolated func recordNotificationResponse(identifier: String) -> NotificationResponse? {
        let sessionID = identifier
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard !sessionID.isEmpty else { return nil }

        return notificationState.withLock { state in
            state.generation &+= 1
            state.suppressReopens = true
            return NotificationResponse(sessionID: sessionID, generation: state.generation)
        }
    }

    func handleNotificationResponse(
        _ response: NotificationResponse,
        openSession: @escaping @MainActor (String) -> Void
    ) {
        openSession(response.sessionID)

        // The reopen callback has no notification ID. Keep a bounded activation
        // window, rather than consuming a one-shot flag or expiring after 100ms.
        // Suppress reopens during this window; a later ordinary Dock reopen
        // still presents Hub. Never close an existing Hub.
        schedule(1) { [weak self] in
            self?.notificationState.withLock { state in
                guard state.generation == response.generation else { return }
                state.suppressReopens = false
            }
        }
    }

    private static func scheduleAfterDelay(
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
