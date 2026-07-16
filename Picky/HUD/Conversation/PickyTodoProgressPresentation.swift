//
//  PickyTodoProgressPresentation.swift
//  Picky
//
//  Pure projection from daemon-authored todo state into compact HUD values.
//  Picky remains read-only: Pi and the todo_write extension own task mutation.
//

import Foundation

struct PickyTodoProgressSnapshotID: Equatable {
    let sessionID: String
    let updatedAt: Date
}

enum PickyTodoProgressOverlayPolicy {
    static func shouldShow(
        snapshotID: PickyTodoProgressSnapshotID,
        hiddenSnapshotID: PickyTodoProgressSnapshotID?
    ) -> Bool {
        snapshotID != hiddenSnapshotID
    }

    static func shouldCollapse(isComplete: Bool) -> Bool {
        isComplete
    }
}

struct PickyTodoProgressPresentation: Equatable {
    let tasks: [PickyTodoTask]
    let completedCount: Int
    let totalCount: Int
    let fraction: Double
    let activeText: String
    let isComplete: Bool
    let updatedAt: Date

    init?(state: PickyTodoState?) {
        guard let state, !state.tasks.isEmpty else { return nil }
        let completedCount = state.completedCount
        let isComplete = completedCount == state.tasks.count
        let activeTask = state.tasks.first { $0.status == .inProgress }
            ?? state.tasks.first { $0.status == .pending }
            ?? state.tasks.last
        guard let activeTask else { return nil }

        self.tasks = state.tasks
        self.completedCount = completedCount
        self.totalCount = state.tasks.count
        self.fraction = Double(completedCount) / Double(state.tasks.count)
        self.activeText = activeTask.displayText
        self.isComplete = isComplete
        self.updatedAt = state.updatedAt
    }

    var activeStepNumber: Int? {
        tasks.firstIndex(where: { $0.status == .inProgress }).map { $0 + 1 }
    }

    /// The compact count follows the current step while work is active, then
    /// falls back to completed work for pending/between-step/complete snapshots.
    var currentStepNumber: Int {
        activeStepNumber ?? completedCount
    }

    var countText: String {
        "\(currentStepNumber)/\(totalCount)"
    }

    /// Ordinal wording is reserved for an active task. Snapshots with no active
    /// task use completion wording, matching the adjacent completion ring.
    var stepText: String {
        if let activeStepNumber {
            return L10n.t("hud.todo.stepCount", Int64(activeStepNumber), Int64(totalCount))
        }
        return L10n.t("hud.todo.completedCount", Int64(completedCount), Int64(totalCount))
    }

    var usesScrollableExpandedList: Bool {
        tasks.count > 6
    }
}

extension PickyTodoTask {
    var displayText: String {
        if status == .inProgress,
           let activeForm,
           !activeForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activeForm
        }
        return content
    }
}
