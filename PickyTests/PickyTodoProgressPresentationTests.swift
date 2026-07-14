//
//  PickyTodoProgressPresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyTodoProgressPresentationTests {
    @Test func emptyTodoStateKeepsExistingHUDPathUnchanged() {
        let state = PickyTodoState(tasks: [], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(PickyTodoProgressPresentation(state: state) == nil)
    }

    @Test func activeFormDrivesCompactAndExpandedCurrentTaskText() throws {
        let state = PickyTodoState(
            tasks: [
                PickyTodoTask(id: "todo-1", content: "Inspect protocol", status: .completed),
                PickyTodoTask(
                    id: "todo-2",
                    content: "Implement HUD",
                    status: .inProgress,
                    activeForm: "Implementing HUD"
                ),
                PickyTodoTask(id: "todo-3", content: "Run tests", status: .pending),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )

        let presentation = try #require(PickyTodoProgressPresentation(state: state))

        #expect(presentation.completedCount == 1)
        #expect(presentation.totalCount == 3)
        #expect(presentation.fraction == 1.0 / 3.0)
        #expect(presentation.activeText == "Implementing HUD")
        #expect(presentation.isComplete == false)
    }

    @Test func contentIsUsedWhenActiveFormIsMissing() throws {
        let state = PickyTodoState(
            tasks: [PickyTodoTask(id: "todo-1", content: "Run tests", status: .inProgress)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_002)
        )

        let presentation = try #require(PickyTodoProgressPresentation(state: state))

        #expect(presentation.activeText == "Run tests")
    }

    @Test func expandedListOnlyScrollsAfterSixTasks() throws {
        let threeTasks = PickyTodoState(
            tasks: (1...3).map { PickyTodoTask(id: "todo-\($0)", content: "Task \($0)", status: .pending) },
            updatedAt: Date(timeIntervalSince1970: 1_800_000_003)
        )
        let sevenTasks = PickyTodoState(
            tasks: (1...7).map { PickyTodoTask(id: "todo-\($0)", content: "Task \($0)", status: .pending) },
            updatedAt: Date(timeIntervalSince1970: 1_800_000_004)
        )

        #expect(try #require(PickyTodoProgressPresentation(state: threeTasks)).usesScrollableExpandedList == false)
        #expect(try #require(PickyTodoProgressPresentation(state: sevenTasks)).usesScrollableExpandedList)
    }

    @Test func daemonSessionUpdateCanAuthoritativelyClearTodoState() {
        let todoState = PickyTodoState(
            tasks: [PickyTodoTask(id: "todo-1", content: "Implement HUD", status: .inProgress)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_003)
        )
        let existing = PickySessionListViewModel.SessionCard.fromAgentSession(agentSession(todoState: todoState))
        let incoming = PickySessionListViewModel.SessionCard.fromAgentSession(agentSession(todoState: nil))

        let merged = existing.merged(with: incoming, preserveConversationState: true)

        #expect(merged.todoState == nil)
    }

    @Test func completedStateUsesLastTaskAsStableSummary() throws {
        let state = PickyTodoState(
            tasks: [
                PickyTodoTask(id: "todo-1", content: "Implement HUD", status: .completed),
                PickyTodoTask(id: "todo-2", content: "Run tests", status: .completed),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_003)
        )

        let presentation = try #require(PickyTodoProgressPresentation(state: state))

        #expect(presentation.completedCount == 2)
        #expect(presentation.totalCount == 2)
        #expect(presentation.fraction == 1)
        #expect(presentation.activeText == "Run tests")
        #expect(presentation.isComplete)
    }

    private func agentSession(todoState: PickyTodoState?) -> PickyAgentSession {
        PickyAgentSession(
            id: "session-todo",
            title: "Todo session",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010),
            logs: [],
            tools: [],
            todoState: todoState,
            artifacts: [],
            changedFiles: []
        )
    }
}
