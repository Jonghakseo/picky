//
//  PickyProjectionOwnershipLedger.swift
//  Picky
//
//  Pure ownership rules for session projection frames arriving from several
//  daemon connections (the primary plus one child daemon per manual Pickle).
//  Decides which connection may claim a session, which bootstrap completions
//  are current, and which owned records a completion is allowed to prune.
//  The router owns transport state and calls into this ledger; the ledger
//  never touches sockets or timers.
//

import Foundation

struct PickyProjectionOwnershipLedger: Equatable {
    static let primaryOwnerKey = "primary"

    enum SnapshotOutcome: Equatable {
        /// The snapshot belongs to a current bootstrap and now maps its session to `ownerKey`.
        case accepted
        /// No current bootstrap expectation exists for this owner; the frame is still forwarded.
        case noCurrentBootstrap
        /// The bootstrap observed a second epoch and is poisoned until reconnect.
        case epochMismatch
        /// Another connection already owns this session id; ownership is never transferred by a frame.
        case ownedElsewhere
    }

    enum CompletionOutcome: Equatable {
        case discard(reason: String)
        /// Accepted for correlation only; a booting child may complete an empty index before its first snapshot.
        case acceptedWithoutReconcile
        case reconcile(removedSessionIDs: Set<String>)
    }

    private struct BootstrapExpectation: Equatable {
        let connectionGeneration: Int
        let bootstrapID: String
        var epoch: String?
        /// A bootstrap that observes more than one epoch cannot prove a
        /// coherent membership cutover. It remains poisoned until reconnect.
        var failed = false
    }

    private struct ConnectionKey: Hashable {
        let ownerKey: String
        let connectionGeneration: Int
    }

    private struct CompletionKey: Hashable {
        let ownerKey: String
        let connectionGeneration: Int
        let bootstrapID: String
        let epoch: String
    }

    private struct RetiredChildPrimaryOwnership: Equatable {
        /// `nil` is intentionally conservative: without a known release epoch,
        /// a primary completion cannot prove the child record was rehydrated.
        let primaryEpochAtRelease: String?
    }

    private var ownerKeysBySessionID: [String: String] = [:]
    private var connectionGenerations: [String: Int] = [:]
    private var bootstrapExpectations: [String: BootstrapExpectation] = [:]
    /// Last primary epoch observed on this daemon process. It intentionally
    /// survives a socket reconnect so released-child ownership can distinguish
    /// a reconnect from a daemon restart.
    private var knownPrimaryEpoch: String?
    /// A released child is transferred to primary ownership, but primary
    /// membership exclusion is not authoritative until a different primary
    /// epoch proves a daemon restart rehydrated the shared store.
    private var retiredChildPrimaryOwnerships: [String: RetiredChildPrimaryOwnership] = [:]
    /// Child membership completion is destructive only after this connection
    /// generation has produced its configured session snapshot.
    private var sessionProducingConnections = Set<ConnectionKey>()
    private var acceptedCompletions = Set<CompletionKey>()

    func ownerKey(for sessionID: String) -> String {
        ownerKeysBySessionID[sessionID] ?? Self.primaryOwnerKey
    }

    func sessionIDs(ownedBy ownerKey: String) -> Set<String> {
        Set(ownerKeysBySessionID.compactMap { $0.value == ownerKey ? $0.key : nil })
    }

    /// Clears per-connection correlation while keeping session ownership and
    /// the last primary epoch, which must survive a socket reconnect.
    mutating func disconnectAll() {
        bootstrapExpectations.removeAll()
        knownPrimaryEpoch = nil
        retiredChildPrimaryOwnerships.removeAll()
        sessionProducingConnections.removeAll()
        acceptedCompletions.removeAll()
    }

    /// A new capability registration starts a bootstrap generation for `ownerKey`.
    mutating func beginBootstrap(ownerKey: String, bootstrapID: String) {
        let generation = (connectionGenerations[ownerKey] ?? 0) + 1
        connectionGenerations[ownerKey] = generation
        bootstrapExpectations[ownerKey] = BootstrapExpectation(connectionGeneration: generation, bootstrapID: bootstrapID, epoch: nil)
        sessionProducingConnections = sessionProducingConnections.filter { $0.ownerKey != ownerKey }
        acceptedCompletions = acceptedCompletions.filter { $0.ownerKey != ownerKey }
    }

    mutating func invalidateBootstrap(ownerKey: String) {
        bootstrapExpectations[ownerKey] = nil
        sessionProducingConnections = sessionProducingConnections.filter { $0.ownerKey != ownerKey }
        acceptedCompletions = acceptedCompletions.filter { $0.ownerKey != ownerKey }
    }

