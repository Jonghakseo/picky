//
//  PickySessionProjectionStoreTests.swift
//  PickyTests
//

import Foundation
import Observation
import Testing
@testable import Picky

@MainActor
struct PickySessionProjectionStoreTests {
    @Test func registryRetainsSessionAndMessageStoreIdentityAcrossReregistration() {
        let registry = PickySessionRegistry()
        let firstSession = registry.sessionStore(sessionID: "session-a")
        let secondSession = registry.sessionStore(sessionID: "session-a")
        let firstMessage = firstSession.conversationStore.messageStore(message: message(id: "message-a"))
        let secondMessage = secondSession.conversationStore.messageStore(id: "message-a")

        #expect(firstSession === secondSession)
        #expect(firstMessage === secondMessage)
        #expect(secondSession.conversationStore.orderedMessageIDs == ["message-a"])
    }

    @Test func unrelatedMessageChangesDoNotInvalidateAnotherSessionObservation() {
        let registry = PickySessionRegistry()
        let observed = registry.sessionStore(sessionID: "session-a")
        let unrelated = registry.sessionStore(sessionID: "session-b")
        let invalidations = ObservationInvalidationCounter()

        withObservationTracking {
            _ = observed.conversationStore.orderedMessageIDs
        } onChange: {
            invalidations.increment()
        }

        _ = unrelated.conversationStore.messageStore(message: message(id: "message-b"))

        #expect(invalidations.count == 0)
    }

    @Test func relatedMessageChangesInvalidateOrderedMessageObservation() {
        let registry = PickySessionRegistry()
        let session = registry.sessionStore(sessionID: "session-a")
        let invalidations = ObservationInvalidationCounter()

        withObservationTracking {
            _ = session.conversationStore.orderedMessageIDs
        } onChange: {
            invalidations.increment()
        }

        _ = session.conversationStore.messageStore(message: message(id: "message-a"))

        #expect(invalidations.count == 1)
    }

    @Test func stableMessageReplacementInvalidatesOnlyItsObservedLeafValue() {
        let registry = PickySessionRegistry()
        let observed = registry.sessionStore(sessionID: "session-a")
        let unrelated = registry.sessionStore(sessionID: "session-b")
        let observedMessage = observed.conversationStore.messageStore(message: message(id: "message-a", text: "Streaming"))
        let invalidations = ObservationInvalidationCounter()

        withObservationTracking {
            _ = observedMessage.messageState
        } onChange: {
            invalidations.increment()
        }

        _ = unrelated.conversationStore.messageStore(message: message(id: "message-b", text: "Unrelated stream"))
        #expect(invalidations.count == 0)

        _ = observed.conversationStore.messageStore(message: message(id: "message-a", text: "Stream complete"))

        #expect(invalidations.count == 1)
        #expect(observed.conversationStore.orderedMessageIDs == ["message-a"])
        #expect(observedMessage.messageState.loadedValue?.text == "Stream complete")
    }

    @Test func registryMaterializesCardFromLoadedChildrenAndClearsUnavailableSections() {
        let registry = PickySessionRegistry()
        let store = registry.sessionStore(sessionID: "session-a")
        let source = PickyProjectionReplayFixtures.bootstrapSession(
            id: "session-a",
            index: 1,
            status: .running,
            archived: false,
            messages: [],
            messageJournalAvailable: true
        )
        store.metaStore.replace(PickySessionMetadata(session: source, revision: 7))
        store.logStore.replace(["REQUEST: Build the projection"])
        store.conversationStore.replaceMessages([message(id: "message-a", text: "Loaded reply")])
        store.conversationStore.replaceMessageJournalAvailability(true)

        let loadedCard = store.materializedSessionCard()
        #expect(loadedCard?.id == "session-a")
        #expect(loadedCard?.messages.map(\.text) == ["Loaded reply"])
        guard case .loaded(let metadata) = store.metaStore.metadataState else {
            Issue.record("Expected loaded metadata")
            return
        }
        #expect(metadata.revision == 7)
        #expect(store.conversationStore.messageJournalAvailabilityState == .loaded(true))

        store.conversationStore.markMessagesUnavailable()

        #expect(store.materializedSessionCard()?.messages.isEmpty == true)
        #expect(store.conversationStore.messageJournalAvailabilityState == .unavailable)
    }

    @Test func unavailableSectionsClearPreviousValuesInsteadOfRetainingStaleProjection() {
        let session = PickySessionStore(sessionID: "session-a")
        let messageStore = session.conversationStore.messageStore(message: message(id: "message-a"))

        session.conversationStore.markMessagesUnavailable()

        #expect(session.conversationStore.orderedMessageIDs.isEmpty)
        #expect(session.conversationStore.messagesState == .unavailable)
        #expect(messageStore.messageState == .unavailable)
    }

    private func message(id: String, text: String? = nil) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: .agentText,
            createdAt: PickyProjectionReplayFixtures.terminalDate,
            originatedBy: .mainAgent,
            text: text ?? "Message \(id)",
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil
        )
    }
}

private final class ObservationInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private extension PickyProjectionSectionState where Value == PickySessionMessage {
    var loadedValue: PickySessionMessage? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
