//
//  PickyTodoProgressPresentation.swift
//  Picky
//
//  Pure projection from daemon-authored todo state into compact HUD values.
//  Picky remains read-only: Pi and the todo_write extension own task mutation.
//

import Foundation

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

    /// The compact label communicates which step the agent is currently on,
    /// while `fraction` remains completion-based for the progress ring.
    var currentStepNumber: Int {
        if let activeIndex = tasks.firstIndex(where: { $0.status == .inProgress }) {
            return activeIndex + 1
        }
        return completedCount
    }

    var countText: String {
        "\(currentStepNumber)/\(totalCount)"
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
