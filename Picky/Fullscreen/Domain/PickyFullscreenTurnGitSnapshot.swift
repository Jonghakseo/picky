//
//  PickyFullscreenTurnGitSnapshot.swift
//  Picky
//
//  Git boundary snapshot for fullscreen turn-scoped changed files.
//

import Foundation

struct PickyFullscreenTurnGitSnapshot: Equatable {
    let capturedAt: Date
    let headSHA: String
    let worktreeSHA: String?

    var effectiveRef: String {
        worktreeSHA?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? worktreeSHA! : headSHA
    }
}
