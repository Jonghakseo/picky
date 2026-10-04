import Testing
import UserNotifications
@testable import Picky

struct PickySessionNotificationCenterTests {
    @MainActor @Test func onlyOpenCardsOnVisibleHUDsSuppressNotifications() {
        let visibility = PickyHUDActualPanelVisibilityStore()
        visibility.setVisible(true, for: 1)
        visibility.setVisible(false, for: 2)
        visibility.setOpenedSession("first", for: 1)
        visibility.setOpenedSession("second", for: 2)

        #expect(visibility.isConversationCardVisible(sessionID: "first"))
        #expect(!visibility.isConversationCardVisible(sessionID: "second"))
        #expect(!visibility.isConversationCardVisible(sessionID: "dock-only"))

        visibility.setVisible(true, for: 2)
        #expect(visibility.isConversationCardVisible(sessionID: "second"))
        visibility.setOpenedSession(nil, for: 1)
        #expect(!visibility.isConversationCardVisible(sessionID: "first"))
        #expect(visibility.isConversationCardVisible(sessionID: "second"))

        visibility.setVisible(false, for: 2)
        #expect(!visibility.isConversationCardVisible(sessionID: "second"))
    }

    @MainActor @Test func removingDisplaysClearsRetainedOpenCards() {
        let visibility = PickyHUDActualPanelVisibilityStore()
        visibility.setVisible(true, for: 1)
        visibility.setOpenedSession("first", for: 1)
        visibility.removePanel(for: 1)
        visibility.setVisible(true, for: 1)
        #expect(!visibility.isConversationCardVisible(sessionID: "first"))

        visibility.setOpenedSession("first", for: 1)
        visibility.setVisible(false, for: 1)
        visibility.removeAllPanels()
        visibility.setVisible(true, for: 1)
        #expect(!visibility.isConversationCardVisible(sessionID: "first"))
    }

    @Test func foregroundNotificationsAllowBannerAndNotificationCenterPresentation() {
        let options = PickyNotificationPresentationPolicy.foregroundOptions

        #expect(options.contains(.banner))
        #expect(options.contains(.list))
        #expect(options.contains(.sound))
    }
}
