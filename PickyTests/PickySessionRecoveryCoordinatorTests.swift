//
//  PickySessionRecoveryCoordinatorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickySessionRecoveryCoordinatorTests {
    @Test func gapBuffersOneSessionAndReplaysContiguousTransactionsAfterMatchingSnapshot() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var snapshots: [(sessionID: String, omittedFields: [String])] = []
        var applied: [Int] = []
        var nextRequest = 0
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { snapshot, omittedFields in snapshots.append((snapshot.sessionId, omittedFields)) },
            applyTransaction: { transaction in applied.append(transaction.revision) },
            requestID: { nextRequest += 1; return "request-\(nextRequest)" }
        )

        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 3, revision: 4))
        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 4, revision: 5))

        #expect(requests.map(\.requestID) == ["request-1"])
        #expect(applied.isEmpty)
        #expect(coordinator.bufferedTransactionCount(sessionID: "session-a") == 2)

        coordinator.receive(snapshot: try snapshot(requestID: "request-1", sessionID: "session-a", epoch: "epoch-1", revision: 3, omittedFields: ["messages"]))

        #expect(snapshots.map(\.sessionID) == ["session-a"])
        #expect(snapshots.first?.omittedFields == ["messages"])
        #expect(applied == [4, 5])
        #expect(coordinator.bufferedTransactionCount(sessionID: "session-a") == 0)
    }

    @Test func recoveryBlocksOnlyAffectedSessionWhileAnotherSessionContinues() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var applied: [String] = []
        var nextRequest = 0
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { _, _ in },
            applyTransaction: { transaction in applied.append("\(transaction.sessionId):\(transaction.revision)") },
            requestID: { nextRequest += 1; return "request-\(nextRequest)" }
        )

        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 2, revision: 3))
        coordinator.receive(transaction: try transaction(sessionID: "session-b", epoch: "epoch-1", baseRevision: 7, revision: 8))
        coordinator.receive(snapshot: try snapshot(requestID: "request-2", sessionID: "session-b", epoch: "epoch-1", revision: 7))

        #expect(requests.map(\.sessionID) == ["session-a", "session-b"])
        #expect(applied == ["session-b:8"])
        #expect(coordinator.bufferedTransactionCount(sessionID: "session-a") == 1)
        #expect(coordinator.bufferedTransactionCount(sessionID: "session-b") == 0)
    }

    @Test func bootstrapSnapshotInstallsCursorBeforeFollowingContiguousTransaction() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var snapshots: [String] = []
        var applied: [Int] = []
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { snapshot, _ in snapshots.append("\(snapshot.epoch):\(snapshot.revision)") },
            applyTransaction: { transaction in applied.append(transaction.revision) },
            requestID: { "unexpected-recovery" }
        )

        coordinator.receive(snapshot: try snapshot(requestID: nil, sessionID: "session-a", epoch: "epoch-1", revision: 3))
        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 3, revision: 4))

        #expect(snapshots == ["epoch-1:3"])
        #expect(applied == [4])
        #expect(requests.isEmpty)
        #expect(coordinator.inFlightRequestID(sessionID: "session-a") == nil)
    }

    @Test func bootstrapSnapshotForNewEpochReplacesPendingRecoveryState() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var snapshots: [String] = []
        var applied: [Int] = []
        var nextRequest = 0
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { snapshot, _ in snapshots.append("\(snapshot.epoch):\(snapshot.revision)") },
            applyTransaction: { transaction in applied.append(transaction.revision) },
            requestID: { nextRequest += 1; return "request-\(nextRequest)" }
        )

        coordinator.receive(snapshot: try snapshot(requestID: nil, sessionID: "session-a", epoch: "epoch-1", revision: 3))
        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 5, revision: 6))
        #expect(requests.map(\.requestID) == ["request-1"])

        coordinator.receive(snapshot: try snapshot(requestID: nil, sessionID: "session-a", epoch: "epoch-2", revision: 7))
        // The bootstrap cleared request-1. Its late, formerly matching recovery
        // response must not replace the newly installed epoch-2 cursor.
        coordinator.receive(snapshot: try snapshot(requestID: "request-1", sessionID: "session-a", epoch: "epoch-1", revision: 6))
        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-2", baseRevision: 7, revision: 8))

        #expect(snapshots == ["epoch-1:3", "epoch-2:7"])
        #expect(applied == [8])
        #expect(coordinator.inFlightRequestID(sessionID: "session-a") == nil)
        #expect(coordinator.bufferedTransactionCount(sessionID: "session-a") == 0)
    }

    @Test func staleRecoveryResponseIsIgnoredUntilTheMatchingRequestArrives() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var snapshots: [String] = []
        var nextRequest = 0
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { snapshot, _ in snapshots.append(snapshot.requestId ?? "missing") },
            applyTransaction: { _ in },
            requestID: { nextRequest += 1; return "request-\(nextRequest)" }
        )

        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-1", baseRevision: 0, revision: 1))
        coordinator.receive(snapshot: try snapshot(requestID: "stale-request", sessionID: "session-a", epoch: "epoch-1", revision: 0))

        #expect(snapshots.isEmpty)
        #expect(coordinator.inFlightRequestID(sessionID: "session-a") == "request-1")

        coordinator.receive(snapshot: try snapshot(requestID: "request-1", sessionID: "session-a", epoch: "epoch-1", revision: 0))

        #expect(snapshots == ["request-1"])
        #expect(coordinator.inFlightRequestID(sessionID: "session-a") == nil)
    }

    @Test func epochChangeDuringRecoveryDiscardsStaleResponseAndRequestsTheNewEpoch() throws {
        var requests: [(sessionID: String, requestID: String)] = []
        var applied: [Int] = []
        var nextRequest = 0
        let coordinator = PickySessionRecoveryCoordinator(
            requestSnapshot: { sessionID, requestID in requests.append((sessionID, requestID)) },
            applySnapshot: { _, _ in },
            applyTransaction: { transaction in applied.append(transaction.revision) },
            requestID: { nextRequest += 1; return "request-\(nextRequest)" }
        )

        coordinator.receive(transaction: try transaction(sessionID: "session-a", epoch: "epoch-2", baseRevision: 4, revision: 5))
        coordinator.receive(snapshot: try snapshot(requestID: "request-1", sessionID: "session-a", epoch: "epoch-1", revision: 4))

        #expect(requests.map(\.requestID) == ["request-1", "request-2"])
        #expect(applied.isEmpty)

        coordinator.receive(snapshot: try snapshot(requestID: "request-2", sessionID: "session-a", epoch: "epoch-2", revision: 4))

        #expect(applied == [5])
    }

    private func transaction(sessionID: String, epoch: String, baseRevision: Int, revision: Int) throws -> PickySessionProjectionTransaction {
        let json = """
        {"sessionId":"\(sessionID)","epoch":"\(epoch)","baseRevision":\(baseRevision),"revision":\(revision),"mutations":[{"type":"metaPatch","patch":{"title":"Updated"}}]}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionTransaction.self, from: Data(json.utf8))
    }

    private func snapshot(requestID: String?, sessionID: String, epoch: String, revision: Int, omittedFields: [String] = []) throws -> PickySessionProjectionSnapshot {
        let omittedJSON = String(data: try JSONEncoder().encode(omittedFields), encoding: .utf8)!
        let requestIDJSON = requestID.map { "\"requestId\":\"\($0)\"," } ?? ""
        let json = """
        {\(requestIDJSON)"sessionId":"\(sessionID)","epoch":"\(epoch)","revision":\(revision),"complete":\(omittedFields.isEmpty ? "true" : "false"),"omittedFields":\(omittedJSON),"projection":{"id":"\(sessionID)","title":"Session","status":"running","createdAt":"2026-08-24T00:00:00.000Z","updatedAt":"2026-08-24T00:00:00.000Z"}}
        """
        return try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: Data(json.utf8))
    }
}
