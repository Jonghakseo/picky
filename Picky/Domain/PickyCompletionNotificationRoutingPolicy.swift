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
        notifyMainOnCompletion: Bool,
        notifyMacOSOnCompletion: Bool,
        status: PickySessionStatus
    ) -> Channels {
        guard status == .completed else { return [] }
        var result: Channels = []
        if notifyMainOnCompletion { result.insert(.mainPicky) }
        if notifyMacOSOnCompletion { result.insert(.macOS) }
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
