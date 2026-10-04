//
//  PickySessionNotificationController.swift
//  Picky
//
//  Owns projection-driven notification deduplication and delivery.
//  Durable completion notifications remain app-coordinator owned.
//

@MainActor
final class PickySessionNotificationController {
    private let notificationCenter: PickyNotificationDelivering
    private let isConversationCardVisible: (String) -> Bool
    private let preferencesProvider: PickyNotificationPreferencesProviding
    private var deliveredNotificationKeys = Set<String>()

    init(
        notificationCenter: PickyNotificationDelivering,
        isConversationCardVisible: @escaping (String) -> Bool,
        preferencesProvider: PickyNotificationPreferencesProviding
    ) {
        self.notificationCenter = notificationCenter
        self.isConversationCardVisible = isConversationCardVisible
        self.preferencesProvider = preferencesProvider
    }

    func markDeliveredIfNeeded(for session: PickySessionCard) {
        guard let notification = notification(for: session) else { return }
        deliveredNotificationKeys.insert(notification.key)
    }

    func deliverIfNeeded(for session: PickySessionCard) {
        guard let notification = notification(for: session) else {
            deliveredNotificationKeys.subtract(
                PickySessionNotificationPolicy.terminalDedupKeysToReset(
                    sessionID: session.id,
                    status: session.status
                )
            )
            return
        }

        guard !deliveredNotificationKeys.contains(notification.key) else { return }
        deliveredNotificationKeys.insert(notification.key)
        // Suppressed alerts remain consumed across subsequent projection updates.
        guard !isConversationCardVisible(session.id) else { return }
        notificationCenter.deliver(title: notification.title, body: notification.body, identifier: notification.key)
    }

    func clearTerminalNotifications(sessionID: String) {
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
    }

    func forgetSession(sessionID: String) {
        deliveredNotificationKeys = deliveredNotificationKeys.filter { !$0.hasPrefix("\(sessionID):") }
    }

    private func notification(for session: PickySessionCard) -> PickySessionNotificationPolicy.Notification? {
        PickySessionNotificationPolicy.notification(
            for: PickySessionNotificationPolicy.Input(card: session),
            preferences: preferencesProvider.notificationPreferences
        )
    }
}
