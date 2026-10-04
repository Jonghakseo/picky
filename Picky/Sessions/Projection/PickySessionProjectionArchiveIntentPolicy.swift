//
//  PickySessionProjectionArchiveIntentPolicy.swift
//  Picky
//
//  Pure policy for reconciling an incoming projection's archive flag with an
//  optimistic local archive intent that has not been acknowledged yet.
//

import Foundation

enum PickySessionProjectionArchiveIntentUpdate: Equatable {
    case preserve
    case set(Bool)
    case setAndResolvePending(Bool)
}

enum PickySessionProjectionArchiveIntentPolicy {
    static func snapshotUpdate(
        archived: Bool?,
        origin: PickySessionRecoveryCoordinator.SnapshotOrigin,
        pendingLocalIntent: Bool?
    ) -> PickySessionProjectionArchiveIntentUpdate {
        guard let archived else { return .preserve }
        if pendingLocalIntent != nil {
            guard origin == .recovery else { return .preserve }
            // A response to the in-flight recovery request is authoritative
            // even when it conflicts with an optimistic archive intent. It
            // can briefly flicker if the daemon processes the command later,
            // but that later transaction re-applies the archive, whereas
            // preserving the conflict leaves the session hidden forever.
            return .setAndResolvePending(archived)
        }
        switch origin {
        case .recovery:
            return .set(archived)
        case .bootstrap:
            return archived ? .set(true) : .preserve
        }
    }

    static func transactionUpdate(
        archived: Bool,
        pendingLocalIntent: Bool?
    ) -> PickySessionProjectionArchiveIntentUpdate {
        guard let pendingLocalIntent else { return .set(archived) }
        guard archived == pendingLocalIntent else { return .preserve }
        return .setAndResolvePending(archived)
    }
}
