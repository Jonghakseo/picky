//
//  PickyConversationStore.swift
//  Picky
//

import Observation

/// Session-scoped owner for message membership and journal availability.
@MainActor
@Observable
final class PickyConversationStore {
    @ObservationIgnored private var messagesByID: [String: PickyMessageStore] = [:]
    /// O(1) membership for `orderedMessageIDs`. `messagesByID` cannot serve this
    /// role: `messageStore(id:)` vends a leaf for a message that has not joined
    /// the ordered journal yet.
    @ObservationIgnored private var orderedMessageIDSet: Set<String> = []
    @ObservationIgnored private var state: PickyProjectionSectionState<[PickySessionMessage]> = .unavailable
    @ObservationIgnored private var messageJournalAvailability: PickyProjectionSectionState<Bool?> = .unavailable
    private(set) var orderedMessageIDs: [String] = []
    /// Composer-specific journal projection. This is assigned only when its
    /// small Equatable value changes, so agent streaming stays local to leaves.
    private(set) var composerMessageContext = PickyComposerMessageContext.empty
    private(set) var valueRevision = 0

    var messagesState: PickyProjectionSectionState<[PickySessionMessage]> {
        _ = valueRevision
        return state
    }

    var messageJournalAvailabilityState: PickyProjectionSectionState<Bool?> {
        _ = valueRevision
        return messageJournalAvailability
    }

    @discardableResult
    func messageStore(message: PickySessionMessage) -> PickyMessageStore {
        let store = upsert(message)
        republishMembership()
        return store
    }

    /// Batch equivalent of upserting each message in order. Membership is
    /// republished once for the whole batch, so hydrating a long journal costs
    /// one invalidation and one array build instead of one per message.
    func importMessages(_ messages: [PickySessionMessage]) {
        guard !messages.isEmpty else { return }
        for message in messages { _ = upsert(message) }
        republishMembership()
    }

    func messageStore(id: String) -> PickyMessageStore {
        if let existing = messagesByID[id] { return existing }
        let store = PickyMessageStore(messageID: id)
        messagesByID[id] = store
        return store
    }

    func replaceMessages(_ messages: [PickySessionMessage]) {
        let incomingIDs = messages.map(\.id)
        for message in messages { _ = upsert(message) }
        let retainedIDs = Set(incomingIDs)
        orderedMessageIDs = incomingIDs
        orderedMessageIDSet = retainedIDs
        messagesByID = messagesByID.filter { retainedIDs.contains($0.key) }
        state = .loaded(messages)
        updateComposerMessageContext(messages)
        valueRevision += 1
    }

    func replaceMessageJournalAvailability(_ available: Bool?) {
        messageJournalAvailability = .loaded(available)
        valueRevision += 1
    }

    func removeMessage(id: String) {
        messagesByID[id]?.markUnavailable()
        messagesByID.removeValue(forKey: id)
        orderedMessageIDs.removeAll { $0 == id }
        orderedMessageIDSet.remove(id)
        republishMembership()
    }

    func markMessageJournalAvailabilityUnavailable() {
        messageJournalAvailability = .unavailable
        valueRevision += 1
    }

    func markMessagesUnavailable() {
        for store in messagesByID.values {
            store.markUnavailable()
        }
        orderedMessageIDs = []
        orderedMessageIDSet = []
        messagesByID = [:]
        state = .unavailable
        messageJournalAvailability = .unavailable
        updateComposerMessageContext([])
        valueRevision += 1
    }

    private func upsert(_ message: PickySessionMessage) -> PickyMessageStore {
        let store = messageStore(id: message.id)
        store.replace(message)
        if orderedMessageIDSet.insert(message.id).inserted {
            orderedMessageIDs.append(message.id)
        }
        return store
    }

    private func republishMembership() {
        let messages = orderedMessageIDs.compactMap { messagesByID[$0]?.messageState.loadedValue }
        state = .loaded(messages)
        updateComposerMessageContext(messages)
        valueRevision += 1
    }

    private func updateComposerMessageContext(_ messages: [PickySessionMessage]) {
        let nextContext = PickyComposerMessageContext(messages: messages)
        guard composerMessageContext != nextContext else { return }
        composerMessageContext = nextContext
    }
}

/// Manifest name for the session-scoped message owner. `PickyMessageStore`
/// remains the stable leaf identity for each individual message.
typealias PickySessionMessageStore = PickyConversationStore

private extension PickyProjectionSectionState where Value == PickySessionMessage {
    var loadedValue: PickySessionMessage? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
