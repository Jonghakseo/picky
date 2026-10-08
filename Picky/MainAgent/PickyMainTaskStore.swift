//
//  PickyMainTaskStore.swift
//  Picky
//
//  Owner of the main Picky agent's Task and delegation-decision snapshot as
//  reported by picky-agentd, plus the two user controls that act on it.
//  CompanionManager applies `mainTasksUpdated` here and injects `send`.
//
//  Separate from `PickyMainAgentActivityStore` on purpose: an activity chip
//  belongs to the current reply and disappears with it, while a Task keeps
//  running after Picky finishes speaking.
//
//  The daemon is the only writer of Task state: a control command never mutates
//  the snapshot optimistically, it waits for the next broadcast. On disconnect
//  the last snapshot stays on screen and is replaced wholesale on reconnect.
//

import Combine
import Foundation

@MainActor
final class PickyMainTaskStore: ObservableObject {
    typealias CommandSender = @MainActor (PickyCommandEnvelope) async throws -> PickyErrorEvent?

    @Published private(set) var snapshot = PickyMainTasksSnapshot.empty
    /// Task and decision ids with a control command in flight, so a row can
    /// show progress and refuse a second click until the daemon answers.
    @Published private(set) var pendingCommandIDs: Set<String> = []
    /// Last control failure, surfaced inline next to the section.
    @Published private(set) var commandError: String?

    /// Set by CompanionManager; nil in previews and unit tests that only check state.
    var send: CommandSender?

    func apply(_ snapshot: PickyMainTasksSnapshot) {
        self.snapshot = snapshot
    }

    func isPending(_ id: String) -> Bool {
        pendingCommandIDs.contains(id)
    }

    func control(taskID: String, action: PickyMainTaskControlAction) async {
        await perform(id: taskID, command: .controlMainTask(taskId: taskID, action: action))
    }

    func resolve(decisionID: String, choice: PickyMainDelegationChoice) async {
        await perform(id: decisionID, command: .resolveMainDelegation(decisionId: decisionID, choice: choice))
    }

    func clearCommandError() {
        commandError = nil
    }

    private func perform(id: String, command: PickyCommandEnvelope) async {
        guard let send, !pendingCommandIDs.contains(id) else { return }
        pendingCommandIDs.insert(id)
        commandError = nil
        defer { pendingCommandIDs.remove(id) }
        do {
            if let error = try await send(command) { commandError = error.message }
        } catch {
            commandError = L10n.t("hub.tasks.error.commandFailed")
        }
    }
}
