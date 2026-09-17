import Testing
import UserNotifications
@testable import Picky

struct PickySessionNotificationCenterTests {
    @Test func foregroundNotificationsAllowBannerAndNotificationCenterPresentation() {
        let options = PickyNotificationPresentationPolicy.foregroundOptions

        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(options.contains(.sound))
    }
}
