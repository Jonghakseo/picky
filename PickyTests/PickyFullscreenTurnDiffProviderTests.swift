//
//  PickyFullscreenTurnDiffProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenTurnDiffProvider")
struct PickyFullscreenTurnDiffProviderTests {
    @Test func parsesNameStatusOutput() {
        let output = """
        A\tdocs/new.md
        M\tPicky/Fullscreen/View.swift
        D\told.txt
        R100\tbefore.md\tafter.md
        """

        let parsed = PickyFullscreenTurnDiffProvider.parseNameStatus(output)

        #expect(parsed == [
            PickyChangedFile(path: "docs/new.md", status: "added", summary: nil),
            PickyChangedFile(path: "Picky/Fullscreen/View.swift", status: "modified", summary: nil),
            PickyChangedFile(path: "old.txt", status: "deleted", summary: nil),
            PickyChangedFile(path: "after.md", status: "renamed", summary: nil)
        ])
    }

    @MainActor
    @Test func nonGitCwdReturnsEmptyResultsGracefully() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyFullscreenTurnDiffProviderTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = PickyFullscreenTurnDiffProvider(cwd: directory.path)

        await provider.fetchDiff(turnID: "turn-1", startRef: "HEAD", endRef: "HEAD")

        #expect(provider.diffsByTurnID["turn-1"] == [])
    }

    @MainActor
    @Test func fetchLastTurnDiffUsesFreshWorktreeSnapshot() async {
        let provider = PickyFullscreenTurnDiffProvider(cwd: "/tmp/repo") { arguments, _ in
            if arguments == ["rev-parse", "HEAD"] { return "head\n" }
            if arguments == ["stash", "create", "--include-untracked"] { return "worktree\n" }
            if arguments == ["diff", "start..worktree", "--name-status"] { return "M\tfile.swift\n" }
            return nil
        }

        await provider.fetchLastTurnDiff(turnID: "turn-1", startRef: "start")

        #expect(provider.diffsByTurnID["turn-1"] == [
            PickyChangedFile(path: "file.swift", status: "modified", summary: nil)
        ])
    }
}
