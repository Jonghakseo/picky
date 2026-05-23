//
//  PickyGitChipActionRunner.swift
//  Picky
//
//  Executes the user-configured git chip action when the user clicks an
//  insertions/deletions chip or the branch label in the Pickle conversation
//  card. Two modes are supported:
//
//   - `.pi`   — mirrors `/name <new>`: routed to `steer` (live session) or
//               `followUp` (terminal/blocked session) on the chip's Pickle.
//   - `.shell` — spawned with `/bin/sh -lc <command>` in the Pickle's cwd as a
//               detached, fire-and-forget process so GUI helpers like `open
//               -a Cursor .` return immediately and Picky doesn't block on
//               long-running launchers.
//
//  Failures from either branch surface as a macOS user notification with the
//  same shape as `deliverGitFailureNotification` (chip-row push/pull errors).
//

import AppKit
import Foundation
import UserNotifications

/// Routing decision derived from the Pickle's status. Mirrors the `/name`
/// rename branch in `PickyConversationHeaderView.sendRenameCommand` so chip
/// actions interrupt or queue based on the same contract.
enum PickyGitChipPiDestination: Equatable {
    case steer
    case followUp

    static func resolve(for status: PickySessionStatus) -> PickyGitChipPiDestination {
        switch status {
        case .completed, .blocked: .followUp
        case .queued, .running, .waiting_for_input, .cancelled, .failed: .steer
        }
    }
}

/// Protocol-of-one so unit tests can inject a recording double in place of
/// `PickySessionListViewModel`. Picky's view model already exposes both
/// methods with this exact signature, so the live conformance is one line.
@MainActor
protocol PickyGitChipActionViewModelDispatch: AnyObject {
    func followUp(text: String, sessionID: String?) async throws
    func steer(text: String, sessionID: String?) async throws
}

extension PickySessionListViewModel: PickyGitChipActionViewModelDispatch {}

/// Side-effect surface for the shell branch and failure delivery, factored
/// out so tests don't spawn real processes or post UNNotificationRequests.
@MainActor
struct PickyGitChipActionEnvironment {
    /// Runs the user's shell command from `cwd` in a detached process. The
    /// caller is responsible for catching synchronous launch failures and
    /// surfacing them via `deliverFailureNotification`.
    var runShell: (_ command: String, _ cwd: String) throws -> Void
    /// Posts a macOS notification with the chip-failure summary. Same shape
    /// as `deliverGitFailureNotification` so the user sees a consistent UI
    /// regardless of which path failed.
    var deliverFailureNotification: (_ title: String, _ message: String) -> Void

    static let live = PickyGitChipActionEnvironment(
        runShell: { command, cwd in
            let process = Process()
            process.launchPath = "/bin/sh"
            // `-l` gives the command a login shell so PATH/`open` aliases
            // behave the way users expect from Terminal.app; `-c` runs the
            // whole command verbatim so quoting/pipes are respected.
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            // Drop stdout/stderr so the parent doesn't hold pipes open and
            // we can fire-and-forget. Anything the user wants to see should
            // be routed through Pi instead.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
        },
        deliverFailureNotification: { title, message in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(message.prefix(280))
            content.sound = nil
            let request = UNNotificationRequest(identifier: "picky-git-chip-action-\(UUID().uuidString)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    )
}

@MainActor
enum PickyGitChipActionRunner {
    /// Run `action` for the chip on `sessionID` with `status`/`cwd`. Returns
    /// nothing — Pi dispatch errors and shell spawn errors are reported to
    /// the user through `environment.deliverFailureNotification`.
    static func run(
        action: PickyGitChipAction,
        sessionID: String,
        status: PickySessionStatus,
        cwd: String?,
        viewModel: PickyGitChipActionViewModelDispatch,
        environment: PickyGitChipActionEnvironment = .live
    ) async {
        let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            // Defensive: the click handler is supposed to skip nil/empty
            // actions and deep-link to Settings instead. If we ended up here
            // anyway, surface the misconfiguration rather than silently
            // doing nothing.
            environment.deliverFailureNotification(
                "Git chip action is empty",
                "Open Settings → Pickle to configure the command."
            )
            return
        }
        switch action.kind {
        case .pi:
            await runPiAction(command: command, sessionID: sessionID, status: status, viewModel: viewModel, environment: environment)
        case .shell:
            await runShellAction(command: command, cwd: cwd, environment: environment)
        }
    }

    private static func runPiAction(
        command: String,
        sessionID: String,
        status: PickySessionStatus,
        viewModel: PickyGitChipActionViewModelDispatch,
        environment: PickyGitChipActionEnvironment
    ) async {
        let destination = PickyGitChipPiDestination.resolve(for: status)
        do {
            switch destination {
            case .steer:
                try await viewModel.steer(text: command, sessionID: sessionID)
            case .followUp:
                try await viewModel.followUp(text: command, sessionID: sessionID)
            }
        } catch {
            environment.deliverFailureNotification(
                "Git chip action failed",
                error.localizedDescription
            )
        }
    }

    private static func runShellAction(
        command: String,
        cwd: String?,
        environment: PickyGitChipActionEnvironment
    ) async {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedCwd.isEmpty else {
            environment.deliverFailureNotification(
                "Git chip action failed",
                "This Pickle has no working directory, so the shell command cannot run."
            )
            return
        }
        do {
            try environment.runShell(command, trimmedCwd)
        } catch {
            environment.deliverFailureNotification(
                "Git chip action failed",
                error.localizedDescription
            )
        }
    }
}
