//
//  PickyCompletionNotificationCoordinator.swift
//  Picky
//
//  App-owned fan-out for durable completion envelopes.
//

import Foundation

@MainActor
final class PickyCompletionNotificationCoordinator {
    typealias MainDelivery = (PickyCompletionNotificationEnvelope) async throws -> Void

    private let preferencesProvider: PickyNotificationPreferencesProviding
    private let notificationCenter: PickyNotificationDelivering
    private let deliverMain: MainDelivery
    private var acceptedChannels = Set<String>()

    init(
        preferencesProvider: PickyNotificationPreferencesProviding,
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        deliverMain: @escaping MainDelivery
    ) {
        self.preferencesProvider = preferencesProvider
        self.notificationCenter = notificationCenter
        self.deliverMain = deliverMain
    }

    /// Snapshots settings once, then records each accepted channel independently.
    /// A repeated bridge request never repeats an accepted effect, while a main
    /// delivery that throws remains eligible for retry on the next request.
    func route(_ envelope: PickyCompletionNotificationEnvelope) async throws -> PickyCompletionNotificationRoutingPolicy.Channels {
        let destination = preferencesProvider.notificationPreferences.completionDestination
        let channels = PickyCompletionNotificationRoutingPolicy.channels(
            bellEnabled: envelope.bellEnabled,
            status: envelope.status,
            destination: destination
        )

        if channels.contains(.macOS), accept(channel: "macos", completionId: envelope.completionId) {
            let notification = PickyCompletionNotificationRoutingPolicy.macOSNotification(for: envelope)
            notificationCenter.deliver(
                title: notification.title,
                body: notification.body,
                identifier: notification.identifier
            )
        }

        if channels.contains(.mainPicky), !acceptedChannels.contains(channelKey("main", completionId: envelope.completionId)) {
            try await deliverMain(envelope)
            acceptedChannels.insert(channelKey("main", completionId: envelope.completionId))
        }
        return channels
    }

    private func accept(channel: String, completionId: String) -> Bool {
        acceptedChannels.insert(channelKey(channel, completionId: completionId)).inserted
    }

    private func channelKey(_ channel: String, completionId: String) -> String {
        "\(completionId):\(channel)"
    }
}
