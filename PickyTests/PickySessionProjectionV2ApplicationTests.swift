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

    @Test func projectionRuntimeReattachLogInvalidatesLoadedSlashCommands() async throws {
        let client = FakePickyAgentClient()
        let viewModel = makeViewModel(client: client, storage: PickyRegistrySessionProjectionStorage())
        apply(snapshot(sessionID: "commands", title: "Commands", status: .running, revision: 1), to: viewModel)

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

        apply(transaction(sessionID: "commands", baseRevision: 1, revision: 2, mutations: #"[{"type":"logAppend","line":"runtime reattached from pi session: /tmp/pi.jsonl"}]"#), to: viewModel)

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "commands"))
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
        notificationPreferencesProvider: PickyNotificationPreferencesProviding = PickyStubNotificationPreferences()
    ) -> PickySessionListViewModel {
        PickySessionListViewModel(
            client: client,
            notificationCenter: notificationCenter,
            notificationPreferencesProvider: notificationPreferencesProvider,
            selectionStore: V2SelectionStore(),
            archiveStore: V2ArchiveStore(),
            manualOrderStore: V2ManualOrderStore(),
            composerDraftStore: V2ComposerDraftStore(),
            composerAttachmentDraftStore: V2AttachmentDraftStore(),
            sessionProjectionStorage: storage
        )
    }

    private func apply(_ snapshot: PickySessionProjectionSnapshot, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "snapshot-\(snapshot.sessionId)-\(snapshot.revision)", protocolVersion: pickyAgentProtocolVersion, timestamp: PickyProjectionReplayFixtures.bootstrapDate, event: .sessionProjectionSnapshot(snapshot))))
    }

    private func apply(_ transaction: PickySessionProjectionTransaction, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "transaction-\(transaction.sessionId)-\(transaction.revision)", protocolVersion: pickyAgentProtocolVersion, timestamp: PickyProjectionReplayFixtures.terminalDate, event: .sessionProjectionTransaction(transaction))))
    }

    private func snapshot(sessionID: String, title: String, status: PickySessionStatus, revision: Int, requestID: String? = nil, thinkingPreview: String? = nil) -> PickySessionProjectionSnapshot {
        let request = requestID.map { "\"requestId\":\"\($0)\"," } ?? ""
        let preview = thinkingPreview.map { ",\"thinkingPreview\":\"\($0)\"" } ?? ""
        let json = """
        {
          \(request)"sessionId":"\(sessionID)","epoch":"epoch-1","revision":\(revision),"complete":true,"omittedFields":[],
          "projection":{"id":"\(sessionID)","title":"\(title)","status":"\(status.rawValue)","createdAt":"2026-08-25T00:00:00.000Z","updatedAt":"2026-08-25T00:00:00.000Z"\(preview)}
        }
        """
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
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

private extension PickyProjectionSectionState {
    var loadedValue: Value? { if case .loaded(let value) = self { value } else { nil } }
}

