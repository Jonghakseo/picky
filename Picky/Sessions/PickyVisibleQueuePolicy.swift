//
//  PickyVisibleQueuePolicy.swift
//  Picky
//
//  Shared queue visibility and restoration policy for the Journal and Composer.
//

import Foundation

/// The smallest user-message shape the composer needs for recall and queue
/// deduplication. It intentionally excludes agent text and thinking updates.
struct PickySubmittedUserMessage: Equatable {
    let text: String
    let createdAt: Date
}

/// The only journal-derived value the Composer observes. Equality guards in
/// `PickyConversationStore` keep agent streaming replacements from waking the
/// editor while preserving the user-message changes that affect its controls.
struct PickyComposerMessageContext: Equatable {
    let hasAnyMessage: Bool
    let submittedUserMessages: [PickySubmittedUserMessage]

    static let empty = Self(hasAnyMessage: false, submittedUserMessages: [])

    init(messages: [PickySessionMessage]) {
        hasAnyMessage = !messages.isEmpty
        submittedUserMessages = messages.compactMap { message in
            guard message.kind == .userText,
                  let text = message.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return PickySubmittedUserMessage(text: text, createdAt: message.createdAt)
        }
    }

    init(hasAnyMessage: Bool, submittedUserMessages: [PickySubmittedUserMessage]) {
        self.hasAnyMessage = hasAnyMessage
        self.submittedUserMessages = submittedUserMessages
    }
}

/// One normalized, chronological queue projection shared by Journal evidence,
/// Queue Dock counts, and draft restoration. Pi accepts a queued prompt before
/// it necessarily dequeues it, so a matching committed user message makes that
/// queued item stale rather than another visible/restorable instruction.
struct PickyVisibleQueue: Equatable {
    let steers: [PickyQueueItem]
    let followUps: [PickyQueueItem]

    init(
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem],
        committedUserMessages: [PickySubmittedUserMessage]
    ) {
        steers = Self.filter(queuedSteers, committedUserMessages: committedUserMessages)
        followUps = Self.filter(queuedFollowUps, committedUserMessages: committedUserMessages)
    }

    func items(for kind: PickyQueueClearKind) -> [PickyQueueItem] {
        let selected: [PickyQueueItem]
        switch kind {
        case .steering:
            selected = steers
        case .followUp:
            selected = followUps
        case .all:
            selected = steers + followUps
        }
        return selected.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    private static func filter(
        _ items: [PickyQueueItem],
        committedUserMessages: [PickySubmittedUserMessage]
    ) -> [PickyQueueItem] {
        items.filter { item in
            let queuedText = PickyQueuedInputText.normalized(item.text)
            guard !queuedText.isEmpty else { return false }
            return !committedUserMessages.contains { message in
                abs(message.createdAt.timeIntervalSince(item.enqueuedAt)) <= Self.committedTextMatchWindow
                    && PickyQueuedInputText.normalized(message.text) == queuedText
            }
        }
    }

    /// The five-minute acceptance window used by both Journal evidence and
    /// draft restoration. A queued prompt can remain in a snapshot after Pi
    /// has already committed its matching `user_text`.
    private static let committedTextMatchWindow: TimeInterval = 300
}

/// Extracts the user-facing portion of an agentd prompt envelope. This policy
/// is deliberately shared with restoration, so raw prompt/context envelopes can
/// never be inserted into a composer draft.
enum PickyQueuedInputText {
    private static let envelopes: [(parent: String, userSection: String)] = [
        ("# Picky steering message", "## User steering instruction"),
        ("# Picky follow-up", "## User follow-up"),
    ]

    static func displayText(from text: String) -> String {
        extractUserInstruction(from: text) ?? text
    }

    static func normalized(_ text: String) -> String {
        displayText(from: text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractUserInstruction(from text: String) -> String? {
        guard let envelope = envelopes.first(where: { text.contains($0.parent) }),
              let headingRange = text.range(of: envelope.userSection)
        else { return nil }

        let body = text[headingRange.upperBound...]
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var extracted: [Substring] = []
        var hasStarted = false

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !hasStarted && trimmedLine.isEmpty { continue }
            if hasStarted && trimmedLine.hasPrefix("## ") { break }
            hasStarted = true
            extracted.append(line)
        }

        let result = stripEnvelopeMetadataPrefix(from: extracted)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func stripEnvelopeMetadataPrefix(from lines: [Substring]) -> [Substring] {
        var result = lines
        guard let first = result.first,
              isEnvelopeMetadataLine(first.trimmingCharacters(in: .whitespaces))
        else { return result }

        result.removeFirst()
        if let separator = result.first,
           separator.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeFirst()
        }
        return result
    }

    private static func isEnvelopeMetadataLine(_ line: String) -> Bool {
        line.hasPrefix("- Source:")
    }
}
