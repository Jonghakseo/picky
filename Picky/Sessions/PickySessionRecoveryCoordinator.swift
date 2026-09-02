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
    enum SnapshotOrigin: Equatable {
        case bootstrap
        case recovery
    }

    typealias SnapshotRequest = (_ sessionID: String, _ requestID: String) -> Void
    /// The injected applier must mark every child section named in
    /// `omittedFields` as `.unavailable` (clearing stale values) before it
    /// exposes the bounded projection. Production wiring is intentionally
    /// deferred to W6.5.
    typealias SnapshotApplier = (_ snapshot: PickySessionProjectionSnapshot, _ omittedFields: [String], _ origin: SnapshotOrigin) -> Void
    typealias TransactionApplier = (_ transaction: PickySessionProjectionTransaction) -> Void

    private struct SessionState {
        var cursor = PickySessionRevisionCursor()
        var inFlightRequestID: String?
        var recoveryFailureCount = 0
        var bufferedTransactionsSinceRecoveryRequest = 0
        var bufferedTransactions: [PickySessionProjectionTransaction] = []
    }

    private var states: [String: SessionState] = [:]
    private let requestSnapshot: SnapshotRequest
    private let applySnapshot: SnapshotApplier
    private let applyTransaction: TransactionApplier
    private let makeRequestID: () -> String
    private let recoveryRetryTransactionThreshold: Int
    private let maximumBufferedTransactions: Int
    private let maximumRecoveryRetriesWithoutSnapshot: Int

    init(
        requestSnapshot: @escaping SnapshotRequest,
        applySnapshot: @escaping SnapshotApplier,
        applyTransaction: @escaping TransactionApplier,
        requestID: @escaping () -> String = { UUID().uuidString },
        recoveryRetryTransactionThreshold: Int = 32,
        maximumBufferedTransactions: Int = 256,
        maximumRecoveryRetriesWithoutSnapshot: Int = 2
    ) {
        precondition(recoveryRetryTransactionThreshold > 0)
        precondition(maximumBufferedTransactions > 0)
        precondition(maximumRecoveryRetriesWithoutSnapshot > 0)
        self.requestSnapshot = requestSnapshot
        self.applySnapshot = applySnapshot
        self.applyTransaction = applyTransaction
        makeRequestID = requestID
        self.recoveryRetryTransactionThreshold = recoveryRetryTransactionThreshold
        self.maximumBufferedTransactions = maximumBufferedTransactions
        self.maximumRecoveryRetriesWithoutSnapshot = maximumRecoveryRetriesWithoutSnapshot
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
        case .requestRecovery:
            state.bufferedTransactions.append(transaction)
            requestID = beginRecoveryIfNeeded(in: &state)
        case .replaceRecovery:
            state.bufferedTransactions.append(transaction)
            // The cursor changed epochs, so the in-flight response can never
            // install. Clear both owners before replacing its request ID.
            state.inFlightRequestID = nil
            state.cursor.abandonRecoveryRequest()
            requestID = beginRecoveryIfNeeded(in: &state)
        case .buffer:
            state.bufferedTransactions.append(transaction)
            requestID = advanceRecoveryIfNeeded(in: &state)
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
        state.recoveryFailureCount = 0
        state.bufferedTransactionsSinceRecoveryRequest = 0
        state.cursor = PickySessionRevisionCursor()
        guard case .apply = state.cursor.receive(snapshot: snapshot) else { return }
        install(snapshot: snapshot, origin: .bootstrap, into: &state)
    }

    /// Accepts only the response correlated to the session's outstanding
    /// recovery request; late responses must never replace a newer cursor.
    private func receiveRecovery(snapshot: PickySessionProjectionSnapshot, requestID: String) {
        guard var state = states[snapshot.sessionId], state.inFlightRequestID == requestID else {
            return
        }

        state.inFlightRequestID = nil
        state.recoveryFailureCount = 0
        switch state.cursor.receive(snapshot: snapshot) {
        case .apply:
            install(snapshot: snapshot, origin: .recovery, into: &state)
        case .dropStaleOrDuplicate, .requestRecovery, .replaceRecovery, .buffer, .discard:
            // The server answered a request but the cursor could not install
            // it (for example, the daemon epoch changed during recovery).
            let nextRequestID = beginRecoveryIfNeeded(in: &state)
            states[snapshot.sessionId] = state
            if let nextRequestID { requestSnapshot(snapshot.sessionId, nextRequestID) }
        }
    }

    private func install(snapshot: PickySessionProjectionSnapshot, origin: SnapshotOrigin, into state: inout SessionState) {
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
        applySnapshot(snapshot, snapshot.omittedFields, origin)
        for transaction in transactionsToApply { applyTransaction(transaction) }
        if let nextRequestID { requestSnapshot(snapshot.sessionId, nextRequestID) }
    }

    /// Releases a recovery request rejected through the existing
    /// command-correlated `error` event. The first rejection retries once;
    /// another rejection drops buffered state and resets the cursor so a later
    /// transaction can begin a fresh recovery instead of buffering forever.
    func receiveRecoveryFailure(commandID: String?) {
        guard let commandID,
              let sessionID = states.first(where: { $0.value.inFlightRequestID == commandID })?.key,
              var state = states[sessionID]
        else { return }

        state.inFlightRequestID = nil
        state.recoveryFailureCount += 1
        if state.recoveryFailureCount < 2 {
            state.cursor.abandonRecoveryRequest()
            let retryRequestID = beginRecoveryIfNeeded(in: &state)
            states[sessionID] = state
            if let retryRequestID { requestSnapshot(sessionID, retryRequestID) }
            return
        }

        resetBufferedRecoveryState(in: &state)
        states[sessionID] = state
    }

    func inFlightRequestID(sessionID: String) -> String? {
        states[sessionID]?.inFlightRequestID
    }

    func bufferedTransactionCount(sessionID: String) -> Int {
        states[sessionID]?.bufferedTransactions.count ?? 0
    }

    /// Authoritative membership removal must also discard any cursor, buffered
    /// transactions, and correlated recovery request so a recreated ID starts
    /// from a clean projection incarnation.
    func remove(sessionID: String) {
        states.removeValue(forKey: sessionID)
    }

    private func beginRecoveryIfNeeded(in state: inout SessionState) -> String? {
        guard state.inFlightRequestID == nil else { return nil }
        let requestID = makeRequestID()
        state.inFlightRequestID = requestID
        state.bufferedTransactionsSinceRecoveryRequest = 0
        return requestID
    }

    /// Recovery responses are normally immediate on localhost, so continued
    /// incoming mutations are deterministic proof that the current request is
    /// not making progress. Replace it once, then discard the bounded replay
    /// buffer and let a later frame initiate a clean recovery. This prevents a
    /// lost response from pinning a session in `.buffer` forever.
    private func advanceRecoveryIfNeeded(in state: inout SessionState) -> String? {
        guard state.bufferedTransactions.count <= maximumBufferedTransactions else {
            resetBufferedRecoveryState(in: &state)
            return nil
        }
        guard state.inFlightRequestID != nil else {
            return beginRecoveryIfNeeded(in: &state)
        }

        state.bufferedTransactionsSinceRecoveryRequest += 1
        guard state.bufferedTransactionsSinceRecoveryRequest >= recoveryRetryTransactionThreshold else {
            return nil
        }

        state.recoveryFailureCount += 1
        guard state.recoveryFailureCount < maximumRecoveryRetriesWithoutSnapshot else {
            resetBufferedRecoveryState(in: &state)
            return nil
        }

        state.inFlightRequestID = nil
        state.cursor.abandonRecoveryRequest()
        return beginRecoveryIfNeeded(in: &state)
    }

    private func resetBufferedRecoveryState(in state: inout SessionState) {
        state.inFlightRequestID = nil
        state.recoveryFailureCount = 0
        state.bufferedTransactionsSinceRecoveryRequest = 0
        state.cursor = PickySessionRevisionCursor()
        state.bufferedTransactions.removeAll()
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
            case .requestRecovery, .replaceRecovery:
                return beginRecoveryIfNeeded(in: &state)
            case .buffer:
                return nil
            }
        }
        return nil
    }
}
