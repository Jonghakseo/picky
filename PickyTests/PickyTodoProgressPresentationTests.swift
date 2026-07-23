//
//  PickyTodoProgressPresentationTests.swift
//  PickyTests
//

import AppKit
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
        #expect(presentation.currentStepNumber == 2)
        #expect(presentation.countText == "2/3")
        #expect(presentation.stepText == L10n.t("hud.todo.stepCount", Int64(2), Int64(3)))
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

    @Test func firstInProgressTaskDisplaysOneOfTotalWhileCompletionRingStartsAtZero() throws {
        let state = PickyTodoState(
            tasks: [
                PickyTodoTask(id: "todo-1", content: "Prepare workspace", status: .inProgress),
                PickyTodoTask(id: "todo-2", content: "Implement", status: .pending),
                PickyTodoTask(id: "todo-3", content: "Verify", status: .pending),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_002)
        )

        let presentation = try #require(PickyTodoProgressPresentation(state: state))

        #expect(presentation.completedCount == 0)
        #expect(presentation.currentStepNumber == 1)
        #expect(presentation.countText == "1/3")
        #expect(presentation.stepText == L10n.t("hud.todo.stepCount", Int64(1), Int64(3)))
        #expect(presentation.fraction == 0)
    }

    @Test func entirelyPendingTodoStillDisplaysZeroOfTotal() throws {
        let state = PickyTodoState(
            tasks: [
                PickyTodoTask(id: "todo-1", content: "Prepare workspace", status: .pending),
                PickyTodoTask(id: "todo-2", content: "Implement", status: .pending),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_002)
        )

        let presentation = try #require(PickyTodoProgressPresentation(state: state))

        #expect(presentation.activeStepNumber == nil)
        #expect(presentation.currentStepNumber == 0)
        #expect(presentation.countText == "0/2")
        #expect(presentation.stepText == L10n.t("hud.todo.completedCount", Int64(0), Int64(2)))
    }

    @Test func expansionDefaultsToCurrentWorkExpandedAndCompletedWorkCollapsed() {
        #expect(PickyTodoProgressExpansionPolicy.isExpanded(savedValue: nil, isComplete: false))
        #expect(!PickyTodoProgressExpansionPolicy.isExpanded(savedValue: nil, isComplete: true))
        #expect(PickyTodoProgressExpansionPolicy.isExpanded(savedValue: true, isComplete: true))
        #expect(!PickyTodoProgressExpansionPolicy.isExpanded(savedValue: false, isComplete: false))
    }

    @Test func completionCollapsesOnlyOnTheTransitionIntoDone() {
        #expect(PickyTodoProgressExpansionPolicy.shouldCollapse(previousIsComplete: nil, currentIsComplete: true))
        #expect(PickyTodoProgressExpansionPolicy.shouldCollapse(previousIsComplete: false, currentIsComplete: true))
        #expect(!PickyTodoProgressExpansionPolicy.shouldCollapse(previousIsComplete: true, currentIsComplete: true))
        #expect(!PickyTodoProgressExpansionPolicy.shouldCollapse(previousIsComplete: false, currentIsComplete: false))
    }

    @Test func adaptiveWidthResolvesShortWidthToMinimum() {
        let resolved = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: 120,
            availableWidth: 1024,
            minimumWidth: PickyTodoProgressOverlayView.minimumCardWidth,
            maximumWidth: PickyTodoProgressOverlayView.maximumCardWidth
        )

        #expect(resolved == PickyTodoProgressOverlayView.minimumCardWidth)
    }

    @Test func adaptiveWidthResolvesMediumWidthToIdeal() {
        let resolved = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: 480,
            availableWidth: 1024,
            minimumWidth: PickyTodoProgressOverlayView.minimumCardWidth,
            maximumWidth: PickyTodoProgressOverlayView.maximumCardWidth
        )

        #expect(resolved == 480)
    }

    @Test func adaptiveWidthResolvesOverwideToClampedMaximum() {
        let resolved = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: 1200,
            availableWidth: 1024,
            minimumWidth: PickyTodoProgressOverlayView.minimumCardWidth,
            maximumWidth: PickyTodoProgressOverlayView.maximumCardWidth
        )

        #expect(resolved == PickyTodoProgressOverlayView.maximumCardWidth)
    }

    @Test func adaptiveWidthUsesAvailableWidthWhenBelowMaximum() {
        let resolved = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: 1200,
            availableWidth: 520,
            minimumWidth: PickyTodoProgressOverlayView.minimumCardWidth,
            maximumWidth: PickyTodoProgressOverlayView.maximumCardWidth
        )

        #expect(resolved == 520)
    }

    @Test func adaptiveWidthUsesAvailableWidthWhenNarrowerThanMinimum() {
        let resolved = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: 1200,
            availableWidth: 250,
            minimumWidth: PickyTodoProgressOverlayView.minimumCardWidth,
            maximumWidth: PickyTodoProgressOverlayView.maximumCardWidth
        )

        #expect(resolved == 250)
    }

    @Test func expandedListScrollsWhenTaskCountExceedsFive() throws {
        let fiveTasks = PickyTodoState(
            tasks: (1...5).map { PickyTodoTask(id: "todo-\($0)", content: "Task \($0)", status: .pending) },
            updatedAt: Date(timeIntervalSince1970: 1_800_000_003)
        )
        let sixTasks = PickyTodoState(
            tasks: (1...6).map { PickyTodoTask(id: "todo-\($0)", content: "Task \($0)", status: .pending) },
            updatedAt: Date(timeIntervalSince1970: 1_800_000_004)
        )

        #expect(try #require(PickyTodoProgressPresentation(state: fiveTasks)).usesScrollableExpandedList == false)
        #expect(try #require(PickyTodoProgressPresentation(state: sixTasks)).usesScrollableExpandedList)
    }

    @Test func inProgressTodoMarkerAnimatesOnlyWhenSessionIsRunning() {
        #expect(PickyTodoProgressMarkerPolicy.shouldAnimateInProgressMarker(taskStatus: .inProgress, isSessionRunning: true))
        #expect(!PickyTodoProgressMarkerPolicy.shouldAnimateInProgressMarker(taskStatus: .inProgress, isSessionRunning: false))
        #expect(!PickyTodoProgressMarkerPolicy.shouldAnimateInProgressMarker(taskStatus: .pending, isSessionRunning: false))
        #expect(!PickyTodoProgressMarkerPolicy.shouldAnimateInProgressMarker(taskStatus: .completed, isSessionRunning: true))
    }

    @Test func todoOutsideClickPolicyCollapsesOnlyOutsideTrackedBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 180)

        #expect(!PickyTodoOutsideClickPolicy.shouldCollapse(
            isSameWindow: true,
            locationInTrackedView: CGPoint(x: 150, y: 90),
            trackedBounds: bounds
        ))
        #expect(PickyTodoOutsideClickPolicy.shouldCollapse(
            isSameWindow: true,
            locationInTrackedView: CGPoint(x: 320, y: 90),
            trackedBounds: bounds
        ))
        #expect(PickyTodoOutsideClickPolicy.shouldCollapse(
            isSameWindow: false,
            locationInTrackedView: nil,
            trackedBounds: bounds
        ))
    }

    @Test func todoOutsideClickMonitorReturnsEventAfterSchedulingCollapse() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 500, height: 300))
        let trackedView = NSView(frame: NSRect(x: 100, y: 80, width: 300, height: 180))
        contentView.addSubview(trackedView)
        panel.contentView = contentView
        defer { panel.close() }

        var collapseCount = 0
        let coordinator = PickyTodoOutsideClickMonitor.Coordinator(
            onOutsideClick: { collapseCount += 1 },
            schedule: { action in action() }
        )
        let outsideEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let returnedEvent = coordinator.handle(event: outsideEvent, relativeTo: trackedView)

        #expect(returnedEvent === outsideEvent)
        #expect(collapseCount == 1)
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
        #expect(presentation.activeStepNumber == nil)
        #expect(presentation.currentStepNumber == 2)
        #expect(presentation.countText == "2/2")
        #expect(presentation.stepText == L10n.t("hud.todo.completedCount", Int64(2), Int64(2)))
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
