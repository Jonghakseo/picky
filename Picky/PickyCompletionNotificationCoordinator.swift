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

    private struct MainDeliveryAttempt {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let notificationCenter: PickyNotificationDelivering
    private let deliverMain: MainDelivery
    private var acceptedChannels = Set<String>()
    private var mainDeliveriesInFlight: [String: MainDeliveryAttempt] = [:]

    init(
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        deliverMain: @escaping MainDelivery
    ) {
        self.notificationCenter = notificationCenter
        self.deliverMain = deliverMain
    }

    /// Records each channel from the durable completion snapshot independently.
    /// A repeated bridge request never repeats an accepted effect, while a main
    /// delivery that throws remains eligible for retry on the next request.
    func route(_ envelope: PickyCompletionNotificationEnvelope) async throws -> PickyCompletionNotificationRoutingPolicy.Channels {
        let channels = PickyCompletionNotificationRoutingPolicy.channels(
            notifyMainOnCompletion: envelope.notifyMainOnCompletion,
            notifyMacOSOnCompletion: envelope.notifyMacOSOnCompletion,
            status: envelope.status
        )

        if channels.contains(.macOS), accept(channel: "macos", completionId: envelope.completionId) {
            let notification = PickyCompletionNotificationRoutingPolicy.macOSNotification(for: envelope)
            notificationCenter.deliver(
                title: notification.title,
                body: notification.body,
                identifier: notification.identifier
            )
        }

        if channels.contains(.mainPicky) {
            try await deliverMainOnce(envelope)
        }
        return channels
    }

    private func deliverMainOnce(_ envelope: PickyCompletionNotificationEnvelope) async throws {
        let key = channelKey("main", completionId: envelope.completionId)
        guard !acceptedChannels.contains(key) else { return }

        let attempt: MainDeliveryAttempt
        if let inFlight = mainDeliveriesInFlight[key] {
            attempt = inFlight
        } else {
            let created = MainDeliveryAttempt(
                id: UUID(),
                task: Task { try await deliverMain(envelope) }
            )
            mainDeliveriesInFlight[key] = created
            attempt = created
        }

        do {
            try await attempt.task.value
            finishMainDelivery(key: key, attemptID: attempt.id, accepted: true)
        } catch {
            finishMainDelivery(key: key, attemptID: attempt.id, accepted: false)
            throw error
        }
    }

    private func finishMainDelivery(key: String, attemptID: UUID, accepted: Bool) {
        guard mainDeliveriesInFlight[key]?.id == attemptID else { return }
        if accepted {
            acceptedChannels.insert(key)
        }
        mainDeliveriesInFlight[key] = nil
    }

    private func accept(channel: String, completionId: String) -> Bool {
        acceptedChannels.insert(channelKey(channel, completionId: completionId)).inserted
    }

    private func channelKey(_ channel: String, completionId: String) -> String {
        "\(completionId):\(channel)"
    }
}
