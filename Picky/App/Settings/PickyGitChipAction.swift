//
//  PickyGitChipAction.swift
//  Picky
//
//  User-defined click action for the git chips (insertions/deletions, branch
//  label) rendered in the Pickle conversation card. Stored on `PickySettings`
//  and executed by `PickyGitChipActionRunner` when the user clicks a chip.
//

import Foundation

/// Which surface the saved command should drop into when the user clicks a
/// git chip. `pi` mirrors the `/name <new>` rename path: the command is sent
/// to the chip's Pickle as `steer` or `followUp` based on the session status.
/// `shell` runs the command verbatim from the Pickle's cwd via `/bin/sh -lc`.
enum PickyGitChipActionKind: String, Codable, Equatable, CaseIterable {
    case pi
    case shell
}

/// Single command attached to a git chip. A nil `PickyGitChipAction` (or an
/// empty `command`) means the user has not configured this chip yet; the click
/// handler deep-links them to Settings → Pickle so they can fill it in.
struct PickyGitChipAction: Codable, Equatable {
    var kind: PickyGitChipActionKind
    var command: String

    /// `true` once the user has stored a non-empty command. Empty drafts are
    /// persisted as `nil` at the `PickyGitChipActions` level, so this is just
    /// a defensive guard for paths that bypass the settings store.
    var isConfigured: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One slot per chip group: `diffAction` is shared by the `+N` and `-N`
/// metrics (they live in the same row and represent the same change set);
/// `branchAction` is the branch label. Both default to `nil` so a fresh
/// install does nothing on click (the deep link surfaces Settings).
struct PickyGitChipActions: Codable, Equatable {
    var diffAction: PickyGitChipAction?
    var branchAction: PickyGitChipAction?

    static let empty = PickyGitChipActions(diffAction: nil, branchAction: nil)
}
