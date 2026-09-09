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

    @Test func deliversPlainTextToMacOSWithoutChangingMainCompletion() async throws {
        let cases: [(String?, String)] = [
            ("## 완료 **수정** `file.swift`", "완료 수정 file.swift"),
            ("- **완료**\n- `test` 통과", "완료\ntest 통과"),
            ("```swift\nlet count = 1\n```", "let count = 1"),
            ("[문서](https://example.com)와 ~~이전~~ 결과", "문서와 이전 결과"),
            ("foo_bar에서 2 * 3 계산 (#123)", "foo_bar에서 2 * 3 계산 (#123)"),
            ("  \n ", "Build report"),
            (nil, "Build report"),
            ("---", "Build report"),
        ]
        for (summary, expected) in cases {
            let notifications = PickyNoopNotificationCenter()
            var mainDeliveries: [PickyCompletionNotificationEnvelope] = []
            let coordinator = PickyCompletionNotificationCoordinator(
                notificationCenter: notifications,
                deliverMain: { mainDeliveries.append($0) }
            )
            let envelope = completionEnvelope(notifyMain: true, notifyMacOS: true, summary: summary)

            _ = try await coordinator.route(envelope)

            #expect(notifications.delivered.map(\.body) == [expected])
            #expect(mainDeliveries == [envelope])
        }
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
        notifyMacOS: Bool,
        summary: String? = "Finished cleanly"
    ) -> PickyCompletionNotificationEnvelope {
        PickyCompletionNotificationEnvelope(
            completionId: "session-1:4",
            sessionID: "session-1",
            title: "Build report",
            status: .completed,
            summary: summary,
            prompt: "Pickle finished",
            cwd: "/tmp/project",
            notifyMainOnCompletion: notifyMain,
            notifyMacOSOnCompletion: notifyMacOS
        )
    }

    private enum TestError: Error { case failed }
}
