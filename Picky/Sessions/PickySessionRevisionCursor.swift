//
//  PickySessionRevisionCursor.swift
//  Picky
//
//  Dormant v2 session projection ordering policy.
//

import Foundation

enum PickySessionRevisionCursorDecision: Equatable {
    case apply
    case dropStaleOrDuplicate
    case requestRecovery
    /// The awaited snapshot epoch changed, so the coordinator must abandon
    /// the correlated request before requesting the replacement epoch.
    case replaceRecovery
    /// The recovery coordinator owns buffered transactions; the cursor owns
    /// only ordering state and never retains a second copy.
    case buffer
    /// A response or event cannot be applied to this cursor and must not be
    /// retained (for example, a stale recovery response for another epoch).
    case discard
}

/// Per-session revision policy for the dormant projection-v2 protocol. The
/// current v1 seq path does not construct or consult this type.
struct PickySessionRevisionCursor {
    private(set) var epoch: String?
    private(set) var revision: Int?
    private var awaitingSnapshotEpoch: String?
    private var recoveryRequested = false

    init(epoch: String? = nil, revision: Int? = nil) {
        precondition((epoch == nil) == (revision == nil), "epoch and revision must be installed together")
        self.epoch = epoch
        self.revision = revision
    }

    mutating func receive(transaction: PickySessionProjectionTransaction) -> PickySessionRevisionCursorDecision {
        guard let epoch, let revision else {
            if let awaitingSnapshotEpoch, awaitingSnapshotEpoch != transaction.epoch {
                self.awaitingSnapshotEpoch = transaction.epoch
                recoveryRequested = true
                return .replaceRecovery
            }
            awaitingSnapshotEpoch = transaction.epoch
            if recoveryRequested { return .buffer }
            recoveryRequested = true
            return .requestRecovery
        }
        if let awaitingSnapshotEpoch {
            guard transaction.epoch == awaitingSnapshotEpoch else {
                // A recovery request for the previous epoch cannot establish
                // ordering for this transaction. Tell the coordinator to
                // abandon that request and issue one for the new epoch.
                self.awaitingSnapshotEpoch = transaction.epoch
                recoveryRequested = true
                return .replaceRecovery
            }
            return .buffer
        }
        guard transaction.epoch == epoch else {
            awaitingSnapshotEpoch = transaction.epoch
            recoveryRequested = true
            return .requestRecovery
        }
        guard transaction.revision > revision else { return .dropStaleOrDuplicate }
        guard transaction.baseRevision == revision else {
            if !recoveryRequested {
                recoveryRequested = true
                return .requestRecovery
            }
            return .buffer
        }

        self.revision = transaction.revision
        recoveryRequested = false
        return .apply
    }

    /// Allows the recovery coordinator to issue a replacement request after a
    /// correlated daemon rejection. The cursor still retains its known epoch
    /// and revision, so the replacement snapshot remains authoritative.
    mutating func abandonRecoveryRequest() {
        recoveryRequested = false
    }

    mutating func receive(snapshot: PickySessionProjectionSnapshot) -> PickySessionRevisionCursorDecision {
        if let awaitingSnapshotEpoch {
            guard snapshot.epoch == awaitingSnapshotEpoch else { return .discard }
            install(snapshot)
            return .apply
        }

        if let epoch, let revision, snapshot.epoch == epoch, snapshot.revision < revision {
            return .dropStaleOrDuplicate
        }

        // An epoch-bearing snapshot is authoritative at its serialized server
        // barrier. It is therefore safe to install a new epoch even when this
        // cursor has not yet observed its first transaction.
        install(snapshot)
        return .apply
    }

    private mutating func install(_ snapshot: PickySessionProjectionSnapshot) {
        epoch = snapshot.epoch
        revision = snapshot.revision
        awaitingSnapshotEpoch = nil
        recoveryRequested = false
    }
}
