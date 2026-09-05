//
//  PickyCompletionNotificationCoordinatorTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@Suite("PickyCompletionNotificationCoordinator")
@MainActor
struct PickyCompletionNotificationCoordinatorTests {
    @Test func routesExactlyTheSnapshottedCompletionChannels() async throws {
        let cases: [(Bool, Bool, PickyCompletionNotificationRoutingPolicy.Channels)] = [
            (false, false, []),
            (true, false, [.mainPicky]),
            (false, true, [.macOS]),
            (true, true, [.mainPicky, .macOS]),
        ]

        for (notifyMain, notifyMacOS, expected) in cases {
            let notifications = PickyNoopNotificationCenter()
            var mainDeliveries: [PickyCompletionNotificationEnvelope] = []
            let coordinator = PickyCompletionNotificationCoordinator(
                notificationCenter: notifications,
                deliverMain: { mainDeliveries.append($0) }
            )
            let envelope = completionEnvelope(notifyMain: notifyMain, notifyMacOS: notifyMacOS)

            let channels = try await coordinator.route(envelope)

            #expect(channels == expected)
            #expect(mainDeliveries == (notifyMain ? [envelope] : []))
            #expect(notifications.delivered.map(\.identifier) == (notifyMacOS ? ["session-1:4"] : []))
        }
    }

    @Test func deduplicatesAcceptedChannelsButRetriesFailedMainDelivery() async throws {
        let notifications = PickyNoopNotificationCenter()
        var attempts = 0
        let coordinator = PickyCompletionNotificationCoordinator(
            notificationCenter: notifications,
            deliverMain: { _ in
                attempts += 1
                if attempts == 1 { throw TestError.failed }
            }
        )
        let envelope = completionEnvelope(notifyMain: true, notifyMacOS: true)

        await #expect(throws: TestError.self) { try await coordinator.route(envelope) }
        _ = try await coordinator.route(envelope)
        _ = try await coordinator.route(envelope)

        #expect(attempts == 2)
        #expect(notifications.delivered.count == 1)
    }

    @Test func coalescesConcurrentMainDeliveriesForTheSameCompletion() async throws {
        var attempts = 0
        let coordinator = PickyCompletionNotificationCoordinator(
            notificationCenter: PickyNoopNotificationCenter(),
            deliverMain: { _ in
                attempts += 1
                try await Task.sleep(for: .milliseconds(20))
            }
        )
        let envelope = completionEnvelope(notifyMain: true, notifyMacOS: false)

        async let first = coordinator.route(envelope)
        async let second = coordinator.route(envelope)
        let results = try await [first, second]

        #expect(results == [[.mainPicky], [.mainPicky]])
        #expect(attempts == 1)
    }

    @Test func policySuppressesNonCompletedEffects() {
        #expect(PickyCompletionNotificationRoutingPolicy.channels(
            notifyMainOnCompletion: true,
            notifyMacOSOnCompletion: true,
            status: .failed
        ).isEmpty)
    }

    private func completionEnvelope(
        notifyMain: Bool,
        notifyMacOS: Bool
    ) -> PickyCompletionNotificationEnvelope {
        PickyCompletionNotificationEnvelope(
            completionId: "session-1:4",
            sessionID: "session-1",
            title: "Build report",
            status: .completed,
            summary: "Finished cleanly",
            prompt: "Pickle finished",
            cwd: "/tmp/project",
            notifyMainOnCompletion: notifyMain,
            notifyMacOSOnCompletion: notifyMacOS
        )
    }

    private enum TestError: Error { case failed }
}
