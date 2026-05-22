//
//  PickyDiffReviewPromptTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("Diff review prompt")
struct PickyDiffReviewPromptTests {
    @Test func emptyPayloadProducesHeaderOnlyPrompt() {
        let prompt = PickyDiffReviewPrompt.compose(files: [], payload: payload())

        #expect(prompt == "Please address the following feedback")
    }

    @Test func overallCommentOnly() {
        let prompt = PickyDiffReviewPrompt.compose(files: [], payload: payload(overallComment: "  Looks good except tests.  "))

        #expect(prompt == """
        Please address the following feedback

        Looks good except tests.
        """)
    }

    @Test func singleFileCommentWithNoLineRangeUsesFileLocation() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", side: .file, body: "  Please review this file.  ")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [branch diff] src/App.swift
           Please review this file.
        """)
    }

    @Test func branchScopeFileCommentWithLineRangeUsesNewSuffix() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift", displayPath: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", side: .modified, startLine: 10, endLine: 12, body: "Tighten this logic.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [branch diff] src/App.swift:10-12 (new)
           Tighten this logic.
        """)
    }

    @Test func branchScopeOriginalSideUsesOldSuffix() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", side: .original, startLine: 4, body: "Old side issue.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [branch diff] src/App.swift:4 (old)
           Old side issue.
        """)
    }

    @Test func branchScopeModifiedSideUsesNewSuffix() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", side: .modified, startLine: 7, body: "New side issue.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [branch diff] src/App.swift:7 (new)
           New side issue.
        """)
    }

    @Test func commitsScopeWorkingTreeCommitUsesWorkingTreeLabel() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", scope: .commits, commitSha: PickyDiffReviewGit.workingTreeCommitSha, commitShort: "WT", commitKind: .workingTree, side: .modified, startLine: 2, body: "Fix uncommitted change.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [working tree changes] src/App.swift:2 (new)
           Fix uncommitted change.
        """)
    }

    @Test func commitsScopeCommitWithShortShaUsesCommitLabel() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", scope: .commits, commitSha: "abcdef123", commitShort: "abcdef1", commitKind: .commit, side: .modified, startLine: 3, body: "Fix committed change.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [commit abcdef1] src/App.swift:3 (new)
           Fix committed change.
        """)
    }

    @Test func allScopeFileWithLineRangeHasNoSideSuffix() {
        let prompt = PickyDiffReviewPrompt.compose(
            files: [file(id: "f1", path: "src/App.swift")],
            payload: payload(comments: [comment(fileId: "f1", scope: .all, side: .modified, startLine: 20, endLine: 22, body: "All files note.")])
        )

        #expect(prompt == """
        Please address the following feedback

        1. [all files] src/App.swift:20-22
           All files note.
        """)
    }

    @Test func hasFeedbackMatrix() {
        #expect(PickyDiffReviewPrompt.hasFeedback(payload()) == false)
        #expect(PickyDiffReviewPrompt.hasFeedback(payload(comments: [comment(body: "")])) == false)
        #expect(PickyDiffReviewPrompt.hasFeedback(payload(overallComment: " summary ")) == true)
        #expect(PickyDiffReviewPrompt.hasFeedback(payload(comments: [comment(body: " body ")])) == true)
        #expect(PickyDiffReviewPrompt.hasFeedback(payload(overallComment: "   ", comments: [comment(body: " \n ")])) == false)
    }

    private func payload(overallComment: String = "", comments: [DiffReviewComment] = []) -> PickyDiffReviewPrompt.SubmitPayload {
        PickyDiffReviewPrompt.SubmitPayload(overallComment: overallComment, comments: comments)
    }

    private func comment(
        fileId: String = "f1",
        scope: ReviewScope = .branch,
        commitSha: String? = nil,
        commitShort: String? = nil,
        commitKind: ReviewCommitKind? = nil,
        side: CommentSide = .file,
        startLine: Int? = nil,
        endLine: Int? = nil,
        body: String
    ) -> DiffReviewComment {
        DiffReviewComment(
            id: UUID().uuidString,
            fileId: fileId,
            scope: scope,
            commitSha: commitSha,
            commitShort: commitShort,
            commitKind: commitKind,
            side: side,
            startLine: startLine,
            endLine: endLine,
            body: body
        )
    }

    private func file(id: String, path: String, displayPath: String? = nil) -> ReviewFile {
        ReviewFile(
            id: id,
            path: path,
            worktreeStatus: nil,
            hasWorkingTreeFile: true,
            inGitDiff: true,
            gitDiff: displayPath.map {
                ReviewFileComparison(
                    status: .modified,
                    oldPath: path,
                    newPath: path,
                    displayPath: $0,
                    hasOriginal: true,
                    hasModified: true
                )
            },
            kind: .text,
            mimeType: nil
        )
    }
}
