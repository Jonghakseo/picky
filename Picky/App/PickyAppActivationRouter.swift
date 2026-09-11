//
//  PickyAppActivationRouter.swift
//  Picky
//
//  Coalesces macOS reopen events with notification responses. AppKit and
//  UserNotifications do not guarantee which delegate callback arrives first,
//  so notification intent wins within one short activation window.
//

import Foundation

@MainActor
final class PickyAppActivationRouter {
    typealias Schedule = (@escaping @MainActor () -> Void) -> Void

    private let schedule: Schedule
    private var generation: UInt64 = 0
    private var suppressNextReopen = false

    init(schedule: @escaping Schedule = PickyAppActivationRouter.scheduleAfterSystemResponseOpportunity) {
        self.schedule = schedule
    }

    func handleReopen(showHub: @escaping @MainActor () -> Void) {
        generation &+= 1
        if suppressNextReopen {
            suppressNextReopen = false
            return
        }

        let requestGeneration = generation
        schedule { [weak self] in
            guard let self, generation == requestGeneration else { return }
            showHub()
        }
    }

    func handleNotificationResponse(
        identifier: String,
        openSession: @escaping @MainActor (String) -> Void
    ) {
        generation &+= 1
        let responseGeneration = generation
        suppressNextReopen = true
        let sessionID = identifier
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? identifier
        openSession(sessionID)

        schedule { [weak self] in
            guard let self, generation == responseGeneration else { return }
            suppressNextReopen = false
        }
    }

    private static func scheduleAfterSystemResponseOpportunity(
        _ action: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
