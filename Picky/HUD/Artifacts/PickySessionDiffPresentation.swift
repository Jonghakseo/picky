//
//  PickySessionDiffPresentation.swift
//  Picky
//
//  Pure presentation and state-reduction policies for session git diffs.
//

import Foundation

enum PickySessionDiffStatusTone: Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
}

enum PickySessionDiffLineKind: Equatable {
    case addition
    case deletion
    case hunk
    case context
}

enum PickySessionDiffPresentation {
    static let maximumRenderedLinesPerFile = 1_200

    static func statusLetter(for status: PickySessionDiffFile.Status) -> String {
        switch status {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "?"
        }
    }

    static func statusTone(for status: PickySessionDiffFile.Status) -> PickySessionDiffStatusTone {
        switch status {
        case .added: .added
        case .modified: .modified
        case .deleted: .deleted
        case .renamed: .renamed
        case .untracked: .untracked
        }
    }

    static func badgeCount(for state: PickySessionDiffState) -> Int? {
        guard state.hasReceivedResult, state.isGitRepo else { return nil }
        return state.files.count
    }

    static func lineKind(for line: String) -> PickySessionDiffLineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .addition }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .deletion }
        return .context
    }

    static func renderedLines(for diff: String) -> [String] {
        Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(maximumRenderedLinesPerFile)).map(String.init)
    }

    static func shouldShowTruncationFootnote(for file: PickySessionDiffFile) -> Bool {
        file.truncated
            || file.diff.split(separator: "\n", omittingEmptySubsequences: false).count > maximumRenderedLinesPerFile
    }

    static func isSettledTransition(from previous: PickySessionStatus?, to next: PickySessionStatus) -> Bool {
        guard previous == .running else { return false }
        return next != .running
    }
}

struct PickySessionDiffState: Equatable {
    var view: PickySessionDiffView = .unstaged
    var isGitRepo = true
    var files: [PickySessionDiffFile] = []
    var isLoading = false
    var errorMessage: String?
    var requestID: String?
    var hasReceivedResult = false
    var filesTruncated = false

    static func requesting(view: PickySessionDiffView, requestID: String) -> Self {
        Self(
            view: view,
            isGitRepo: true,
            files: [],
            isLoading: true,
            errorMessage: nil,
            requestID: requestID,
            hasReceivedResult: false,
            filesTruncated: false
        )
    }

    static func reducing(current: Self, result: PickySessionDiffResult) -> Self {
        guard result.view == current.view,
              let requestID = current.requestID,
              result.requestID == requestID else { return current }
        return Self(
            view: result.view,
            isGitRepo: result.isGitRepo,
            files: result.files,
            isLoading: false,
            errorMessage: result.errorMessage,
            requestID: nil,
            hasReceivedResult: true,
            filesTruncated: result.filesTruncated
        )
    }
}
