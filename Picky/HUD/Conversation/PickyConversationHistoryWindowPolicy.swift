//
//  PickyConversationHistoryWindowPolicy.swift
//  Picky
//
//  Pure policy for how much conversation history the Pickle card renders.
//  The card shows the last `baseTurnCount` user turns by default; the
//  "load earlier turns" pill expands the window backwards `loadMoreTurnStep`
//  user turns at a time by pinning an absolute anchor (the oldest visible
//  `userText` message id). Because the anchor is an absolute message id,
//  newly streamed turns never push already-expanded history back out of view.
//

import Foundation

enum PickyConversationHistoryWindowPolicy {
    /// Keep in sync with `SNAPSHOT_VISIBLE_USER_TURN_COUNT` in agentd/src/server.ts:
    /// the initial sessionSnapshot trims messages to this same window so the first
    /// full sessionUpdated arrives without a visible layout shift.
    static let baseTurnCount = 10
    static let loadMoreTurnStep = 10

    /// Index of the first message to render, or nil when every message is visible
    /// (fewer user turns than the base window, or no `userText` at all).
    /// An anchor that no longer resolves to a `userText` message in `messages`
    /// (session switch, compaction rewrite) safely falls back to the base window.
    static func visibleStartIndex(
        messages: [PickySessionMessage],
        expandedAnchorID: String?
    ) -> Int? {
        let userIndices = messages.indices.filter { messages[$0].kind == .userText }
        guard userIndices.count > baseTurnCount,
              let baseStart = userIndices.suffix(baseTurnCount).first
        else { return nil }
        guard let anchorID = expandedAnchorID,
              let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }),
              messages[anchorIndex].kind == .userText,
              anchorIndex < baseStart
        else { return baseStart }
        return anchorIndex == userIndices.first ? nil : anchorIndex
    }

    /// Number of user turns hidden above the current window. Drives the
    /// "load earlier turns" pill visibility and its count label.
    static func hiddenTurnCount(
        messages: [PickySessionMessage],
        expandedAnchorID: String?
    ) -> Int {
        guard let start = visibleStartIndex(messages: messages, expandedAnchorID: expandedAnchorID) else {
            return 0
        }
        return messages[..<start].filter { $0.kind == .userText }.count
    }

    /// Anchor id after expanding the window one step further into the past.
    /// Returns the existing anchor unchanged when nothing is hidden.
    static func anchorIDAfterLoadingMore(
        messages: [PickySessionMessage],
        expandedAnchorID: String?
    ) -> String? {
        guard let start = visibleStartIndex(messages: messages, expandedAnchorID: expandedAnchorID) else {
            return expandedAnchorID
        }
        let earlierUserIndices = messages[..<start].indices.filter { messages[$0].kind == .userText }
        guard let newStart = earlierUserIndices.suffix(loadMoreTurnStep).first else {
            return expandedAnchorID
        }
        return messages[newStart].id
    }
}
