//
//  PickyDiffViewerTests.swift
//  PickyTests
//

import Foundation
import XCTest
@testable import Picky

final class PickyDiffViewerTests: XCTestCase {
    @MainActor
    func testCachedDiffSelectionInvalidatesInFlightDiffLoad() async throws {
        let fileA = PickyGitDiffFile(
            id: "branch::modified::a.txt",
            path: "a.txt",
            oldPath: nil,
            newPath: "a.txt",
            displayPath: "a.txt",
            status: .modified,
            insertions: 1,
            deletions: 1
        )
        let fileB = PickyGitDiffFile(
            id: "branch::modified::b.txt",
            path: "b.txt",
            oldPath: nil,
            newPath: "b.txt",
            displayPath: "b.txt",
            status: .modified,
            insertions: 2,
            deletions: 0
        )
        let data = PickyGitDiffViewerData(
            repoRoot: "/tmp/repo",
            repositoryName: "repo",
            branchName: "feature/test",
            branchBaseRef: "origin/main",
            branchMergeBaseSha: "abc123",
            repositoryHasHead: true,
            scopes: [
                PickyGitDiffScopeData(
                    scope: .branch,
                    baseLabel: "origin/main",
                    targetLabel: "Working tree",
                    files: [fileA, fileB],
                    insertions: 3,
                    deletions: 1
                ),
                PickyGitDiffScopeData(
                    scope: .worktree,
                    baseLabel: "HEAD",
                    targetLabel: "Working tree",
                    files: [],
                    insertions: 0,
                    deletions: 0
                )
            ]
        )
        let provider = PickyDiffViewerFakeProvider(data: data, immediateDiffs: [fileB.id: "cached B diff"])
        let model = PickyDiffViewerModel(title: "Diff", cwd: "/tmp/repo", initialScope: .branch, provider: provider)

        let loadedInitialFile = await waitUntil {
            let requestCount = await provider.requestCount(for: fileA.id)
            return model.selectedFileID == fileA.id && model.isLoadingDiff && requestCount == 1
        }
        XCTAssertTrue(loadedInitialFile)

        model.selectFile(fileB)
        let loadedCachedFile = await waitUntil {
            model.selectedFileID == fileB.id && model.unifiedDiff == "cached B diff" && !model.isLoadingDiff
        }
        XCTAssertTrue(loadedCachedFile)

        model.selectFile(fileA)
        let loadedSecondPendingFile = await waitUntil {
            let requestCount = await provider.requestCount(for: fileA.id)
            return model.selectedFileID == fileA.id && model.isLoadingDiff && requestCount == 2
        }
        XCTAssertTrue(loadedSecondPendingFile)

        model.selectFile(fileB)
        let reloadedCachedFile = await waitUntil {
            model.selectedFileID == fileB.id && model.unifiedDiff == "cached B diff" && !model.isLoadingDiff
        }
        XCTAssertTrue(reloadedCachedFile)

        await provider.completeAll(fileID: fileA.id, with: "stale A diff")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.selectedFileID, fileB.id)
        XCTAssertEqual(model.unifiedDiff, "cached B diff")
        XCTAssertFalse(model.isLoadingDiff)
    }

    func testUnifiedDiffLineKindsClassifyGitHeadersBeforeAdditionsAndDeletions() {
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "diff --git a/old.txt b/new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "--- a/old.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "+++ b/new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "rename from old.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "rename to new.txt"), .fileHeader)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "@@ -1,2 +1,2 @@"), .hunk)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "+added line"), .addition)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: "-deleted line"), .deletion)
        XCTAssertEqual(PickyDiffUnifiedDiffLine.kind(for: " unchanged line"), .context)
    }

    func testUnifiedDiffLinesPreserveOrderAndStableOffsets() {
        let lines = PickyDiffUnifiedDiffLine.lines(from: "@@ -1 +1 @@\n-old\n+new")

        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(lines.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(lines.map(\.text), ["@@ -1 +1 @@", "-old", "+new"])
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

private actor PickyDiffViewerFakeProvider: PickyGitDiffReviewProviding {
    private let data: PickyGitDiffViewerData
    private let immediateDiffs: [String: String]
    private var pendingContinuations: [String: [CheckedContinuation<String, Error>]] = [:]
    private var requestCounts: [String: Int] = [:]

    init(data: PickyGitDiffViewerData, immediateDiffs: [String: String]) {
        self.data = data
        self.immediateDiffs = immediateDiffs
    }

    func load(cwd: String) async throws -> PickyGitDiffViewerData {
        data
    }

    func loadDiff(cwd: String, scope: PickyGitDiffViewerScope, fileID: String) async throws -> String {
        requestCounts[fileID, default: 0] += 1
        if let diff = immediateDiffs[fileID] {
            return diff
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[fileID, default: []].append(continuation)
        }
    }

    func requestCount(for fileID: String) -> Int {
        requestCounts[fileID, default: 0]
    }

    func completeAll(fileID: String, with diff: String) {
        let continuations = pendingContinuations.removeValue(forKey: fileID) ?? []
        for continuation in continuations {
            continuation.resume(returning: diff)
        }
    }
}
