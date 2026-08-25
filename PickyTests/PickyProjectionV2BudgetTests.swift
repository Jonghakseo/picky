//
//  PickyProjectionV2BudgetTests.swift
//  PickyTests
//

import Combine
import Foundation
import Observation
import Testing
@testable import Picky

@MainActor
struct PickyProjectionV2BudgetTests {
    // Deterministic W7 pins. v1 characterization remains in the dedicated
    // W0 suites (bootstrap: 1,054; terminal burst: 62).
    private static let bootstrapPublishBudget = 96
    private static let messageOnlyV1PublishBudget = 3
    private static let messageOnlyV2PublishBudget = 3
    private static let messageOnlyDockPublishBudget = 1
    private static let terminalV2PublishBudget = 5
    private static let terminalDockPublishBudget = 1
    private static let metaPatchByteBudget = 4 * 1_024
    private static let transactionMaterializedCardBudget = 94

    @Test func bootstrapSnapshotsPublishThePinnedV2BridgeBudget() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        // SessionSupervisor sends bootstrap snapshots in descending `updatedAt`
        // order, while the fixture is constructed in ascending order. Reversing
        // here models the production connection path: the default selection is
        // established once, then subsequent snapshots must not republish it.
        for (index, session) in PickyProjectionReplayFixtures.lightweightBootstrapSessions().reversed().enumerated() {
            try apply(snapshot(for: session, revision: index), to: viewModel)
        }