    /// A same-ID respawn returns ownership to the child only after the pool has
    /// successfully recreated it. Its current-generation snapshot is still
    /// required before completion reconciliation becomes destructive.
    mutating func assignChildOwnership(sessionID: String, childOwnerKey: String) {
        ownerKeysBySessionID[sessionID] = childOwnerKey
        retiredChildPrimaryOwnerships[sessionID] = nil
    }

    /// The primary supervisor hydrates scoped child session metadata only after
    /// a daemon restart. Transfer ownership now, but retain the current primary
    /// epoch so a same-process socket reconnect cannot falsely prune this
    /// still-live child record.
    mutating func releaseChildToPrimary(sessionID: String, childOwnerKey: String) {
        guard ownerKeysBySessionID[sessionID] == childOwnerKey else { return }
        ownerKeysBySessionID[sessionID] = Self.primaryOwnerKey
        retiredChildPrimaryOwnerships[sessionID] = RetiredChildPrimaryOwnership(primaryEpochAtRelease: knownPrimaryEpoch)
    }

    /// Records the epoch and owner of a bootstrap snapshot. `isOwnChildSession`
    /// is true when a child connection reports the session it was spawned for.
    mutating func recordSnapshot(sessionID: String, epoch: String, ownerKey: String, isOwnChildSession: Bool) -> SnapshotOutcome {
        guard var expectation = bootstrapExpectations[ownerKey],
              expectation.connectionGeneration == connectionGenerations[ownerKey]
        else { return .noCurrentBootstrap }
        if let expectedEpoch = expectation.epoch, expectedEpoch != epoch {
            expectation.failed = true
            bootstrapExpectations[ownerKey] = expectation
            return .epochMismatch
        }
        expectation.epoch = epoch
        bootstrapExpectations[ownerKey] = expectation
        if ownerKey == Self.primaryOwnerKey {
            knownPrimaryEpoch = epoch
        }
        // Owners are assigned by the source connection, never inferred from an
        // ID that a child happens to report. Do not silently transfer one.
        guard ownerKeysBySessionID[sessionID] == nil || ownerKeysBySessionID[sessionID] == ownerKey else { return .ownedElsewhere }
        ownerKeysBySessionID[sessionID] = ownerKey
        if isOwnChildSession {
            sessionProducingConnections.insert(ConnectionKey(ownerKey: ownerKey, connectionGeneration: expectation.connectionGeneration))
        }
        return .accepted
    }

    /// Validates a bootstrap completion against the current generation and epoch,
    /// then computes which of this owner's records the completed index no longer
    /// lists. `childIsLive` reports whether the router still holds a live,
    /// non-retired child connection for a child owner; primary passes `true`.
    /// `additionalOwnedSessionIDs` lets the router include records it tracks
    /// outside this ledger under the same owner.
    mutating func acceptCompletion(
        ownerKey: String,
        bootstrapID: String,
        epoch: String,
        membership: Set<String>,
        childIsLive: Bool,
        additionalOwnedSessionIDs: Set<String> = []
    ) -> CompletionOutcome {
        guard let expectation = bootstrapExpectations[ownerKey],
              expectation.connectionGeneration == connectionGenerations[ownerKey],
              expectation.bootstrapID == bootstrapID,
              !expectation.failed
        else { return .discard(reason: "stale or bootstrapId mismatch") }
        guard expectation.epoch == nil || expectation.epoch == epoch else {
            return .discard(reason: "epoch mismatch")
        }
        let key = CompletionKey(ownerKey: ownerKey, connectionGeneration: expectation.connectionGeneration, bootstrapID: bootstrapID, epoch: epoch)
        guard acceptedCompletions.insert(key).inserted else {
            return .discard(reason: "duplicate")
        }
        let isPrimary = ownerKey == Self.primaryOwnerKey
        if !isPrimary {
            let producedSnapshot = sessionProducingConnections.contains(ConnectionKey(ownerKey: ownerKey, connectionGeneration: expectation.connectionGeneration))
            guard childIsLive, producedSnapshot else { return .acceptedWithoutReconcile }
        } else {
            knownPrimaryEpoch = epoch
        }
        let ownedIDs = sessionIDs(ownedBy: ownerKey).union(additionalOwnedSessionIDs)
        var removed = ownedIDs.subtracting(membership)
        if isPrimary {
            removed.subtract(retiredChildIDsAwaitingPrimaryEpochChange(completionEpoch: epoch))
            retiredChildPrimaryOwnerships = retiredChildPrimaryOwnerships.filter { $0.value.primaryEpochAtRelease == epoch }
        }
        return .reconcile(removedSessionIDs: removed)
    }

    private func retiredChildIDsAwaitingPrimaryEpochChange(completionEpoch: String) -> Set<String> {
        Set(retiredChildPrimaryOwnerships.compactMap { sessionID, ownership in
            guard let releaseEpoch = ownership.primaryEpochAtRelease, releaseEpoch != completionEpoch else { return sessionID }
            return nil
        })
    }
}
