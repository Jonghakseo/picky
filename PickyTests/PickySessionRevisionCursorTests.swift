//
//  PickySessionRevisionCursorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySessionRevisionCursorTests {
    @Test func dropsStaleAndDuplicateTransactions() throws {
        var cursor = PickySessionRevisionCursor(epoch: "epoch-1", revision: 4)

        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-1", baseRevision: 3, revision: 4)) == .dropStaleOrDuplicate)
        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-1", baseRevision: 2, revision: 4)) == .dropStaleOrDuplicate)
    }

    @Test func appliesContiguousTransaction() throws {
        var cursor = PickySessionRevisionCursor(epoch: "epoch-1", revision: 4)

        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-1", baseRevision: 4, revision: 5)) == .apply)
        #expect(cursor.revision == 5)
    }

    @Test func requestsOneRecoveryForContinuousGap() throws {
        var cursor = PickySessionRevisionCursor(epoch: "epoch-1", revision: 4)

        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-1", baseRevision: 6, revision: 7)) == .requestRecovery)
        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-1", baseRevision: 7, revision: 8)) == .buffer)
    }

    @Test func blocksTransactionsAfterEpochChangesUntilMatchingSnapshotArrives() throws {
        var cursor = PickySessionRevisionCursor(epoch: "epoch-1", revision: 4)

        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-2", baseRevision: 4, revision: 5)) == .requestRecovery)
        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-2", baseRevision: 5, revision: 6)) == .buffer)
        #expect(cursor.receive(snapshot: try snapshot(epoch: "epoch-1", revision: 5)) == .discard)
        #expect(cursor.receive(snapshot: try snapshot(epoch: "epoch-2", revision: 5)) == .apply)
        #expect(cursor.receive(transaction: try transaction(epoch: "epoch-2", baseRevision: 4, revision: 5)) == .dropStaleOrDuplicate)
    }

    private func transaction(epoch: String, baseRevision: Int, revision: Int) throws -> PickySessionProjectionTransaction {
        let json = """
        {"sessionId":"session-1","epoch":"\(epoch)","baseRevision":\(baseRevision),"revision":\(revision),"mutations":[{"type":"metaPatch","patch":{"title":"Updated"}}]}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionTransaction.self, from: Data(json.utf8))
    }

    private func snapshot(epoch: String, revision: Int) throws -> PickySessionProjectionSnapshot {
        let json = """
        {"requestId":"snapshot-1","sessionId":"session-1","epoch":"\(epoch)","revision":\(revision),"complete":true,"omittedFields":[],"projection":{"id":"session-1","title":"Session","status":"running","createdAt":"2026-08-24T00:00:00.000Z","updatedAt":"2026-08-24T00:00:00.000Z"}}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
    }
}