        // v1 snapshot + hydration is 1,054 publications for the same 94-session
        // corpus. V2 emits one registry façade publish per snapshot plus the
        // initial loader and default-selection transitions, satisfying the
        // ≤1+ε target.
        #expect(publishCount == Self.bootstrapPublishBudget)
        #expect(viewModel.sessions.count + viewModel.archivedSessions.count == 94)
        withExtendedLifetime(cancellable) {}
    }

    @Test func messageOnlyTransactionKeepsUnrelatedChildIsolatedAndPinsDockProjectionWork() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        let target = PickyProjectionReplayFixtures.bootstrapSession(
            id: "message-target", index: 1, status: .running, archived: false, messages: [], messageJournalAvailable: true
        )
        let unrelated = PickyProjectionReplayFixtures.bootstrapSession(
            id: "message-unrelated", index: 2, status: .running, archived: false, messages: [], messageJournalAvailable: true
        )
        try apply(snapshot(for: target, revision: 1), to: viewModel)
        try apply(snapshot(for: unrelated, revision: 1), to: viewModel)
        viewModel.flushDockStateForTesting()

        let unrelatedInvalidations = W7ObservationInvalidationCounter()
        let unrelatedStore = storage.registry.sessionStore(sessionID: unrelated.id)
        withObservationTracking { _ = unrelatedStore.conversationStore.orderedMessageIDs } onChange: {
            unrelatedInvalidations.increment()
        }

        var v2PublishCount = 0
        let v2Cancellable = viewModel.objectWillChange.sink { v2PublishCount += 1 }
        var dockPublishCount = 0
        let dockCancellable = viewModel.dockState.$snapshot.dropFirst().sink { _ in dockPublishCount += 1 }

        try apply(messageOnlyTransaction(sessionID: target.id), to: viewModel)
        viewModel.flushDockStateForTesting()

        #expect(unrelatedInvalidations.count == 0)
        #expect(v2PublishCount == Self.messageOnlyV2PublishBudget)
        // A dock snapshot publish is an upper-bound proxy for dock rail
        // recomputation; the current bridge still publishes one snapshot.
        #expect(dockPublishCount == Self.messageOnlyDockPublishBudget)
        withExtendedLifetime(v2Cancellable) {}
        withExtendedLifetime(dockCancellable) {}

        let v1ViewModel = PickyProjectionReplayFixtures.makeViewModel()
        PickyProjectionReplayFixtures.apply(
            PickyProjectionReplayFixtures.bootstrapEnvelope(
                id: "v1-message-bootstrap",
                event: .sessionSnapshot(PickySessionSnapshot(sessions: [target]))
            ),
            to: v1ViewModel
        )
        var v1PublishCount = 0
        let v1Cancellable = v1ViewModel.objectWillChange.sink { v1PublishCount += 1 }
        PickyProjectionReplayFixtures.apply(
            PickyProjectionReplayFixtures.bootstrapEnvelope(
                id: "v1-message-append",
                event: .sessionMessageAppended(
                    sessionId: target.id,
                    message: PickyProjectionReplayFixtures.terminalMessage(id: "message-only", kind: .agentText, text: "Streaming"),
                    seq: 1
                )
            ),
            to: v1ViewModel
        )
        #expect(v1PublishCount == Self.messageOnlyV1PublishBudget)
        withExtendedLifetime(v1Cancellable) {}
    }

    @Test func terminalTransactionPinsV2FacadeAndDockBudgets() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        let initial = PickyProjectionReplayFixtures.terminalSession(
            status: .running, messages: [], messageJournalAvailable: true, artifacts: []
        )
        try apply(snapshot(for: initial, revision: 1), to: viewModel)
        viewModel.flushDockStateForTesting()

        var facadePublishCount = 0
        let facadeCancellable = viewModel.objectWillChange.sink { facadePublishCount += 1 }
        var dockPublishCount = 0
        let dockCancellable = viewModel.dockState.$snapshot.dropFirst().sink { _ in dockPublishCount += 1 }

        try apply(canonicalTerminalTransaction(), to: viewModel)
        viewModel.flushDockStateForTesting()

        // Agentd integration contracts separately pin this terminal transition
        // to one transaction frame, one save, and one revision increment.
        #expect(facadePublishCount == Self.terminalV2PublishBudget)
        #expect(dockPublishCount == Self.terminalDockPublishBudget)
        #expect(viewModel.sessions.first?.status == .completed)
        #expect(viewModel.pendingDoneFlashSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        #expect(viewModel.unreadSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        withExtendedLifetime(facadeCancellable) {}
        withExtendedLifetime(dockCancellable) {}
    }

    @Test func canonicalTerminalMetaPatchStaysBelowTheOwnedLargeMutationBudget() throws {
        let transactionData = Data(canonicalTerminalTransactionJSON.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: transactionData) as? [String: Any])
        let mutations = try #require(object["mutations"] as? [[String: Any]])
        let patchMutation = try #require(mutations.first { $0["type"] as? String == "metaPatch" })
        let patchData = try JSONSerialization.data(withJSONObject: patchMutation, options: [.sortedKeys])

        // Large owned collections remain separate mutations (messages/artifacts/
        // final answer), so this scalar meta patch must remain independently bounded.
        #expect(patchData.count < Self.metaPatchByteBudget)
    }

    @Test func transactionOverNinetyFourSessionsPinsCurrentEagerMaterializationWork() throws {
        let storage = PickyRegistrySessionProjectionStorage()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(sessionProjectionStorage: storage)
        for index in 0..<Self.transactionMaterializedCardBudget {
            let session = PickyProjectionReplayFixtures.bootstrapSession(
                id: String(format: "eager-%03d", index),
                index: index,
                status: .running,
                archived: false,
                messages: [],
                messageJournalAvailable: true
            )
            try apply(snapshot(for: session, revision: 1), to: viewModel)
        }

        var emittedSnapshots: [PickySessionProjectionStorageSnapshot] = []
        let cancellable = storage.changes.sink { emittedSnapshots.append($0) }
        try apply(messageOnlyTransaction(sessionID: "eager-000"), to: viewModel)

        // `publishProjection` currently calls `snapshot()`, whose `cards(for:)`
        // eagerly materializes every active ID. The output cardinality is the
        // deterministic black-box proxy available without production counters.
        #expect(emittedSnapshots.count == 1)
        #expect(emittedSnapshots[0].activeSessions.count == Self.transactionMaterializedCardBudget)
        #expect(emittedSnapshots[0].archivedSessions.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    private func apply(_ snapshot: PickySessionProjectionSnapshot, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "snapshot-\(snapshot.sessionId)-\(snapshot.revision)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.bootstrapDate,
            event: .sessionProjectionSnapshot(snapshot)
        )))
    }

    private func apply(_ transaction: PickySessionProjectionTransaction, to viewModel: PickySessionListViewModel) {
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "transaction-\(transaction.sessionId)-\(transaction.revision)",
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: PickyProjectionReplayFixtures.terminalDate,
            event: .sessionProjectionTransaction(transaction)
        )))
    }

    private func snapshot(for session: PickyAgentSession, revision: Int) throws -> PickySessionProjectionSnapshot {
        let projection = try String(decoding: JSONEncoder.pickyAgentProtocolEncoder().encode(session), as: UTF8.self)
        let json = """
        {"sessionId":"\(session.id)","epoch":"w7-epoch","revision":\(revision),"complete":true,"omittedFields":[],"projection":\(projection)}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
    }

    private func messageOnlyTransaction(sessionID: String) throws -> PickySessionProjectionTransaction {
        let json = """
        {"sessionId":"\(sessionID)","epoch":"w7-epoch","baseRevision":1,"revision":2,"mutations":[{"type":"messageAppend","message":{"id":"message-only","kind":"agent_text","createdAt":"2026-08-25T00:00:01.000Z","text":"Streaming"}}]}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionTransaction.self, from: Data(json.utf8))
    }

    private func canonicalTerminalTransaction() throws -> PickySessionProjectionTransaction {
        try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionTransaction.self, from: Data(canonicalTerminalTransactionJSON.utf8))
    }

    private var canonicalTerminalTransactionJSON: String {
        """
        {"sessionId":"terminal-session","epoch":"w7-epoch","baseRevision":1,"revision":2,"mutations":[{"type":"metaPatch","patch":{"status":"completed","updatedAt":"2026-08-25T00:00:01.000Z","lastSummary":"Completed the investigation."}},{"type":"messagesImport","messages":[{"id":"assistant-terminal","kind":"agent_text","createdAt":"2026-08-25T00:00:01.000Z","text":"Completed"}]},{"type":"artifactUpsert","artifact":{"id":"artifact-terminal","kind":"github","title":"#123","updatedAt":"2026-08-25T00:00:01.000Z","url":"https://github.com/creatrip/picky/pull/123"}},{"type":"finalAnswerSet","finalAnswer":"Completed"}]}
        """
    }
}

private final class W7ObservationInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
