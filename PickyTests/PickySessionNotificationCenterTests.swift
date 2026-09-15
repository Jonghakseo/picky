import Testing
import UserNotifications
@testable import Picky

struct PickySessionNotificationCenterTests {
    @Test func foregroundNotificationsShowAsBannersWithoutEnteringTheList() {
        let options = PickyNotificationPresentationPolicy.foregroundOptions

        #expect(options.contains(.banner))
        #expect(options.contains(.sound))
        #expect(!options.contains(.list))
    }

    @Test func successfulDeliveryReplacesOlderEntriesAndExpiresFromNotificationCenter() throws {
        let request = makeRequest(identifier: "session-1:completed")
        var clearCount = 0
        var addedIdentifiers: [String] = []
        var scheduledDelay: TimeInterval?
        var scheduledRemoval: (() -> Void)?
        var removedIdentifiers: [[String]] = []

        PickyTransientNotificationCenter.add(
            request,
            clearDelivered: { clearCount += 1 },
            addRequest: { request, completion in
                addedIdentifiers.append(request.identifier)
                completion(nil)
            },
            removeDelivered: { removedIdentifiers.append($0) },
            schedule: { delay, action in
                scheduledDelay = delay
                scheduledRemoval = action
            }
        )

        #expect(clearCount == 1)
        #expect(addedIdentifiers == [request.identifier])
        #expect(scheduledDelay == PickyTransientNotificationCenter.deliveredLifetime)
        #expect(removedIdentifiers.isEmpty)

        let removal = try #require(scheduledRemoval)
        removal()
        #expect(removedIdentifiers == [[request.identifier]])
    }

    @Test func failedDeliveryDoesNotScheduleNotificationCenterRemoval() {
        let request = makeRequest(identifier: "session-1:failed")
        var scheduledCount = 0
        var failures: [String] = []

        PickyTransientNotificationCenter.add(
            request,
            clearDelivered: {},
            addRequest: { _, completion in completion(TestFailure.delivery) },
            removeDelivered: { _ in },
            schedule: { _, _ in scheduledCount += 1 },
            onFailure: { failures.append(String(describing: $0)) }
        )

        #expect(scheduledCount == 0)
        #expect(failures == ["delivery"])
    }

    private func makeRequest(identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Pickle finished"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private enum TestFailure: Error {
        case delivery
    }
}
