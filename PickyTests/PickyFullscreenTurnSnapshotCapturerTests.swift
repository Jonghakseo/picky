//
//  PickyFullscreenTurnSnapshotCapturerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenTurnSnapshotCapturer")
struct PickyFullscreenTurnSnapshotCapturerTests {
    @MainActor
    @Test func capturesHeadAndWorktreeSnapshot() async {
        let store = PickyFullscreenTurnSnapshotStore()
        let capturer = PickyFullscreenTurnSnapshotCapturer(cwd: "/tmp/repo", store: store) { arguments, _ in
            if arguments == ["rev-parse", "HEAD"] { return "head\n" }
            if arguments == ["stash", "create", "--include-untracked"] { return "worktree\n" }
            return nil
        }

        await capturer.captureBoundary(sessionID: "session-1", turnID: "turn-1")

        let snapshot = store.snapshot(sessionID: "session-1", turnID: "turn-1")
        #expect(snapshot?.headSHA == "head")
        #expect(snapshot?.worktreeSHA == "worktree")
        #expect(snapshot?.effectiveRef == "worktree")
    }

    @MainActor
    @Test func emptyStashCreateFallsBackToHead() async {
        let snapshot = await PickyFullscreenTurnSnapshotCapturer.captureSnapshot(cwd: "/tmp/repo") { arguments, _ in
            if arguments == ["rev-parse", "HEAD"] { return "head\n" }
            if arguments == ["stash", "create", "--include-untracked"] { return "\n" }
            return nil
        }

        #expect(snapshot?.headSHA == "head")
        #expect(snapshot?.worktreeSHA == nil)
        #expect(snapshot?.effectiveRef == "head")
    }

    @MainActor
    @Test func failedHeadRecordsNothing() async {
        let store = PickyFullscreenTurnSnapshotStore()
        let capturer = PickyFullscreenTurnSnapshotCapturer(cwd: "/tmp/repo", store: store) { _, _ in nil }

        await capturer.captureBoundary(sessionID: "session-1", turnID: "turn-1")

        #expect(store.snapshot(sessionID: "session-1", turnID: "turn-1") == nil)
    }
}
