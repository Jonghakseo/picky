//
//  PickyCompletionNotificationRoutingPolicy.swift
//  Picky
//
//  Pure routing policy for durable Pickle completion envelopes.
//

import Foundation

enum PickyCompletionNotificationRoutingPolicy {
    struct Channels: OptionSet, Equatable {
        let rawValue: Int

        static let mainPicky = Channels(rawValue: 1 << 0)
        static let macOS = Channels(rawValue: 1 << 1)
    }

    static func channels(
        bellEnabled: Bool,
        status: PickySessionStatus,
        destination: PickyCompletionNotificationDestination
    ) -> Channels {
        guard bellEnabled, status == .completed else { return [] }
        var result: Channels = []
        if destination.includesMain { result.insert(.mainPicky) }
        if destination.includesMacOS { result.insert(.macOS) }
        return result
    }

    static func macOSNotification(
        for envelope: PickyCompletionNotificationEnvelope,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> (title: String, body: String, identifier: String) {
        (
            title: localizer("notif.session.completed.title"),
            body: envelope.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? envelope.title,
            identifier: envelope.completionId
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
