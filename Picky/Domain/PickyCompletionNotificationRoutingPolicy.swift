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
            body: plainText(envelope.summary ?? "").nonEmpty ?? plainText(envelope.title),
            identifier: envelope.completionId
        )
    }

    private static func plainText(_ markdown: String) -> String {
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Foundation removes block separators; restore them without splitting inline emphasis.
        var text = ""
        var previousIntent: PresentationIntent?
        for run in parsed.runs {
            if run.presentationIntent?.components.contains(where: { $0.kind == .thematicBreak }) == true {
                continue
            }
            if !text.isEmpty, run.presentationIntent != previousIntent {
                text += "\n"
            }
            text += String(parsed[run.range].characters)
            previousIntent = run.presentationIntent
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
