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
            let queuedText = PickyQueuedInputText.normalized(item.userFacingText)
            guard !queuedText.isEmpty else { return false }
            // An item the daemon still lists under its own id is live: agentd drops
            // the entry the moment its user bubble is journaled. Hiding it by text
            // would erase a second identical message the user is still waiting on.
            guard item.id == nil else { return true }
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

/// Whitespace normalization for comparing a queued instruction against a
/// committed user bubble. Resolving the envelope is agentd's job (`displayText`
/// on the queue item), so this only removes formatting noise.
enum PickyQueuedInputText {
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
