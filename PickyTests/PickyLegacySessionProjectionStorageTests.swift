//
//  PickyLegacySessionProjectionStorageTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickyLegacySessionProjectionStorageTests {
    @Test func semanticOperationsRelayExactlyOnceAndMaintainSnapshots() {
        let storage = PickyLegacySessionProjectionStorage()
        let first = card(id: "first", index: 1)
        let second = card(id: "second", index: 2)
        var changes: [PickySessionProjectionStorageSnapshot] = []
        let cancellable = storage.changes.sink { changes.append($0) }

        storage.replaceAllSessions(active: [first], archived: [])
        #expect(changes.count == 1)
        #expect(storage.activeSessions.map(\.id) == ["first"])

        storage.upsertSession(second, archived: false)
        #expect(changes.count == 2)
        #expect(storage.activeSessions.map(\.id) == ["first", "second"])

        #expect(storage.archiveSession(id: "first")?.id == "first")
        #expect(changes.count == 3)
        #expect(storage.activeSessions.map(\.id) == ["second"])
        #expect(storage.archivedSessions.map(\.id) == ["first"])

        #expect(storage.unarchiveSession(id: "first")?.id == "first")
        #expect(changes.count == 4)
        #expect(storage.activeSessions.map(\.id) == ["second", "first"])

        #expect(storage.mutateSession(sessionID: "second") { $0.title = "Updated" }?.title == "Updated")
        #expect(changes.count == 5)
        #expect(storage.session(id: "second")?.title == "Updated")

        storage.applyManualOrder(["first", "second"])
        #expect(changes.count == 6)
        #expect(storage.activeSessions.map(\.id) == ["first", "second"])

        storage.removeSession(id: "first")
        #expect(changes.count == 7)
        #expect(storage.session(id: "first") == nil)
        withExtendedLifetime(cancellable) {}
    }

    @Test func archivedMutationRelaysOnceAndRetainsArchivedOrdering() {
        let storage = PickyLegacySessionProjectionStorage()
        let earlier = card(id: "earlier", index: 1)
        let later = card(id: "later", index: 2)
        var relayCount = 0
        let cancellable = storage.changes.sink { _ in relayCount += 1 }

        storage.replaceAllSessions(active: [], archived: [earlier, later])
        #expect(storage.mutateArchivedSession(sessionID: "earlier") { $0.lastSummary = "Changed" }?.lastSummary == "Changed")

        #expect(relayCount == 2)
        #expect(storage.archivedSessions.map(\.id) == ["later", "earlier"])
        withExtendedLifetime(cancellable) {}
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
