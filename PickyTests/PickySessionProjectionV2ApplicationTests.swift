//
//  PickySessionProjectionV2ApplicationTests.swift
//  PickyTests
//

import Combine
import Foundation
import Observation
import Testing
@testable import Picky

@MainActor
struct PickySessionProjectionV2ApplicationTests {
    @Test func bootstrapSnapshotsInstallCardsWithoutHistoricalAttentionEffects() throws {
        let notifications = PickyNoopNotificationCenter()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(
            notificationCenter: notifications,
            sessionProjectionStorage: storage
        )

        apply(snapshot(sessionID: "session-a", title: "Historical completion", status: .completed, revision: 4), to: viewModel)
        apply(snapshot(sessionID: "session-b", title: "Running work", status: .running, revision: 7), to: viewModel)

        #expect(Set(viewModel.sessions.map(\.id)) == ["session-a", "session-b"])
        #expect(storage.registry.sessionStore(sessionID: "session-a").metaStore.metadataState.loadedValue?.revision == 4)
        #expect(notifications.delivered.isEmpty)
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
        #expect(viewModel.unreadSessionIDs.isEmpty)
    }

    @Test func acceptedPrimaryBootstrapCompletionPrunesOnlyExplicitlyRemovedMembershipAndUnblocksLoading() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let archiveStore = V2ArchiveStore()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage, archiveStore: archiveStore)
        apply(snapshot(sessionID: "keep", title: "Keep", status: .running, revision: 1), to: viewModel)
        apply(snapshot(sessionID: "stale", title: "Stale", status: .completed, revision: 1), to: viewModel)
        viewModel.archive(sessionID: "stale")
        #expect(storage.session(id: "stale") != nil)

        viewModel.applySessionProjectionBootstrapCompletion(removedSessionIDs: ["stale"], isPrimary: true)

        #expect(storage.session(id: "keep") != nil)
        #expect(storage.session(id: "stale") == nil)
        #expect(!archiveStore.manuallyArchivedSessionIDs.contains("stale"))
        #expect(!viewModel.isLoadingInitialSessionSnapshot)
    }

    @Test func authoritativeBootstrapRemovalPublishesMonotonicHUDRemovalEvent() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage)
        apply(snapshot(sessionID: "removed", title: "Removed", status: .running, revision: 1), to: viewModel)
        apply(snapshot(sessionID: "next", title: "Next", status: .running, revision: 1), to: viewModel)

        viewModel.applySessionProjectionBootstrapCompletion(removedSessionIDs: ["removed"], isPrimary: true)
        viewModel.flushDockStateForTesting()
        let first = try #require(viewModel.dockState.snapshot.authoritativeRemovalEvent)
        #expect(first.sessionIDs == ["removed"])

        viewModel.applySessionProjectionBootstrapCompletion(removedSessionIDs: ["next"], isPrimary: true)
        viewModel.flushDockStateForTesting()
        let second = try #require(viewModel.dockState.snapshot.authoritativeRemovalEvent)
        #expect(second.revision > first.revision)
        #expect(second.sessionIDs == ["next"])
    }

    @Test func childBootstrapCompletionDoesNotUnblockPrimaryLoading() {
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: PickyRegistrySessionProjectionStorage())
        viewModel.isLoadingInitialSessionSnapshot = true

        viewModel.applySessionProjectionBootstrapCompletion(removedSessionIDs: [], isPrimary: false)

        #expect(viewModel.isLoadingInitialSessionSnapshot)
    }

    @Test func onlyPrimaryProjectionSnapshotUnblocksInitialLoading() {
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: PickyRegistrySessionProjectionStorage())
        viewModel.isLoadingInitialSessionSnapshot = true

        viewModel.handleSessionProjectionSnapshotReceived(isPrimary: false)
        #expect(viewModel.isLoadingInitialSessionSnapshot)

        viewModel.handleSessionProjectionSnapshotReceived(isPrimary: true)
        #expect(!viewModel.isLoadingInitialSessionSnapshot)
    }

    @Test func sequentialV2BootstrapPreservesPersistedGroupMembersNotYetProjected() throws {
        let dockLayoutStore = V2DockLayoutStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(
                id: "existing-group",
                name: "Existing",
                color: .blue,
                memberSessionIDs: ["session-a", "session-b"]
            ))
        ]))
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: PickyRegistrySessionProjectionStorage(),
            dockLayoutStore: dockLayoutStore
        )

        apply(snapshot(sessionID: "session-a", title: "A", status: .running, revision: 1), to: viewModel)
        apply(snapshot(sessionID: "session-b", title: "B", status: .running, revision: 1), to: viewModel)

        #expect(viewModel.dockLayout.group(withID: "existing-group")?.memberSessionIDs == ["session-a", "session-b"])
        #expect(viewModel.dockLayout.container(forSessionID: "session-a") == .group(id: "existing-group", memberIndex: 0))
        #expect(viewModel.dockLayout.container(forSessionID: "session-b") == .group(id: "existing-group", memberIndex: 1))
    }

    @Test func pendingExactGroupAssignmentDrainsWhenV2BootstrapAdmitsSession() throws {
        let dockLayoutStore = V2DockLayoutStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "target-group", name: "Target", color: .teal, memberSessionIDs: []))
        ]))
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: PickyRegistrySessionProjectionStorage(),
            dockLayoutStore: dockLayoutStore
        )

        viewModel.assignSessionToDockGroup(sessionID: "new-pickle", groupID: "target-group")
        apply(snapshot(sessionID: "new-pickle", title: "New Pickle", status: .running, revision: 1), to: viewModel)

        #expect(viewModel.dockLayout.group(withID: "target-group")?.memberSessionIDs == ["new-pickle"])
        #expect(viewModel.dockLayout.container(forSessionID: "new-pickle") == .group(id: "target-group", memberIndex: 0))
        #expect(dockLayoutStore.savedLayouts.last == viewModel.dockLayout)
    }

    @Test func v2BootstrapAdmitsSessionBeforeExactGroupAssignment() throws {
        let dockLayoutStore = V2DockLayoutStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "target-group", name: "Target", color: .teal, memberSessionIDs: []))
        ]))
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: PickyRegistrySessionProjectionStorage(),
            dockLayoutStore: dockLayoutStore
        )

        apply(snapshot(sessionID: "new-pickle", title: "New Pickle", status: .running, revision: 1), to: viewModel)

        #expect(viewModel.dockLayout.allKnownSessionIDs.contains("new-pickle"))
        #expect(dockLayoutStore.savedLayouts.last == viewModel.dockLayout)

        viewModel.assignSessionToDockGroup(sessionID: "new-pickle", groupID: "target-group")

        #expect(viewModel.dockLayout.group(withID: "target-group")?.memberSessionIDs == ["new-pickle"])
        #expect(viewModel.dockLayout.container(forSessionID: "new-pickle") == .group(id: "target-group", memberIndex: 0))
        #expect(dockLayoutStore.savedLayouts.last == viewModel.dockLayout)
    }

    @Test func archiveTransactionRemovesSessionFromDockWithoutWaitingForAnotherActivePublication() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        apply(snapshot(sessionID: "session-a", title: "A", status: .completed, revision: 1), to: viewModel)
        apply(snapshot(sessionID: "session-b", title: "B", status: .running, revision: 1), to: viewModel)
        viewModel.flushDockStateForTesting()

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: #"[{"type":"metaPatch","patch":{"archived":true,"archivedAt":"2026-08-25T00:00:02.000Z"}}]"#
        ), to: viewModel)
        viewModel.flushDockStateForTesting()

        #expect(storage.registry.activeSessionIDs == ["session-b"])
        #expect(storage.registry.archivedSessionIDs == ["session-a"])
        #expect(viewModel.sessions.map(\.id) == ["session-b"])
        #expect(viewModel.archivedSessions.map(\.id) == ["session-a"])
        #expect(viewModel.dockState.snapshot.activeSessions.map(\.id) == ["session-b"])
    }

    @Test func unarchiveTransactionUpdatesBothActiveAndArchivedFacades() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        apply(snapshot(sessionID: "session-a", title: "A", status: .completed, revision: 1), to: viewModel)
        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: #"[{"type":"metaPatch","patch":{"archived":true,"archivedAt":"2026-08-25T00:00:02.000Z"}}]"#
        ), to: viewModel)

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 2,
            revision: 3,
            mutations: #"[{"type":"metaPatch","patch":{"archived":false,"archivedAt":null}}]"#
        ), to: viewModel)
        viewModel.flushDockStateForTesting()

        #expect(storage.registry.activeSessionIDs == ["session-a"])
        #expect(storage.registry.archivedSessionIDs.isEmpty)
        #expect(viewModel.sessions.map(\.id) == ["session-a"])
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(viewModel.dockState.snapshot.activeSessions.map(\.id) == ["session-a"])
    }

    @Test func archiveTransactionClearsSelectionAndVoiceTargetsForTheRemovedSession() async throws {
        let selectionStore = V2SelectionStore()
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: PickyRegistrySessionProjectionStorage(),
            selectionStore: selectionStore
        )
        apply(snapshot(sessionID: "session-a", title: "A", status: .running, revision: 1), to: viewModel)
        viewModel.select(sessionID: "session-a")
        viewModel.beginHoveredVoiceFollowUp(sessionID: "session-a")
        viewModel.toggleScreenContextTarget(sessionID: "session-a")
        NotificationCenter.default.post(
            name: .pickyVoiceFollowUpTargetChanged,
            object: nil,
            userInfo: [PickyVoiceFollowUpTargetNotification.sessionIDKey: "session-a"]
        )
        await waitUntil { viewModel.activeVoiceFollowUpSessionID == "session-a" }

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: #"[{"type":"metaPatch","patch":{"archived":true}}]"#
        ), to: viewModel)

        #expect(viewModel.selectedSessionID == nil)
        #expect(selectionStore.selectedSessionID == nil)
        #expect(viewModel.hoveredVoiceFollowUpSessionID == nil)
        #expect(selectionStore.hoveredVoiceFollowUpSessionID == nil)
        #expect(viewModel.screenContextTargetSessionID == nil)
        #expect(selectionStore.screenContextTargetSessionID == nil)
        #expect(viewModel.activeVoiceFollowUpSessionID == nil)
    }

    @Test func transactionUpdatesOnlyItsSessionStoreAndPreservesMessageLeafIdentity() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        apply(snapshot(sessionID: "session-a", title: "A", status: .running, revision: 1), to: viewModel)
        apply(snapshot(sessionID: "session-b", title: "B", status: .running, revision: 1), to: viewModel)
        let unrelated = storage.registry.sessionStore(sessionID: "session-b")
        let invalidations = ProjectionInvalidationCounter()
        withObservationTracking { _ = unrelated.metaStore.metadataState } onChange: { invalidations.increment() }

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: #"[{"type":"metaPatch","patch":{"title":"Renamed"}},{"type":"messageAppend","message":{"id":"message-1","kind":"agent_text","createdAt":"2026-08-25T00:00:01.000Z","text":"Streaming"}},{"type":"messageReplace","messageId":"message-1","message":{"id":"message-1","kind":"agent_text","createdAt":"2026-08-25T00:00:01.000Z","text":"Complete"}}]"#
        ), to: viewModel)

        #expect(viewModel.sessions.first { $0.id == "session-a" }?.title == "Renamed")
        #expect(storage.registry.sessionStore(sessionID: "session-a").conversationStore.messageStore(id: "message-1").messageState.loadedValue?.text == "Complete")
        #expect(invalidations.count == 0)
    }

    @Test func terminalSyncOutcomeUpdatesOnlyItsV2Store() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage)
        apply(snapshot(
            sessionID: "session-a",
            title: "Terminal sync",
            status: .completed,
            revision: 7,
            extraProjectionFields: ",\"finalAnswer\":\"Finished answer\",\"logs\":[\"pi session: /tmp/a.jsonl\"],\"tools\":[{\"toolCallId\":\"tool-a\",\"name\":\"bash\",\"status\":\"succeeded\"}]"
        ), to: viewModel)
        apply(snapshot(sessionID: "session-b", title: "Unrelated", status: .running, revision: 9), to: viewModel)
        let addressed = storage.registry.sessionStore(sessionID: "session-a")
        let unrelated = storage.registry.sessionStore(sessionID: "session-b")

        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "terminal-sync-outcome",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .terminalSessionSyncOutcome(terminalSyncOutcome(sessionID: "session-a", importedMessageCount: 2))
        )))

        #expect(viewModel.sessions.first { $0.id == "session-a" }?.lastTerminalSyncOutcome?.importedMessageCount == 2)
        #expect(addressed.metaStore.metadataState.loadedValue?.revision == 7)
        #expect(addressed.materializedAgentSessionSummary()?.finalAnswer == "Finished answer")
        #expect(addressed.logStore.logsState.loadedValue == ["pi session: /tmp/a.jsonl"])
        #expect(addressed.toolStore.toolsState.loadedValue?.map(\.toolCallId) == ["tool-a"])
        #expect(unrelated === storage.registry.sessionStore(sessionID: "session-b"))
        #expect(unrelated.metaStore.metadataState.loadedValue?.revision == 9)
    }

    @Test func gapRequestsOneRecoveryAndMatchingSnapshotReplaysBufferedTransaction() async throws {
        let client = FakePickyAgentClient()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: client, storage: storage)
        apply(snapshot(sessionID: "session-a", title: "Initial", status: .running, revision: 1), to: viewModel)

        apply(transaction(sessionID: "session-a", baseRevision: 3, revision: 4, mutations: #"[{"type":"metaPatch","patch":{"title":"Recovered"}}]"#), to: viewModel)
        apply(transaction(sessionID: "session-a", baseRevision: 4, revision: 5, mutations: #"[{"type":"metaPatch","patch":{"lastSummary":"Replay complete"}}]"#), to: viewModel)
        for _ in 0..<8 { await Task.yield() }

        let request = try #require(client.sentCommands.first { $0.type == .getSessionProjectionSnapshot })
        #expect(client.sentCommands.filter { $0.type == .getSessionProjectionSnapshot }.count == 1)
        #expect(request.sessionId == "session-a")
        #expect(request.requestId != nil)

        apply(snapshot(sessionID: "session-a", title: "Initial", status: .running, revision: 3, requestID: request.requestId), to: viewModel)

        let card = try #require(viewModel.sessions.first { $0.id == "session-a" })
        #expect(card.title == "Recovered")
        #expect(card.lastSummary == "Replay complete")
        #expect(storage.registry.sessionStore(sessionID: "session-a").metaStore.metadataState.loadedValue?.revision == 5)
    }

    @Test func correlatedProjectionRecoveryErrorRetriesWithTheRequestAsCommandID() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(sessionID: "session-a", title: "Initial", status: .running, revision: 1), to: viewModel)
        apply(transaction(sessionID: "session-a", baseRevision: 3, revision: 4, mutations: #"[{"type":"metaPatch","patch":{"title":"Buffered"}}]"#), to: viewModel)
        await waitUntil { client.sentCommands.filter { $0.type == .getSessionProjectionSnapshot }.count == 1 }

        let firstRequest = try #require(client.sentCommands.first { $0.type == .getSessionProjectionSnapshot })
        #expect(firstRequest.id == firstRequest.requestId)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "recovery-error",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .error(PickyErrorEvent(code: "bad_message", message: "Unknown session", commandId: firstRequest.id))
        )))

        await waitUntil { client.sentCommands.filter { $0.type == .getSessionProjectionSnapshot }.count == 2 }
        let retryRequest = try #require(client.sentCommands.last { $0.type == .getSessionProjectionSnapshot })
        #expect(retryRequest.id == retryRequest.requestId)
        #expect(retryRequest.id != firstRequest.id)
    }

    @Test func recoverySnapshotUnarchivesAndReplaysBufferedTransactionAfterAGap() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = V2ArchiveStore()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: client, storage: storage, archiveStore: archiveStore)
        apply(snapshot(sessionID: "session-a", title: "Archived", status: .completed, revision: 3, archived: true), to: viewModel)

        // Revision 4 unarchived the session but was missed. Revision 5 creates
        // the gap, and revision 6 must still replay after recovery installs 5.
        apply(transaction(sessionID: "session-a", baseRevision: 4, revision: 5, mutations: #"[{"type":"metaPatch","patch":{"lastSummary":"Gap detected"}}]"#), to: viewModel)
        apply(transaction(sessionID: "session-a", baseRevision: 5, revision: 6, mutations: #"[{"type":"metaPatch","patch":{"title":"Replayed"}}]"#), to: viewModel)
        await waitUntil { client.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }

        let request = try #require(client.sentCommands.first { $0.type == .getSessionProjectionSnapshot })
        apply(snapshot(sessionID: "session-a", title: "Recovered", status: .completed, revision: 5, requestID: request.requestId, archived: false), to: viewModel)

        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        #expect(storage.registry.activeSessionIDs == ["session-a"])
        #expect(storage.registry.archivedSessionIDs.isEmpty)
        #expect(viewModel.sessions.map(\.id) == ["session-a"])
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(viewModel.sessions.first?.title == "Replayed")
        #expect(storage.registry.sessionStore(sessionID: "session-a").metaStore.metadataState.loadedValue?.revision == 6)
    }

    @Test func recoverySnapshotWithUnchangedPiSessionPathPreservesTerminalSyncOutcome() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(
            sessionID: "session-a",
            title: "Initial",
            status: .running,
            revision: 1,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/session-a.jsonl\""
        ), to: viewModel)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "terminal-sync-outcome",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .terminalSessionSyncOutcome(terminalSyncOutcome(sessionID: "session-a", importedMessageCount: 2))
        )))
        apply(transaction(sessionID: "session-a", baseRevision: 2, revision: 3, mutations: "[{\"type\":\"metaPatch\",\"patch\":{\"title\":\"Buffered\"}}]"), to: viewModel)
        await waitUntil { client.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let request = try #require(client.sentCommands.first { $0.type == .getSessionProjectionSnapshot })

        apply(snapshot(
            sessionID: "session-a",
            title: "Recovered",
            status: .running,
            revision: 2,
            requestID: request.requestId,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/session-a.jsonl\""
        ), to: viewModel)

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome?.importedMessageCount == 2)
    }

    @Test func recoverySnapshotWithChangedPiSessionPathClearsTerminalSyncOutcome() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(
            sessionID: "session-a",
            title: "Initial",
            status: .running,
            revision: 1,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/old-session.jsonl\""
        ), to: viewModel)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "terminal-sync-outcome",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .terminalSessionSyncOutcome(terminalSyncOutcome(sessionID: "session-a", importedMessageCount: 2))
        )))
        apply(transaction(sessionID: "session-a", baseRevision: 2, revision: 3, mutations: "[{\"type\":\"metaPatch\",\"patch\":{\"title\":\"Buffered\"}}]"), to: viewModel)
        await waitUntil { client.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let request = try #require(client.sentCommands.first { $0.type == .getSessionProjectionSnapshot })

        apply(snapshot(
            sessionID: "session-a",
            title: "Replacement",
            status: .running,
            revision: 2,
            requestID: request.requestId,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/new-session.jsonl\""
        ), to: viewModel)

        #expect(viewModel.sessions.first?.piSessionFilePath == "/tmp/new-session.jsonl")
        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome == nil)
    }

    @Test func localArchiveMembershipChangesPreserveV2StoresThroughUnarchiveAndRollback() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = V2ArchiveStore()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: client, storage: storage, archiveStore: archiveStore)
        apply(snapshot(
            sessionID: "session-a",
            title: "Archive",
            status: .completed,
            revision: 7,
            archived: false,
            extraProjectionFields: ",\"finalAnswer\":\"Archived answer\",\"logs\":[\"pi session: /tmp/a.jsonl\"],\"tools\":[{\"toolCallId\":\"tool-a\",\"name\":\"bash\",\"status\":\"succeeded\"}]"
        ), to: viewModel)
        apply(snapshot(
            sessionID: "session-b",
            title: "Unrelated",
            status: .running,
            revision: 9,
            archived: false,
            extraProjectionFields: ",\"finalAnswer\":\"Unrelated answer\",\"logs\":[\"pi session: /tmp/b.jsonl\"],\"tools\":[{\"toolCallId\":\"tool-b\",\"name\":\"read\",\"status\":\"succeeded\"}]"
        ), to: viewModel)
        let addressed = storage.registry.sessionStore(sessionID: "session-a")
        let unrelated = storage.registry.sessionStore(sessionID: "session-b")
        let addressedLogStore = addressed.logStore
        let addressedToolStore = addressed.toolStore

        func expectStoresRemainIntact() {
            #expect(addressed === storage.registry.sessionStore(sessionID: "session-a"))
            #expect(addressed.logStore === addressedLogStore)
            #expect(addressed.toolStore === addressedToolStore)
            #expect(addressed.metaStore.metadataState.loadedValue?.revision == 7)
            #expect(addressed.materializedAgentSessionSummary()?.finalAnswer == "Archived answer")
            #expect(addressed.logStore.logsState.loadedValue == ["pi session: /tmp/a.jsonl"])
            #expect(addressed.toolStore.toolsState.loadedValue?.map(\.toolCallId) == ["tool-a"])
            #expect(unrelated === storage.registry.sessionStore(sessionID: "session-b"))
            #expect(unrelated.metaStore.metadataState.loadedValue?.revision == 9)
            #expect(unrelated.materializedAgentSessionSummary()?.finalAnswer == "Unrelated answer")
            #expect(unrelated.logStore.logsState.loadedValue == ["pi session: /tmp/b.jsonl"])
            #expect(unrelated.toolStore.toolsState.loadedValue?.map(\.toolCallId) == ["tool-b"])
        }

        viewModel.archive(sessionID: "session-a")
        await waitUntil { client.sentCommands.filter { $0.type == .setSessionArchived }.count == 1 }
        #expect(viewModel.archivedSessions.map(\.id) == ["session-a"])
        expectStoresRemainIntact()

        viewModel.unarchive(sessionID: "session-a")
        await waitUntil { client.sentCommands.filter { $0.type == .setSessionArchived }.count == 2 }
        #expect(viewModel.sessions.map(\.id) == ["session-a", "session-b"])
        expectStoresRemainIntact()

        viewModel.archive(sessionID: "session-a")
        await waitUntil { client.sentCommands.filter { $0.type == .setSessionArchived }.count == 3 }
        let rejectedCommand = try #require(client.sentCommands.last { $0.type == .setSessionArchived })
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "archive-rejected",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .error(PickyErrorEvent(code: "bad_message", message: "Cannot archive", commandId: rejectedCommand.id))
        )))

        #expect(viewModel.pendingArchiveIntentBySessionID.isEmpty)
        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        #expect(storage.registry.activeSessionIDs == ["session-a", "session-b"])
        #expect(viewModel.archivedSessions.isEmpty)
        expectStoresRemainIntact()
    }

    @Test func correlatedRecoverySnapshotResolvesConflictingPendingArchiveIntent() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = V2ArchiveStore()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: client, storage: storage, archiveStore: archiveStore)
        apply(snapshot(sessionID: "session-a", title: "Archive", status: .completed, revision: 1, archived: false), to: viewModel)

        viewModel.archive(sessionID: "session-a")
        await waitUntil { client.sentCommands.contains { $0.type == .setSessionArchived } }
        apply(transaction(sessionID: "session-a", baseRevision: 3, revision: 4, mutations: "[{\"type\":\"metaPatch\",\"patch\":{\"title\":\"Buffered\"}}]"), to: viewModel)
        await waitUntil { client.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let request = try #require(client.sentCommands.last { $0.type == .getSessionProjectionSnapshot })

        apply(snapshot(sessionID: "session-a", title: "Recovered active", status: .completed, revision: 3, requestID: request.requestId, archived: false), to: viewModel)

        #expect(viewModel.pendingArchiveIntentBySessionID.isEmpty)
        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        #expect(storage.registry.activeSessionIDs == ["session-a"])
        #expect(storage.registry.archivedSessionIDs.isEmpty)

        apply(transaction(sessionID: "session-a", baseRevision: 4, revision: 5, mutations: "[{\"type\":\"metaPatch\",\"patch\":{\"archived\":true}}]"), to: viewModel)

        #expect(storage.registry.activeSessionIDs.isEmpty)
        #expect(storage.registry.archivedSessionIDs == ["session-a"])
        #expect(viewModel.archivedSessions.map(\.id) == ["session-a"])
    }

    @Test func failedArchiveSendRestoresActiveV2Membership() async throws {
        let client = FakePickyAgentClient()
        client.shouldThrowOnSend = true
        let archiveStore = V2ArchiveStore()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: client, storage: storage, archiveStore: archiveStore)
        apply(snapshot(sessionID: "session-a", title: "Archive", status: .completed, revision: 1, archived: false), to: viewModel)

        viewModel.archive(sessionID: "session-a")
        await waitUntil { viewModel.pendingArchiveIntentBySessionID.isEmpty }

        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        #expect(storage.registry.activeSessionIDs == ["session-a"])
        #expect(viewModel.sessions.map(\.id) == ["session-a"])
        #expect(viewModel.archivedSessions.isEmpty)
    }

    @Test func pendingOptimisticArchiveSurvivesStaleBootstrapSnapshot() {
        let archiveStore = V2ArchiveStore()
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: storage,
            archiveStore: archiveStore
        )
        apply(snapshot(sessionID: "session-a", title: "Active", status: .completed, revision: 1, archived: false), to: viewModel)

        viewModel.archive(sessionID: "session-a")
        // No request ID marks this as a regular bootstrap. It arrives before
        // the optimistic archive command has been confirmed.
        apply(snapshot(sessionID: "session-a", title: "Stale", status: .completed, revision: 2, archived: false), to: viewModel)

        #expect(archiveStore.manuallyArchivedSessionIDs == ["session-a"])
        #expect(storage.registry.activeSessionIDs.isEmpty)
        #expect(storage.registry.archivedSessionIDs == ["session-a"])
        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["session-a"])
    }

    @Test func archiveIntentPolicyLimitsUnarchiveToAuthoritativeRecovery() {
        #expect(PickySessionProjectionArchiveIntentPolicy.snapshotUpdate(
            archived: false,
            origin: .recovery,
            pendingLocalIntent: nil
        ) == .set(false))
        #expect(PickySessionProjectionArchiveIntentPolicy.snapshotUpdate(
            archived: false,
            origin: .bootstrap,
            pendingLocalIntent: nil
        ) == .preserve)
        #expect(PickySessionProjectionArchiveIntentPolicy.snapshotUpdate(
            archived: false,
            origin: .recovery,
            pendingLocalIntent: true
        ) == .setAndResolvePending(false))
        #expect(PickySessionProjectionArchiveIntentPolicy.transactionUpdate(
            archived: true,
            pendingLocalIntent: true
        ) == .setAndResolvePending(true))
    }

    @Test func bootstrapSnapshotHydratesPresentationFromAuthoritativeLogs() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage)
        let incoming = snapshot(
            sessionID: "session-a",
            title: "Hydrated",
            status: .running,
            revision: 1,
            extraProjectionFields: ",\"logs\":[\"steer: Resume the investigation\",\"pi session: /tmp/pi-session.jsonl\",\"Latest output\"],\"tools\":[]"
        )
        let expected = PickySessionListViewModel.SessionCard.fromAgentSession(incoming.projection)

        apply(incoming, to: viewModel)

        let card = try #require(viewModel.sessions.first)
        #expect(card.logPreview == expected.logPreview)
        #expect(card.lastRequestText == expected.lastRequestText)
        #expect(card.piSessionFilePath == expected.piSessionFilePath)
        #expect(card.hasRuntimeDetachedFollowUpRejection == expected.hasRuntimeDetachedFollowUpRejection)
        #expect(card.isMainAgentHandoff == expected.isMainAgentHandoff)
    }

    @Test func replacementTransactionClearsEverySessionResetCollectionAndPresentation() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage)
        apply(snapshot(
            sessionID: "session-a",
            title: "Before reset",
            status: .completed,
            revision: 1,
            extraProjectionFields: #","piSessionFilePath":"/tmp/old.jsonl","lastSummary":"Completed","finalAnswer":"Old answer""# +
                #","logs":["followup: Old request","pi session: /tmp/old.jsonl"]"# +
                #","tools":[{"toolCallId":"tool-old","name":"bash","status":"succeeded"}]"# +
                #","todoState":{"tasks":[{"id":"todo-old","content":"Old task","status":"pending"}],"updatedAt":"2026-08-25T00:00:00.000Z"}"# +
                #","subagentRuns":[{"runId":1,"agent":"worker","task":"Old task","status":"done"}]"# +
                #","artifacts":[{"id":"artifact-old","kind":"report","title":"Old report","updatedAt":"2026-08-25T00:00:00.000Z"}]"# +
                #","changedFiles":[{"path":"old.swift","status":"modified"}]"# +
                #","messages":[{"id":"message-old","kind":"user_text","createdAt":"2026-08-25T00:00:00.000Z","text":"Old request"}]"# +
                #","queuedSteers":[{"id":"steer-old","text":"Old steer","enqueuedAt":"2026-08-25T00:00:00.000Z"}]"# +
                #","queuedFollowUps":[{"id":"followup-old","text":"Old follow-up","enqueuedAt":"2026-08-25T00:00:00.000Z"}]"# +
                #","activitySummary":{"read":1,"bash":1,"edit":0,"write":0,"thinking":0,"other":0}"#
        ), to: viewModel)

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: #"[{"type":"metaPatch","patch":{"status":"waiting_for_input","piSessionFilePath":"/tmp/new.jsonl","lastSummary":"Ready for instructions"}},{"type":"logsSet","logs":[]},{"type":"messageRemove","messageId":"message-old"},{"type":"toolsSet","tools":[]},{"type":"todoSet","todoState":null},{"type":"subagentRunsSet","runs":[]},{"type":"artifactsSet","artifacts":[]},{"type":"changedFilesSet","changedFiles":[]},{"type":"queueSet","queuedSteers":[],"queuedFollowUps":[],"steeringMode":"one-at-a-time","followUpMode":"one-at-a-time"},{"type":"activitySet","activitySummary":{"read":0,"bash":0,"edit":0,"write":0,"thinking":0,"other":0}},{"type":"finalAnswerSet","finalAnswer":null}]"#
        ), to: viewModel)

        let store = storage.registry.sessionStore(sessionID: "session-a")
        let session = try #require(store.materializedAgentSessionSummary())
        let card = try #require(viewModel.sessions.first)
        #expect(session.logs.isEmpty)
        #expect(session.tools.isEmpty)
        #expect(session.artifacts.isEmpty)
        #expect(session.changedFiles.isEmpty)
        #expect(card.messages.isEmpty)
        #expect(session.todoState == nil)
        #expect(session.subagentRuns.isEmpty)
        #expect(session.queuedSteers.isEmpty)
        #expect(session.queuedFollowUps.isEmpty)
        #expect(session.activitySummary == .zero)
        #expect(session.finalAnswer == nil)
        #expect(card.logPreview.isEmpty)
        #expect(card.lastRequestText == nil)
        #expect(card.piSessionFilePath == "/tmp/new.jsonl")
    }

    @Test func replacementTransactionClearsTerminalSyncOutcome() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = makeViewModel(client: FakePickyAgentClient(), storage: storage)
        apply(snapshot(sessionID: "session-a", title: "Before reset", status: .completed, revision: 1), to: viewModel)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "terminal-sync-outcome",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .terminalSessionSyncOutcome(terminalSyncOutcome(sessionID: "session-a", importedMessageCount: 2))
        )))

        apply(transaction(
            sessionID: "session-a",
            baseRevision: 1,
            revision: 2,
            mutations: "[{\"type\":\"logsSet\",\"logs\":[]},{\"type\":\"toolsSet\",\"tools\":[]},{\"type\":\"artifactsSet\",\"artifacts\":[]}]"
        ), to: viewModel)

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome == nil)
    }

    @Test func metaPatchDistinguishesExplicitClearFromAbsentField() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        apply(snapshot(sessionID: "session-a", title: "Initial", status: .running, revision: 1, thinkingPreview: "Thinking"), to: viewModel)

        apply(transaction(sessionID: "session-a", baseRevision: 1, revision: 2, mutations: #"[{"type":"metaPatch","patch":{"thinkingPreview":null}}]"#), to: viewModel)
        apply(transaction(sessionID: "session-a", baseRevision: 2, revision: 3, mutations: #"[{"type":"metaPatch","patch":{"title":"Renamed"}}]"#), to: viewModel)

        let metadata = storage.registry.sessionStore(sessionID: "session-a").metaStore.metadataState.loadedValue
        #expect(metadata?.thinkingPreview == nil)
        #expect(metadata?.title == "Renamed")
    }

    @Test func bootstrapSeedsTerminalNotificationDedupBeforeLaterProjectionTransactions() throws {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = makeViewModel(
            client: FakePickyAgentClient(),
            storage: PickyRegistrySessionProjectionStorage(),
            notificationCenter: notifications,
            notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
                notifyOnCompleted: true,
                notifyOnFailed: true,
                notifyOnWaitingForInput: true
            ))
        )

        apply(snapshot(sessionID: "historical", title: "Historical", status: .completed, revision: 1), to: viewModel)
        apply(transaction(sessionID: "historical", baseRevision: 1, revision: 2, mutations: #"[{"type":"metaPatch","patch":{"lastSummary":"Still historical"}}]"#), to: viewModel)

        #expect(notifications.delivered.isEmpty)
    }

    @Test func visibleDiffRefreshesWhenProjectionTransactionLeavesRunning() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(sessionID: "diff-session", title: "Diff", status: .running, revision: 1), to: viewModel)

        viewModel.setSessionDiffVisible(true, sessionID: "diff-session")
        await waitUntil { client.sentCommands.filter { $0.type == .getSessionDiff }.count == 1 }

        apply(transaction(sessionID: "diff-session", baseRevision: 1, revision: 2, mutations: #"[{"type":"metaPatch","patch":{"status":"completed"}}]"#), to: viewModel)
        await waitUntil { client.sentCommands.filter { $0.type == .getSessionDiff }.count == 2 }

        #expect(client.sentCommands.filter { $0.type == .getSessionDiff }.count == 2)
    }

    @Test func piSessionPathMetaPatchInvalidatesLoadedSlashCommandsDespiteLogDerivedPresentation() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(
            sessionID: "commands",
            title: "Commands",
            status: .running,
            revision: 1,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/pi-a.jsonl\",\"logs\":[\"pi session: /tmp/pi-a.jsonl\"]"
        ), to: viewModel)
        viewModel.ensureSlashCommandsLoaded(sessionID: "commands")
        await waitUntil { client.sentCommands.contains { $0.type == .listSlashCommands } }
        let requestID = try #require(client.sentCommands.last { $0.type == .listSlashCommands }?.id)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "commands-loaded",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.bootstrapDate,
            event: .slashCommandsSnapshot(sessionId: "commands", requestId: requestID, commands: [PickySlashCommand(name: "help", description: nil, source: .builtin)])
        )))
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "commands"))

        apply(transaction(sessionID: "commands", baseRevision: 1, revision: 2, mutations: "[{\"type\":\"metaPatch\",\"patch\":{\"piSessionFilePath\":\"/tmp/pi-b.jsonl\"}}]"), to: viewModel)

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "commands"))
        #expect(viewModel.sessions.first?.piSessionFilePath == "/tmp/pi-a.jsonl")
    }

    @Test func projectionLogAndMetadataChangesInvalidateLoadedSlashCommands() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(
            sessionID: "commands",
            title: "Commands",
            status: .running,
            revision: 1,
            extraProjectionFields: ",\"piSessionFilePath\":\"/tmp/pi.jsonl\""
        ), to: viewModel)

        viewModel.ensureSlashCommandsLoaded(sessionID: "commands")
        await waitUntil { client.sentCommands.contains { $0.type == .listSlashCommands } }
        let requestID = try #require(client.sentCommands.last { $0.type == .listSlashCommands }?.id)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "commands-loaded",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.bootstrapDate,
            event: .slashCommandsSnapshot(sessionId: "commands", requestId: requestID, commands: [PickySlashCommand(name: "help", description: nil, source: .builtin)])
        )))
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "commands"))

        apply(transaction(sessionID: "commands", baseRevision: 1, revision: 2, mutations: #"[{"type":"logAppend","line":"pi session: /tmp/pi.jsonl"}]"#), to: viewModel)

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "commands"))

        viewModel.ensureSlashCommandsLoaded(sessionID: "commands")
        await waitUntil { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        let refreshedRequestID = try #require(client.sentCommands.last { $0.type == .listSlashCommands }?.id)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "commands-reloaded",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.bootstrapDate,
            event: .slashCommandsSnapshot(sessionId: "commands", requestId: refreshedRequestID, commands: [PickySlashCommand(name: "help", description: nil, source: .builtin)])
        )))
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "commands"))

        apply(transaction(sessionID: "commands", baseRevision: 2, revision: 3, mutations: #"[{"type":"metaPatch","patch":{"cwd":"/tmp/new-cwd"}}]"#), to: viewModel)

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "commands"))
    }

    @Test func recoverySnapshotsReplayTransitionsWhileBootstrapSnapshotsRemainCold() async throws {
        let recoveryClient = FakePickyAgentClient()
        let recoveryViewModel = makeViewModel(client: recoveryClient, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(sessionID: "recovery", title: "Recovery", status: .running, revision: 1), to: recoveryViewModel)
        apply(transaction(sessionID: "recovery", baseRevision: 2, revision: 3, mutations: #"[{"type":"metaPatch","patch":{"title":"Buffered"}}]"#), to: recoveryViewModel)
        await waitUntil { recoveryClient.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let recoveryRequest = try #require(recoveryClient.sentCommands.first { $0.type == .getSessionProjectionSnapshot })

        apply(snapshot(sessionID: "recovery", title: "Recovered", status: .completed, revision: 2, requestID: recoveryRequest.requestId), to: recoveryViewModel)

        #expect(recoveryViewModel.pendingDoneFlashSessionIDs.contains("recovery"))
        #expect(recoveryViewModel.unreadSessionIDs.contains("recovery"))

        let bootstrapViewModel = makeViewModel(client: FakePickyAgentClient(), storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(sessionID: "bootstrap", title: "Bootstrap", status: .running, revision: 1), to: bootstrapViewModel)
        apply(snapshot(sessionID: "bootstrap", title: "Bootstrap", status: .completed, revision: 2), to: bootstrapViewModel)

        #expect(!bootstrapViewModel.pendingDoneFlashSessionIDs.contains("bootstrap"))
        #expect(!bootstrapViewModel.unreadSessionIDs.contains("bootstrap"))
    }

    @Test func recoveryTerminalSnapshotNotifiesActiveSessionButNotArchivedSession() async throws {
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))

        let archivedClient = FakePickyAgentClient()
        let archivedNotifications = PickyNoopNotificationCenter()
        let archivedViewModel = makeViewModel(
            client: archivedClient,
            storage: PickyRegistrySessionProjectionStorage(),
            notificationCenter: archivedNotifications,
            notificationPreferencesProvider: preferences
        )
        apply(snapshot(sessionID: "archived", title: "Archived", status: .running, revision: 1, archived: true), to: archivedViewModel)
        apply(transaction(sessionID: "archived", baseRevision: 2, revision: 3, mutations: #"[{"type":"metaPatch","patch":{"title":"Gap"}}]"#), to: archivedViewModel)
        await waitUntil { archivedClient.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let archivedRecovery = try #require(archivedClient.sentCommands.first { $0.type == .getSessionProjectionSnapshot })
        apply(snapshot(sessionID: "archived", title: "Archived", status: .completed, revision: 2, requestID: archivedRecovery.requestId, archived: true), to: archivedViewModel)

        #expect(archivedViewModel.archivedSessions.first?.status == .completed)
        #expect(archivedNotifications.delivered.isEmpty)

        let activeClient = FakePickyAgentClient()
        let activeNotifications = PickyNoopNotificationCenter()
        let activeViewModel = makeViewModel(
            client: activeClient,
            storage: PickyRegistrySessionProjectionStorage(),
            notificationCenter: activeNotifications,
            notificationPreferencesProvider: preferences
        )
        apply(snapshot(sessionID: "active", title: "Active", status: .running, revision: 1), to: activeViewModel)
        apply(transaction(sessionID: "active", baseRevision: 2, revision: 3, mutations: #"[{"type":"metaPatch","patch":{"title":"Gap"}}]"#), to: activeViewModel)
        await waitUntil { activeClient.sentCommands.contains { $0.type == .getSessionProjectionSnapshot } }
        let activeRecovery = try #require(activeClient.sentCommands.first { $0.type == .getSessionProjectionSnapshot })
        apply(snapshot(sessionID: "active", title: "Active", status: .completed, revision: 2, requestID: activeRecovery.requestId), to: activeViewModel)

        #expect(activeNotifications.delivered.map(\.identifier) == ["active:completed"])
    }

    @Test func terminalTransactionPublishesPinnedV2BudgetAndPreservesAttentionEffects() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        apply(snapshot(sessionID: PickyProjectionReplayFixtures.terminalSessionID, title: "Terminal", status: .running, revision: 1), to: viewModel)
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        apply(transaction(
            sessionID: PickyProjectionReplayFixtures.terminalSessionID,
            baseRevision: 1,
            revision: 2,
            mutations: """
            [{"type":"metaPatch","patch":{"status":"completed","lastSummary":"Completed the investigation."}},{"type":"messagesImport","messages":[{"id":"assistant-terminal","kind":"agent_text","createdAt":"2026-08-25T00:00:01.000Z","text":"Completed"}]},{"type":"artifactUpsert","artifact":{"id":"artifact-terminal","kind":"github","title":"#123","updatedAt":"2026-08-25T00:00:01.000Z","url":"https://github.com/creatrip/picky/pull/123"}},{"type":"finalAnswerSet","finalAnswer":"Completed"}]
            """
        ), to: viewModel)

        // One façade relay plus the existing terminal attention/UI-state
        // boundaries. This is intentionally pinned against the v1 baseline (62).
        #expect(publishCount == 5)
        #expect(viewModel.pendingDoneFlashSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        #expect(viewModel.unreadSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        withExtendedLifetime(cancellable) {}
    }

    private func makeViewModel(
        client: FakePickyAgentClient,
        storage: PickyRegistrySessionProjectionStorage,
        notificationCenter: PickyNotificationDelivering = PickyNoopNotificationCenter(),
        notificationPreferencesProvider: PickyNotificationPreferencesProviding = PickyStubNotificationPreferences(),
        selectionStore: PickySessionSelectionStoring = V2SelectionStore(),
        archiveStore: PickySessionArchiveStoring = V2ArchiveStore(),
        dockLayoutStore: PickyDockLayoutStoring = PickyNoopDockLayoutStore()
    ) -> PickySessionListViewModel {
        PickySessionListViewModel(
            client: client,
            notificationCenter: notificationCenter,
            notificationPreferencesProvider: notificationPreferencesProvider,
            selectionStore: selectionStore,
            archiveStore: archiveStore,
            manualOrderStore: V2ManualOrderStore(),
            composerDraftStore: V2ComposerDraftStore(),
            composerAttachmentDraftStore: V2AttachmentDraftStore(),
            dockLayoutStore: dockLayoutStore,
            sessionProjectionStorage: storage
        )
    }

    private func apply(_ snapshot: PickySessionProjectionSnapshot, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "snapshot-\(snapshot.sessionId)-\(snapshot.revision)", protocolVersion: pickyAgentProtocolVersion, timestamp: PickyProjectionReplayFixtures.bootstrapDate, event: .sessionProjectionSnapshot(snapshot))))
    }

    private func apply(_ transaction: PickySessionProjectionTransaction, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "transaction-\(transaction.sessionId)-\(transaction.revision)", protocolVersion: pickyAgentProtocolVersion, timestamp: PickyProjectionReplayFixtures.terminalDate, event: .sessionProjectionTransaction(transaction))))
    }

    private func snapshot(sessionID: String, title: String, status: PickySessionStatus, revision: Int, requestID: String? = nil, thinkingPreview: String? = nil, archived: Bool? = nil, extraProjectionFields: String = "") -> PickySessionProjectionSnapshot {
        let request = requestID.map { "\"requestId\":\"\($0)\"," } ?? ""
        let preview = thinkingPreview.map { ",\"thinkingPreview\":\"\($0)\"" } ?? ""
        let archive = archived.map { ",\"archived\":\($0)" } ?? ""
        let json = """
        {
          \(request)"sessionId":"\(sessionID)","epoch":"epoch-1","revision":\(revision),"complete":true,"omittedFields":[],
          "projection":{"id":"\(sessionID)","title":"\(title)","status":"\(status.rawValue)","createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:00:00.000Z"\(preview)\(archive)\(extraProjectionFields)}
        }
        """
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
    }

    private func terminalSyncOutcome(sessionID: String, importedMessageCount: Int) -> PickyTerminalSessionSyncOutcome {
        let json = """
        {"sessionId":"\(sessionID)","baselineFound":true,"importedMessageCount":\(importedMessageCount)}
        """
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyTerminalSessionSyncOutcome.self, from: Data(json.utf8))
    }

    private func transaction(sessionID: String, baseRevision: Int, revision: Int, mutations: String) -> PickySessionProjectionTransaction {
        let json = """
        {"sessionId":"\(sessionID)","epoch":"epoch-1","baseRevision":\(baseRevision),"revision":\(revision),"mutations":\(mutations)}
        """
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionTransaction.self, from: Data(json.utf8))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
        #expect(predicate())
    }
}

