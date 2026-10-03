//
//  PickyRegistrySessionProjectionStorageTests.swift
//  PickyTests
//

import Combine
import Foundation
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

    @Test func batchRemovalPublishesOnceAndPreservesSurvivingStoreIdentity() {
        let storage = PickyRegistrySessionProjectionStorage()
        let first = card(id: "first", index: 1)
        let survivor = card(id: "survivor", index: 2)
        let archived = card(id: "archived", index: 3)
        var publications: [PickySessionProjectionStoragePublication] = []
        let cancellable = storage.changes.sink { publications.append($0) }

        storage.replaceAllSessions(active: [first, survivor], archived: [archived])
        let survivorStore = storage.registry.sessionStore(sessionID: survivor.id)
        storage.removeSessions(ids: [first.id, archived.id])

        #expect(storage.registry.activeSessionIDs == [survivor.id])
        #expect(storage.registry.archivedSessionIDs.isEmpty)
        #expect(storage.registry.sessionStore(sessionID: survivor.id) === survivorStore)
        #expect(publications.count == 2)
        #expect(publications.last?.steps.count == 1)
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

    @Test func mutatingOneSessionKeepsOtherSessionsProjectionOnlyMetadata() {
        let storage = PickyRegistrySessionProjectionStorage()
        storage.applyProjectionSnapshot(
            projectionSnapshot(sessionID: "mutated", revision: 4, status: .running),
            archived: false
        )
        storage.applyProjectionSnapshot(
            projectionSnapshot(
                sessionID: "bystander",
                revision: 9,
                status: .completed,
                finalAnswer: "Bystander finished the investigation.",
                archivedAt: "2026-08-25T00:00:05.000Z"
            ),
            archived: true
        )

        _ = storage.mutateSession(sessionID: "mutated") { $0.title = "Updated" }

        let bystander = storage.registry.sessionStore(sessionID: "bystander")
        #expect(bystander.materializedAgentSessionSummary()?.finalAnswer == "Bystander finished the investigation.")
        #expect(bystander.materializedAgentSessionSummary()?.archivedAt == Date(timeIntervalSince1970: 1_787_616_005))
        #expect(bystander.metaStore.metadataState.loadedMetadata?.revision == 9)
        #expect(storage.activeSessions.first?.title == "Updated")
    }

    @Test func mutatingArchivedSessionKeepsOtherSessionsProjectionOnlyMetadata() {
        let storage = PickyRegistrySessionProjectionStorage()
        storage.applyProjectionSnapshot(
            projectionSnapshot(
                sessionID: "archived-mutated",
                revision: 3,
                status: .completed,
                archivedAt: "2026-08-25T00:00:09.000Z"
            ),
            archived: true
        )
        storage.applyProjectionSnapshot(
            projectionSnapshot(
                sessionID: "bystander",
                revision: 11,
                status: .running,
                finalAnswer: "Bystander answer"
            ),
            archived: false
        )

        _ = storage.mutateArchivedSession(sessionID: "archived-mutated") { $0.title = "Updated" }

        let bystander = storage.registry.sessionStore(sessionID: "bystander")
        #expect(bystander.materializedAgentSessionSummary()?.finalAnswer == "Bystander answer")
        #expect(bystander.metaStore.metadataState.loadedMetadata?.revision == 11)
        #expect(storage.archivedSessions.first?.title == "Updated")
    }

    @Test func mutatingSessionKeepsItsOwnProjectionOnlyMetadata() {
        let storage = PickyRegistrySessionProjectionStorage()
        storage.applyProjectionSnapshot(
            projectionSnapshot(
                sessionID: "mutated",
                revision: 6,
                status: .completed,
                finalAnswer: "Already answered"
            ),
            archived: false
        )

        _ = storage.mutateSession(sessionID: "mutated") { $0.logPreview = "bash: done" }

        let store = storage.registry.sessionStore(sessionID: "mutated")
        #expect(store.materializedAgentSessionSummary()?.finalAnswer == "Already answered")
        #expect(store.metaStore.metadataState.loadedMetadata?.revision == 6)
        #expect(storage.activeSessions.first?.logPreview == "bash: done")
    }

    private func projectionSnapshot(
        sessionID: String,
        revision: Int,
        status: PickySessionStatus,
        finalAnswer: String? = nil,
        archivedAt: String? = nil
    ) -> PickySessionProjectionSnapshot {
        let encodedFinalAnswer = finalAnswer.map { ",\"finalAnswer\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        let encodedArchivedAt = archivedAt.map { ",\"archivedAt\":\"\($0)\"" } ?? ""
        let json = """
        {"sessionId":"\(sessionID)","epoch":"epoch-1","revision":\(revision),"complete":true,"omittedFields":[],
         "projection":{"id":"\(sessionID)","title":"\(sessionID)","status":"\(status.rawValue)","createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:00:01.000Z"\(encodedFinalAnswer)\(encodedArchivedAt)}}
        """
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
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

private extension PickyProjectionSectionState where Value == PickySessionMetadata {
    var loadedMetadata: PickySessionMetadata? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
