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
//  The list pins the window it showed when the Pickle opened (see
//  `pinnedAnchorID`), so the base window only trims history on the next open.
//  Trimming while the card is open moved every turn up the moment a new
//  request crossed the base-window limit.
//

import Foundation

enum PickyConversationHistoryWindowPolicy {
    /// How many of the newest user turns a freshly opened card renders. The
    /// daemon no longer trims the journal for the app: a projection snapshot
    /// carries the whole message list, so this window is purely a render
    /// decision and "Load more" walks backwards through what already arrived.
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

    /// Anchor that keeps the currently shown window in place while the Pickle
    /// stays open. A valid anchor (a `userText` still present in `messages`) is
    /// kept; otherwise it pins to the oldest user turn of the default window,
    /// which is exactly what is rendered right now, so pinning never moves rows.
    /// Returns nil only when there is no `userText` to pin to yet.
    static func pinnedAnchorID(
        messages: [PickySessionMessage],
        currentAnchorID: String?
    ) -> String? {
        if let currentAnchorID,
           messages.contains(where: { $0.id == currentAnchorID && $0.kind == .userText }) {
            return currentAnchorID
        }
        let userIndices = messages.indices.filter { messages[$0].kind == .userText }
        guard let start = userIndices.suffix(baseTurnCount).first else { return nil }
        return messages[start].id
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
