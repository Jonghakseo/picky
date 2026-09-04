//
//  PickyCompletionNotificationCoordinatorTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@Suite("PickyCompletionNotificationCoordinator")
@MainActor
struct PickyCompletionNotificationCoordinatorTests {
    @Test func routesOnlySelectedDestinationForEnabledCompletedEnvelope() async throws {
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            completionDestination: .both,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let notifications = PickyNoopNotificationCenter()
        var mainDeliveries: [PickyCompletionNotificationEnvelope] = []
        let coordinator = PickyCompletionNotificationCoordinator(
            preferencesProvider: preferences,
            notificationCenter: notifications,
            deliverMain: { mainDeliveries.append($0) }
        )
        let envelope = completionEnvelope()

        let channels = try await coordinator.route(envelope)

        #expect(channels == [.mainPicky, .macOS])
        #expect(mainDeliveries == [envelope])
        #expect(notifications.delivered.map(\.identifier) == ["session-1:4"])
    }

    @Test func deduplicatesAcceptedChannelsButRetriesFailedMainDelivery() async throws {
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            completionDestination: .both,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let notifications = PickyNoopNotificationCenter()
        var attempts = 0
        let coordinator = PickyCompletionNotificationCoordinator(
            preferencesProvider: preferences,
            notificationCenter: notifications,
            deliverMain: { _ in
                attempts += 1
                if attempts == 1 { throw TestError.failed }
            }
        )

        await #expect(throws: TestError.self) { try await coordinator.route(completionEnvelope()) }
        _ = try await coordinator.route(completionEnvelope())
        _ = try await coordinator.route(completionEnvelope())

        #expect(attempts == 2)
        #expect(notifications.delivered.count == 1)
    }

    @Test func policySuppressesBellOffAndNonCompletedEffects() {
        #expect(PickyCompletionNotificationRoutingPolicy.channels(
            bellEnabled: false,
            status: .completed,
            destination: .both
        ).isEmpty)
        #expect(PickyCompletionNotificationRoutingPolicy.channels(
            bellEnabled: true,
            status: .failed,
            destination: .both
        ).isEmpty)
        #expect(PickyCompletionNotificationRoutingPolicy.channels(
            bellEnabled: true,
            status: .completed,
            destination: .macOS
        ) == [.macOS])
    }

    private func completionEnvelope() -> PickyCompletionNotificationEnvelope {
        PickyCompletionNotificationEnvelope(
            completionId: "session-1:4",
            sessionID: "session-1",
            title: "Build report",
            status: .completed,
            summary: "Finished cleanly",
            prompt: "Pickle finished",
            cwd: "/tmp/project",
            bellEnabled: true
        )
    }

    private enum TestError: Error { case failed }
}
