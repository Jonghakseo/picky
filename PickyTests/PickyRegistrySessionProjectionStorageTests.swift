//
//  PickyRegistrySessionProjectionStorageTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickyRegistrySessionProjectionStorageTests {
    @Test func everySemanticOperationPublishesOneFinalSnapshotWithItsHistoricalPresentationSteps() {
        let storage = PickyRegistrySessionProjectionStorage()
        let first = card(id: "first", index: 1)
        let second = card(id: "second", index: 2)
        var publications: [PickySessionProjectionStoragePublication] = []
        let cancellable = storage.changes.sink { publications.append($0) }

        storage.replaceAllSessions(active: [first], archived: [])
        assertLatestPublication(publications, steps: ["active", "archived"])

        storage.upsertSession(second, archived: false)
        assertLatestPublication(publications, steps: ["active", "archived", "active", "archived"])

        _ = storage.archiveSession(id: first.id)
        assertLatestPublication(publications, steps: ["active", "archived", "archived"])

        _ = storage.unarchiveSession(id: first.id)
        assertLatestPublication(publications, steps: ["archived", "active"])

        _ = storage.mutateSession(sessionID: second.id) { $0.title = "Updated" }
        assertLatestPublication(publications, steps: ["active"])

        storage.applyManualOrder([first.id, second.id])
        assertLatestPublication(publications, steps: ["active"])

        storage.removeSession(id: first.id)
        assertLatestPublication(publications, steps: ["active", "archived"])

        #expect(publications.count == 7)
        #expect(publications.last?.finalSnapshot.activeSessions.map(\.id) == [second.id])
        withExtendedLifetime(cancellable) {}
    }

    @Test func registryOwnsEffectiveArchiveMembership() {
        let storage = PickyRegistrySessionProjectionStorage()
        let card = card(id: "archive-me", index: 1)

        storage.replaceAllSessions(active: [card], archived: [])
        #expect(storage.activeSessions.map(\.id) == [card.id])
        #expect(storage.archivedSessions.isEmpty)
        #expect(storage.registry.activeSessionIDs == [card.id])

        #expect(storage.archiveSession(id: card.id)?.id == card.id)
        #expect(storage.activeSessions.isEmpty)
        #expect(storage.archivedSessions.map(\.id) == [card.id])
        #expect(storage.registry.archivedSessionIDs == [card.id])

        #expect(storage.unarchiveSession(id: card.id)?.id == card.id)
        #expect(storage.activeSessions.map(\.id) == [card.id])
        #expect(storage.archivedSessions.isEmpty)
        #expect(storage.registry.activeSessionIDs == [card.id])
    }

    @Test func emptyQueueRetainsNonDefaultModesAfterReplaceAllSessions() {
        let storage = PickyRegistrySessionProjectionStorage()
        var emptyQueueCard = card(id: "empty-queue-modes", index: 1)
        emptyQueueCard.steeringMode = .all
        emptyQueueCard.followUpMode = .all

        storage.replaceAllSessions(active: [emptyQueueCard], archived: [])

        #expect(storage.registry.sessionStore(sessionID: emptyQueueCard.id).queueStore.queueState == .unavailable)
        #expect(storage.activeSessions.first?.queuedSteers.isEmpty == true)
        #expect(storage.activeSessions.first?.queuedFollowUps.isEmpty == true)
        #expect(storage.activeSessions.first?.steeringMode == .all)
        #expect(storage.activeSessions.first?.followUpMode == .all)
    }

    @Test func snapshotOmissionClearsPreviouslyHydratedChildSections() {
        let storage = PickyRegistrySessionProjectionStorage()
        var hydrated = card(id: "hydration", index: 1)
        hydrated.messages = [PickyProjectionReplayFixtures.terminalMessage(id: "reply", kind: .agentText, text: "Loaded")]

        storage.replaceAllSessions(active: [hydrated], archived: [])
        #expect(storage.registry.sessionStore(sessionID: hydrated.id).conversationStore.messagesState.isLoaded)

        var summary = hydrated
        summary.messages = []
        storage.replaceAllSessions(active: [summary], archived: [])

        let conversation = storage.registry.sessionStore(sessionID: hydrated.id).conversationStore
        #expect(conversation.messagesState == .unavailable)
        #expect(storage.activeSessions.first?.messages.isEmpty == true)
    }

    private func assertLatestPublication(
        _ publications: [PickySessionProjectionStoragePublication],
        steps: [String]
    ) {
        #expect(publications.last?.steps.map { step in
            step.changesActiveSessions ? "active" : "archived"
        } == steps)
    }

    private func card(id: String, index: Int) -> PickySessionListViewModel.SessionCard {
        .fromAgentSession(PickyProjectionReplayFixtures.bootstrapSession(
            id: id,
            index: index,
            status: .running,
            archived: false,
            messages: [],
            messageJournalAvailable: true
        ))
    }

}

private extension PickyProjectionSectionState {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
