//
//  PickySessionRecoveryCoordinator.swift
//  Picky
//
//  Dormant v2 per-session projection recovery orchestration.
//

import Foundation

/// Keeps recovery local to the affected session. It deliberately owns the
/// buffered transactions: `PickySessionRevisionCursor` owns only epoch/revision
/// ordering decisions, preventing two owners from replaying the same frame.
@MainActor
final class PickySessionRecoveryCoordinator {
    typealias SnapshotRequest = (_ sessionID: String, _ requestID: String) -> Void
    /// The injected applier must mark every child section named in
    /// `omittedFields` as `.unavailable` (clearing stale values) before it
    /// exposes the bounded projection. Production wiring is intentionally
    /// deferred to W6.5.
    typealias SnapshotApplier = (_ snapshot: PickySessionProjectionSnapshot, _ omittedFields: [String]) -> Void
    typealias TransactionApplier = (_ transaction: PickySessionProjectionTransaction) -> Void

    private struct SessionState {
        var cursor = PickySessionRevisionCursor()
        var inFlightRequestID: String?
        var bufferedTransactions: [PickySessionProjectionTransaction] = []
    }

    private var states: [String: SessionState] = [:]
    private let requestSnapshot: SnapshotRequest
    private let applySnapshot: SnapshotApplier
    private let applyTransaction: TransactionApplier
    private let makeRequestID: () -> String

    init(
        requestSnapshot: @escaping SnapshotRequest,
        applySnapshot: @escaping SnapshotApplier,
        applyTransaction: @escaping TransactionApplier,
        requestID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.requestSnapshot = requestSnapshot
        self.applySnapshot = applySnapshot
        self.applyTransaction = applyTransaction
        makeRequestID = requestID
    }

    func receive(transaction: PickySessionProjectionTransaction) {
        var state = states[transaction.sessionId] ?? SessionState()
        let decision = state.cursor.receive(transaction: transaction)
        var transactionToApply: PickySessionProjectionTransaction?
        var requestID: String?

        switch decision {
        case .apply:
            transactionToApply = transaction
        case .dropStaleOrDuplicate, .discard:
            break
        case .requestRecovery, .buffer:
            state.bufferedTransactions.append(transaction)
            if decision == .requestRecovery {
                requestID = beginRecoveryIfNeeded(in: &state)
            }
        }

        states[transaction.sessionId] = state
        if let transactionToApply { applyTransaction(transactionToApply) }
        if let requestID { requestSnapshot(transaction.sessionId, requestID) }
    }

    func receive(snapshot: PickySessionProjectionSnapshot) {
        guard let requestID = snapshot.requestId else {
            receiveBootstrap(snapshot: snapshot)
            return
        }
        receiveRecovery(snapshot: snapshot, requestID: requestID)
    }

    /// Installs the fresh v2 index snapshot before live transactions begin.
    /// Unlike a recovery response, it has no request correlation and is
    /// authoritative for the session's current epoch at the index barrier.
    private func receiveBootstrap(snapshot: PickySessionProjectionSnapshot) {
        var state = states[snapshot.sessionId] ?? SessionState()
        state.inFlightRequestID = nil
        state.cursor = PickySessionRevisionCursor()
        guard case .apply = state.cursor.receive(snapshot: snapshot) else { return }
        install(snapshot: snapshot, into: &state)
    }

    /// Accepts only the response correlated to the session's outstanding
    /// recovery request; late responses must never replace a newer cursor.
    private func receiveRecovery(snapshot: PickySessionProjectionSnapshot, requestID: String) {
        guard var state = states[snapshot.sessionId], state.inFlightRequestID == requestID else {
            return
        }

        state.inFlightRequestID = nil
        switch state.cursor.receive(snapshot: snapshot) {
        case .apply:
            install(snapshot: snapshot, into: &state)
        case .dropStaleOrDuplicate, .requestRecovery, .buffer, .discard:
            // The server answered a request but the cursor could not install
            // it (for example, the daemon epoch changed during recovery).
            let nextRequestID = beginRecoveryIfNeeded(in: &state)
            states[snapshot.sessionId] = state
            if let nextRequestID { requestSnapshot(snapshot.sessionId, nextRequestID) }
        }
    }

    private func install(snapshot: PickySessionProjectionSnapshot, into state: inout SessionState) {
        // The installed snapshot supersedes old revisions and other epochs;
        // only future frames from its epoch remain eligible for replay.
        state.bufferedTransactions.removeAll {
            $0.epoch != snapshot.epoch || $0.revision <= snapshot.revision
        }
        var transactionsToApply: [PickySessionProjectionTransaction] = []
        let nextRequestID = drainContiguousTransactions(
            sessionID: snapshot.sessionId,
            state: &state,
            applied: &transactionsToApply
        )

        states[snapshot.sessionId] = state
        applySnapshot(snapshot, snapshot.omittedFields)
        for transaction in transactionsToApply { applyTransaction(transaction) }
        if let nextRequestID { requestSnapshot(snapshot.sessionId, nextRequestID) }
    }

    func inFlightRequestID(sessionID: String) -> String? {
        states[sessionID]?.inFlightRequestID
    }

    func bufferedTransactionCount(sessionID: String) -> Int {
        states[sessionID]?.bufferedTransactions.count ?? 0
    }

    private func beginRecoveryIfNeeded(in state: inout SessionState) -> String? {
        guard state.inFlightRequestID == nil else { return nil }
        let requestID = makeRequestID()
        state.inFlightRequestID = requestID
        return requestID
    }

    private func drainContiguousTransactions(
        sessionID: String,
        state: inout SessionState,
        applied: inout [PickySessionProjectionTransaction]
    ) -> String? {
        state.bufferedTransactions.sort {
            ($0.baseRevision, $0.revision) < ($1.baseRevision, $1.revision)
        }

        while let first = state.bufferedTransactions.first {
            switch state.cursor.receive(transaction: first) {
            case .apply:
                state.bufferedTransactions.removeFirst()
                applied.append(first)
            case .dropStaleOrDuplicate, .discard:
                state.bufferedTransactions.removeFirst()
            case .requestRecovery:
                return beginRecoveryIfNeeded(in: &state)
            case .buffer:
                return nil
            }
        }
        return nil
    }
}
