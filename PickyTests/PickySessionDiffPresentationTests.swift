//
//  PickySessionDiffPresentationTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickySessionDiffPresentationTests {
    @Test func statusPresentationUsesGitLettersAndSemanticTones() {
        #expect(PickySessionDiffPresentation.statusLetter(for: .modified) == "M")
        #expect(PickySessionDiffPresentation.statusLetter(for: .untracked) == "?")
        #expect(PickySessionDiffPresentation.statusTone(for: .added) == .added)
        #expect(PickySessionDiffPresentation.statusTone(for: .deleted) == .deleted)
    }

    @Test func badgeCountIsVisibleOnlyAfterAGitResultArrives() {
        #expect(PickySessionDiffPresentation.badgeCount(for: .requesting(view: .unstaged, requestID: "request-1")) == nil)

        let state = PickySessionDiffState.reducing(
            current: .requesting(view: .unstaged, requestID: "request-1"),
            result: result(requestID: "request-1", files: [file(path: "Picky/App.swift")])
        )
        #expect(PickySessionDiffPresentation.badgeCount(for: state) == 1)
    }

    @Test func reducerAcceptsOnlyTheActiveRequestIDAndView() {
        let current = PickySessionDiffState.requesting(view: .staged, requestID: "request-staged")

        #expect(
            PickySessionDiffState.reducing(
                current: current,
                result: result(view: .unstaged, requestID: "request-staged")
            ) == current
        )
        #expect(
            PickySessionDiffState.reducing(
                current: current,
                result: result(view: .staged, requestID: "request-older")
            ) == current
        )

        let settled = PickySessionDiffState.reducing(
            current: current,
            result: result(view: .staged, requestID: "request-staged")
        )
        #expect(PickySessionDiffState.reducing(current: settled, result: result(view: .staged, requestID: "request-staged")) == settled)
    }

    @Test func renderedDiffLinesCapLargeFilesAndUseStructuredTruncation() {
        let diff = (0...PickySessionDiffPresentation.maximumRenderedLinesPerFile)
            .map { "+line \($0)" }
            .joined(separator: "\n")

        #expect(PickySessionDiffPresentation.renderedLines(for: diff).count == PickySessionDiffPresentation.maximumRenderedLinesPerFile)
        #expect(PickySessionDiffPresentation.shouldShowTruncationFootnote(for: file(path: "large.swift", diff: diff)))
        #expect(PickySessionDiffPresentation.shouldShowTruncationFootnote(for: file(path: "capped.swift", truncated: true)))
        #expect(PickySessionDiffPresentation.lineKind(for: "@@ -1 +1 @@") == .hunk)
        #expect(PickySessionDiffPresentation.lineKind(for: "+added") == .addition)
        #expect(PickySessionDiffPresentation.lineKind(for: "-removed") == .deletion)
    }

    private func file(path: String, diff: String = "+added", truncated: Bool = false) -> PickySessionDiffFile {
        PickySessionDiffFile(
            path: path,
            status: .modified,
            renamedFrom: nil,
            additions: 1,
            deletions: 0,
            diff: diff,
            truncated: truncated
        )
    }

    private func result(
        view: PickySessionDiffView = .unstaged,
        requestID: String,
        files: [PickySessionDiffFile] = []
    ) -> PickySessionDiffResult {
        PickySessionDiffResult(
            sessionId: "session-1",
            view: view,
            isGitRepo: true,
            files: files,
            filesTruncated: false,
            errorMessage: nil,
            requestID: requestID
        )
    }
}
