//
//  PickyRegistrySessionProjectionStorageTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickyRegistrySessionProjectionStorageTests {
    @Test func registryBackendMatchesLegacyForBootstrapHydrationAndTerminalReplay() {
        let legacy = PickyProjectionReplayFixtures.makeViewModel(
            selectedSessionID: "bootstrap-001",
            sessionProjectionStorage: PickyLegacySessionProjectionStorage()
        )
        let registry = PickyProjectionReplayFixtures.makeViewModel(
            selectedSessionID: "bootstrap-001",
            sessionProjectionStorage: PickyRegistrySessionProjectionStorage()
        )

        applyBootstrapHydration(to: legacy)
        applyBootstrapHydration(to: registry)
        let nonDefaultSession = nonDefaultSession()
        let nonDefaultEnvelope = PickyProjectionReplayFixtures.bootstrapEnvelope(
            id: "non-default-session",
            event: .sessionUpdated(nonDefaultSession)
        )
        PickyProjectionReplayFixtures.apply(nonDefaultEnvelope, to: legacy)
        PickyProjectionReplayFixtures.apply(nonDefaultEnvelope, to: registry)
        for event in PickyProjectionReplayFixtures.terminalReplayEvents() {
            PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.terminalEnvelope(event), to: legacy)
            PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.terminalEnvelope(event), to: registry)
        }

        // SessionCard is Equatable, so this compares every HUD-facing field,
        // including conversation, queue, artifact, and local presentation state.
        #expect(registry.sessions == legacy.sessions)
        #expect(registry.archivedSessions == legacy.archivedSessions)
        #expect(registry.selectedSessionID == legacy.selectedSessionID)
    }

    @Test func everySemanticOperationRelaysOneFinalSnapshot() {
        let storage = PickyRegistrySessionProjectionStorage()
        let first = card(id: "first", index: 1)
        let second = card(id: "second", index: 2)
        var changes: [PickySessionProjectionStorageSnapshot] = []
        let cancellable = storage.changes.sink { changes.append($0) }

        storage.replaceAllSessions(active: [first], archived: [])
        storage.upsertSession(second, archived: false)
        _ = storage.archiveSession(id: first.id)
        _ = storage.unarchiveSession(id: first.id)
        _ = storage.mutateSession(sessionID: second.id) { $0.title = "Updated" }
        storage.applyManualOrder([first.id, second.id])
        storage.removeSession(id: first.id)

        #expect(changes.count == 7)
        #expect(changes.last?.activeSessions.map(\.id) == [second.id])
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

    private func applyBootstrapHydration(to viewModel: PickySessionListViewModel) {
        PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.bootstrapSnapshotEvent(), to: viewModel)
        for session in PickyProjectionReplayFixtures.hydratedBootstrapSessions() {
            PickyProjectionReplayFixtures.apply(
                PickyProjectionReplayFixtures.bootstrapEnvelope(id: "hydration-\(session.id)", event: .sessionUpdated(session)),
                to: viewModel
            )
        }
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

    /// Deliberately exercises scalar fields that empty child collections cannot
    /// stand in for. The full SessionCard Equatable comparison above verifies
    /// this v1 update round-trips identically through both storage backends.
    private func nonDefaultSession() -> PickyAgentSession {
        var session = PickyProjectionReplayFixtures.bootstrapSession(
            id: "non-default-session",
            index: 95,
            status: .running,
            archived: false,
            messages: [],
            messageJournalAvailable: true
        )
        session.queuedSteers = []
        session.queuedFollowUps = []
        session.steeringMode = .all
        session.followUpMode = .all
        session.pinned = true
        session.notifyMainOnCompletion = true
        session.changedFiles = [PickyChangedFile(path: "Picky/Projection.swift", status: "modified", summary: "Preserve projection state")]
        session.todoState = PickyTodoState(
            tasks: [PickyTodoTask(id: "projection-task", content: "Preserve scalar fields", status: .inProgress)],
            updatedAt: PickyProjectionReplayFixtures.terminalDate
        )
        session.contextUsage = PickyContextUsage(tokens: 42_000, contextWindow: 200_000, percent: 21)
        session.currentAssistantRun = PickyAssistantRunMetadata(model: "anthropic/claude-opus-4-7", thinkingLevel: .high)
        return session
    }
}

private extension PickyProjectionSectionState {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
