import Foundation
import Testing
@testable import Picky

struct PickyProjectionOwnershipLedgerTests {
    private let primary = PickyProjectionOwnershipLedger.primaryOwnerKey
    private let child = "child:pickle-1"

    private func bootstrappedLedger(primaryEpoch: String = "epoch-1") -> PickyProjectionOwnershipLedger {
        var ledger = PickyProjectionOwnershipLedger()
        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-1")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: primaryEpoch, ownerKey: primary, isOwnChildSession: false) == .accepted)
        #expect(ledger.recordSnapshot(sessionID: "s-2", epoch: primaryEpoch, ownerKey: primary, isOwnChildSession: false) == .accepted)
        return ledger
    }

    @Test func primaryCompletionPrunesOnlyRecordsItOwnsAndNoLongerLists() {
        var ledger = bootstrappedLedger()
        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child")
        #expect(ledger.recordSnapshot(sessionID: "pickle-1", epoch: "epoch-child", ownerKey: child, isOwnChildSession: true) == .accepted)

        let outcome = ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-1", membership: ["s-1"], childIsLive: true)

        #expect(outcome == .reconcile(removedSessionIDs: ["s-2"]))
        #expect(ledger.ownerKey(for: "pickle-1") == child)
    }

    @Test func childCannotClaimASessionAnotherConnectionOwns() {
        var ledger = bootstrappedLedger()
        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child")

        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-child", ownerKey: child, isOwnChildSession: false) == .ownedElsewhere)
        #expect(ledger.ownerKey(for: "s-1") == primary)
    }

    @Test func staleDuplicateAndEpochMismatchedCompletionsAreDiscarded() {
        var ledger = bootstrappedLedger()

        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-0", epoch: "epoch-1", membership: [], childIsLive: true) == .discard(reason: "stale or bootstrapId mismatch"))
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-other", membership: [], childIsLive: true) == .discard(reason: "epoch mismatch"))
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-1", membership: ["s-1", "s-2"], childIsLive: true) == .reconcile(removedSessionIDs: []))
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-1", membership: ["s-1", "s-2"], childIsLive: true) == .discard(reason: "duplicate"))
    }

    @Test func bootstrapObservingTwoEpochsIsPoisonedUntilReconnect() {
        var ledger = PickyProjectionOwnershipLedger()
        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-1")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-1", ownerKey: primary, isOwnChildSession: false) == .accepted)
        #expect(ledger.recordSnapshot(sessionID: "s-2", epoch: "epoch-2", ownerKey: primary, isOwnChildSession: false) == .epochMismatch)

        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-1", membership: [], childIsLive: true) == .discard(reason: "stale or bootstrapId mismatch"))

        // The mismatched snapshot never assigned ownership, so a later index
        // that omits it has nothing of ours to prune.
        #expect(ledger.sessionIDs(ownedBy: primary) == ["s-1"])
        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-2")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-2", ownerKey: primary, isOwnChildSession: false) == .accepted)
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-2", epoch: "epoch-2", membership: [], childIsLive: true) == .reconcile(removedSessionIDs: ["s-1"]))
    }

    @Test func childCompletionIsNotDestructiveBeforeItsOwnSnapshotOrAfterRetirement() {
        var ledger = PickyProjectionOwnershipLedger()
        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child")

        // Empty index before the child's first scoped snapshot: correlate only.
        #expect(ledger.acceptCompletion(ownerKey: child, bootstrapID: "boot-child", epoch: "epoch-child", membership: [], childIsLive: true) == .acceptedWithoutReconcile)

        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child-2")
        #expect(ledger.recordSnapshot(sessionID: "pickle-1", epoch: "epoch-child", ownerKey: child, isOwnChildSession: true) == .accepted)
        // A retired child (router reports it is no longer live) may not prune either.
        #expect(ledger.acceptCompletion(ownerKey: child, bootstrapID: "boot-child-2", epoch: "epoch-child", membership: [], childIsLive: false) == .acceptedWithoutReconcile)
    }

    @Test func releasedChildSurvivesPrimaryReconnectUntilTheEpochChanges() {
        var ledger = bootstrappedLedger()
        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child")
        #expect(ledger.recordSnapshot(sessionID: "pickle-1", epoch: "epoch-child", ownerKey: child, isOwnChildSession: true) == .accepted)

        ledger.releaseChildToPrimary(sessionID: "pickle-1", childOwnerKey: child)
        #expect(ledger.ownerKey(for: "pickle-1") == primary)

        // Same-process socket reconnect: the primary index does not list the
        // released child yet, but the epoch is unchanged, so it is retained.
        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-2")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-1", ownerKey: primary, isOwnChildSession: false) == .accepted)
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-2", epoch: "epoch-1", membership: ["s-1", "s-2"], childIsLive: true) == .reconcile(removedSessionIDs: []))

        // Daemon restart: a new epoch proves the shared store was rehydrated,
        // so a missing released child is now pruned.
        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-3")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-2", ownerKey: primary, isOwnChildSession: false) == .accepted)
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-3", epoch: "epoch-2", membership: ["s-1", "s-2"], childIsLive: true) == .reconcile(removedSessionIDs: ["pickle-1"]))
    }

    @Test func respawnedChildRegainsOwnershipAndClearsTheReleaseGuard() {
        var ledger = bootstrappedLedger()
        ledger.beginBootstrap(ownerKey: child, bootstrapID: "boot-child")
        #expect(ledger.recordSnapshot(sessionID: "pickle-1", epoch: "epoch-child", ownerKey: child, isOwnChildSession: true) == .accepted)
        ledger.releaseChildToPrimary(sessionID: "pickle-1", childOwnerKey: child)

        ledger.assignChildOwnership(sessionID: "pickle-1", childOwnerKey: child)
        #expect(ledger.ownerKey(for: "pickle-1") == child)

        ledger.beginBootstrap(ownerKey: primary, bootstrapID: "boot-2")
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-1", ownerKey: primary, isOwnChildSession: false) == .accepted)
        // The child owns the record again, so a primary index that omits it cannot prune it.
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-2", epoch: "epoch-1", membership: ["s-1", "s-2"], childIsLive: true) == .reconcile(removedSessionIDs: []))
    }

    @Test func disconnectKeepsOwnershipButDropsPerConnectionCorrelation() {
        var ledger = bootstrappedLedger()
        ledger.disconnectAll()

        #expect(ledger.ownerKey(for: "s-1") == primary)
        #expect(ledger.recordSnapshot(sessionID: "s-1", epoch: "epoch-1", ownerKey: primary, isOwnChildSession: false) == .noCurrentBootstrap)
        #expect(ledger.acceptCompletion(ownerKey: primary, bootstrapID: "boot-1", epoch: "epoch-1", membership: [], childIsLive: true) == .discard(reason: "stale or bootstrapId mismatch"))
    }
}
