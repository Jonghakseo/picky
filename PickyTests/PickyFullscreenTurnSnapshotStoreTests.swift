//
//  PickyFullscreenTurnSnapshotStoreTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenTurnSnapshotStore")
struct PickyFullscreenTurnSnapshotStoreTests {
    @MainActor
    @Test func recordsFetchesAndClearsSnapshots() {
        let store = PickyFullscreenTurnSnapshotStore()
        let snapshot = PickyFullscreenTurnGitSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1),
            headSHA: "head",
            worktreeSHA: "worktree"
        )

        store.record(sessionID: "session-1", turnID: "turn-1", snapshot: snapshot)

        #expect(store.snapshot(sessionID: "session-1", turnID: "turn-1") == snapshot)
        #expect(store.snapshot(sessionID: "session-1", turnID: "missing") == nil)
        store.clear(sessionID: "session-1")
        #expect(store.snapshot(sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test func effectiveRefPrefersWorktreeSnapshot() {
        let withWorktree = PickyFullscreenTurnGitSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1),
            headSHA: "head",
            worktreeSHA: "worktree"
        )
        let withoutWorktree = PickyFullscreenTurnGitSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1),
            headSHA: "head",
            worktreeSHA: nil
        )

        #expect(withWorktree.effectiveRef == "worktree")
        #expect(withoutWorktree.effectiveRef == "head")
    }
}