private final class ProjectionInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class V2SelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky = false
    func setScreenContextTarget(sessionID: String?, sticky: Bool) { screenContextTargetSessionID = sessionID; screenContextTargetSticky = sticky }
}
private final class V2ArchiveStore: PickySessionArchiveStoring { var archivedSessionIDs = Set<String>(); var manuallyArchivedSessionIDs = Set<String>() }
private final class V2ManualOrderStore: PickySessionManualOrderStoring { var manualOrder: [String] = [] }
private final class V2ComposerDraftStore: PickyComposerDraftStoring { func draft(for _: String) -> String? { nil }; func setDraft(_: String?, for _: String) {}; func prune(knownSessionIDs _: Set<String>) {} }
private final class V2AttachmentDraftStore: PickyComposerAttachmentDraftStoring { func attachmentPaths(for _: String) -> [String] { [] }; func setAttachmentPaths(_: [String], for _: String) {}; func prune(knownSessionIDs _: Set<String>) {} }

@MainActor
private final class V2DockLayoutStore: PickyDockLayoutStoring {
    private var layout: PickyDockLayout
    private(set) var savedLayouts: [PickyDockLayout] = []

    init(layout: PickyDockLayout = .empty) {
        self.layout = layout
    }

    func load() -> PickyDockLayout { layout }

    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        self.layout = layout
        savedLayouts.append(layout)
        completion(.success(()))
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? { if case .loaded(let value) = self { value } else { nil } }
}

