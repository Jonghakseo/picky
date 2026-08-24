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
    case bufferOrDiscard
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
        guard let epoch, let revision else { return .bufferOrDiscard }
        if awaitingSnapshotEpoch != nil { return .bufferOrDiscard }
        guard transaction.epoch == epoch else {
            awaitingSnapshotEpoch = transaction.epoch
            recoveryRequested = false
            return .bufferOrDiscard
        }
        guard transaction.revision > revision else { return .dropStaleOrDuplicate }
        guard transaction.baseRevision == revision else {
            if !recoveryRequested {
                recoveryRequested = true
                return .requestRecovery
            }
            return .bufferOrDiscard
        }

        self.revision = transaction.revision
        recoveryRequested = false
        return .apply
    }

    mutating func receive(snapshot: PickySessionProjectionSnapshot) -> PickySessionRevisionCursorDecision {
        guard snapshot.complete else { return .bufferOrDiscard }

        if let awaitingSnapshotEpoch {
            guard snapshot.epoch == awaitingSnapshotEpoch else { return .bufferOrDiscard }
            install(snapshot)
            return .apply
        }

        if let epoch, let revision {
            guard snapshot.epoch == epoch else {
                awaitingSnapshotEpoch = snapshot.epoch
                recoveryRequested = false
                return .bufferOrDiscard
            }
            guard snapshot.revision >= revision else { return .dropStaleOrDuplicate }
        }

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
