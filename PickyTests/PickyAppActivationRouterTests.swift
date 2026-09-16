import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAppActivationRouterTests {
    @Test func dockReopenPresentsHubAfterNotificationResponseOpportunity() {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0

        router.handleReopen { hubPresentationCount += 1 }

        #expect(hubPresentationCount == 0)
        scheduler.advance(by: 0.1)
        #expect(hubPresentationCount == 1)
    }

    @Test(arguments: ["pickle-1:4", "pickle-1:failed", "pickle-1:waiting:request-1"])
    func notificationAfterReopenCancelsHubAndOpensOnlySourcePickle(identifier: String) throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        router.handleReopen { hubPresentationCount += 1 }
        let response = try #require(router.recordNotificationResponse(identifier: identifier))
        router.handleNotificationResponse(response) { openedSessionIDs.append($0) }
        scheduler.advance(by: 2)

        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test func notificationReceiptCancelsHubBeforeHUDMainActorDelivery() async throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        router.handleReopen { hubPresentationCount += 1 }
        // UserNotifications enters off-main. Its HUD Task can run after the
        // already-scheduled Hub action, so receipt itself must cancel that action.
        let response = await Task.detached {
            router.recordNotificationResponse(identifier: "pickle-1:4")
        }.value
        scheduler.advance(by: 2)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 2)
        #expect(hubPresentationCount == 0)

        router.handleNotificationResponse(try #require(response)) { openedSessionIDs.append($0) }
        scheduler.advance(by: 2)
        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test func repeatedAndDelayedReopensAfterNotificationDoNotPresentHub() throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        let response = try #require(router.recordNotificationResponse(identifier: "pickle-1:4"))
        router.handleNotificationResponse(response) { openedSessionIDs.append($0) }
        router.handleReopen { hubPresentationCount += 1 }
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 0.2)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 0.5)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 2)

        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test func laterDockReopenStillPresentsHubAfterNotificationSuppressionExpires() throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0

        let response = try #require(router.recordNotificationResponse(identifier: "pickle-1:failed"))
        router.handleNotificationResponse(response) { _ in }
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 2)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 0.2)

        #expect(hubPresentationCount == 1)
    }

    @Test func olderNotificationExpiryCannotReleaseNewerNotificationActivation() throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        let first = try #require(router.recordNotificationResponse(identifier: "pickle-1:4"))
        router.handleNotificationResponse(first) { openedSessionIDs.append($0) }
        scheduler.advance(by: 0.8)
        let second = try #require(router.recordNotificationResponse(identifier: "pickle-2:9"))
        router.handleNotificationResponse(second) { openedSessionIDs.append($0) }
        scheduler.advance(by: 0.4)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 2)

        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1", "pickle-2"])
    }

    @Test func notificationDoesNotPresentAnAlreadyOpenHubAgain() throws {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 0.2)
        #expect(hubPresentationCount == 1)

        let response = try #require(router.recordNotificationResponse(identifier: "pickle-1:4"))
        router.handleNotificationResponse(response) { openedSessionIDs.append($0) }
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 2)

        #expect(hubPresentationCount == 1)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test(arguments: ["", ":completed"])
    func notificationWithoutSessionIDDoesNotSuppressOrdinaryReopen(identifier: String) {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0

        #expect(router.recordNotificationResponse(identifier: identifier) == nil)
        router.handleReopen { hubPresentationCount += 1 }
        scheduler.advance(by: 0.2)

        #expect(hubPresentationCount == 1)
    }
}

@MainActor
private final class ManualAppActivationScheduler {
    private var now: TimeInterval = 0
    private var actions: [(deadline: TimeInterval, action: @MainActor () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        actions.append((now + delay, action))
    }

    func advance(by duration: TimeInterval) {
        let target = now + duration
        while let next = actions.indices.min(by: { actions[$0].deadline < actions[$1].deadline }),
              actions[next].deadline <= target {
            let scheduled = actions.remove(at: next)
            now = scheduled.deadline
            scheduled.action()
        }
        now = target
    }
}
