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
    @ObservationIgnored private var state: PickyProjectionSectionState<[PickySessionMessage]> = .unavailable
    @ObservationIgnored private var messageJournalAvailability: PickyProjectionSectionState<Bool?> = .unavailable
    private(set) var orderedMessageIDs: [String] = []
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
        let store = messageStore(id: message.id)
        store.replace(message)
        if !orderedMessageIDs.contains(message.id) {
            orderedMessageIDs.append(message.id)
        }
        state = .loaded(orderedMessageIDs.compactMap { messagesByID[$0]?.messageState.loadedValue })
        valueRevision += 1
        return store
    }

    func messageStore(id: String) -> PickyMessageStore {
        if let existing = messagesByID[id] { return existing }
        let store = PickyMessageStore(messageID: id)
        messagesByID[id] = store
        return store
    }

    func replaceMessages(_ messages: [PickySessionMessage]) {
        let incomingIDs = messages.map(\.id)
        for message in messages {
            _ = messageStore(message: message)
        }
        orderedMessageIDs = incomingIDs
        messagesByID = messagesByID.filter { incomingIDs.contains($0.key) }
        state = .loaded(messages)
        valueRevision += 1
    }

    func replaceMessageJournalAvailability(_ available: Bool?) {
        messageJournalAvailability = .loaded(available)
        valueRevision += 1
    }

    func markMessagesUnavailable() {
        for store in messagesByID.values {
            store.markUnavailable()
        }
        orderedMessageIDs = []
        messagesByID = [:]
        state = .unavailable
        messageJournalAvailability = .unavailable
        valueRevision += 1
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
