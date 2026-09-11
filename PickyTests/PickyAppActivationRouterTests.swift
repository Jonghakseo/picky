import Testing
@testable import Picky

@MainActor
struct PickyAppActivationRouterTests {
    @Test func dockReopenPresentsHubAfterNotificationResponseOpportunity() {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0

        router.handleReopen {
            hubPresentationCount += 1
        }

        #expect(hubPresentationCount == 0)
        scheduler.runAll()
        #expect(hubPresentationCount == 1)
    }

    @Test func notificationAfterReopenCancelsHubAndOpensOnlyPickle() {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        router.handleReopen {
            hubPresentationCount += 1
        }
        router.handleNotificationResponse(identifier: "pickle-1:completed") { sessionID in
            openedSessionIDs.append(sessionID)
        }
        scheduler.runAll()

        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test func reopenAfterNotificationIsSuppressedAndOpensOnlyPickle() {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0
        var openedSessionIDs: [String] = []

        router.handleNotificationResponse(identifier: "pickle-1:waiting:request-1") { sessionID in
            openedSessionIDs.append(sessionID)
        }
        router.handleReopen {
            hubPresentationCount += 1
        }
        scheduler.runAll()

        #expect(hubPresentationCount == 0)
        #expect(openedSessionIDs == ["pickle-1"])
    }

    @Test func laterDockReopenStillPresentsHubAfterNotificationSuppressionExpires() {
        let scheduler = ManualAppActivationScheduler()
        let router = PickyAppActivationRouter(schedule: scheduler.schedule)
        var hubPresentationCount = 0

        router.handleNotificationResponse(identifier: "pickle-1:failed") { _ in }
        scheduler.runAll()
        router.handleReopen {
            hubPresentationCount += 1
        }
        scheduler.runAll()

        #expect(hubPresentationCount == 1)
    }
}

@MainActor
private final class ManualAppActivationScheduler {
    private var actions: [@MainActor () -> Void] = []

    func schedule(_ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }

    func runAll() {
        while !actions.isEmpty {
            actions.removeFirst()()
        }
    }
}
