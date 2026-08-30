//
//  PickySessionRegistryProjectionTests.swift
//  PickyTests
//

import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickySessionRegistryProjectionTests {
    /// Strict deterministic ownership gate. This observes store invalidation
    /// directly, rather than AppKit-driven body evaluation.
    @Test func messageOnlyUpdateDoesNotInvalidateSiblingDockProjectionButStatusChangeDoes() {
        let registry = PickySessionRegistry()
        let first = registry.sessionStore(sessionID: "first")
        let second = registry.sessionStore(sessionID: "second")
        first.replace(card: card(id: "first", status: .running))
        second.replace(card: card(id: "second", status: .running))
        registry.replaceMembership(active: ["first", "second"], archived: [])

        let firstInvalidations = ProjectionInvalidationCounter()
        let secondInvalidations = ProjectionInvalidationCounter()
        withObservationTracking { _ = first.dockStore.projection } onChange: {
            firstInvalidations.increment()
        }
        withObservationTracking { _ = second.dockStore.projection } onChange: {
            secondInvalidations.increment()
        }

        first.conversationStore.messageStore(message: message(id: "first-message", text: "Streaming"))

        #expect(firstInvalidations.count == 0)
        #expect(secondInvalidations.count == 0)

        first.replace(card: card(id: "first", status: .completed))

        #expect(firstInvalidations.count == 1)
        #expect(secondInvalidations.count == 0)
    }

    @Test func terminalAttachmentStoreInvalidatesMountedAttachmentWhenAnotherPanelTakesOwnership() {
        let store = PickyTerminalAttachmentStore()
        let invalidations = ProjectionInvalidationCounter()
        func trackFirstPanelAttachment() {
            withObservationTracking {
                _ = store.isActive(sessionID: "first", attachmentID: "first-panel")
            } onChange: {
                invalidations.increment()
            }
        }

        trackFirstPanelAttachment()
        store.activate(
            sessionID: "first",
            attachmentID: "first-panel",
            eligibleSessionIDs: ["first", "second"]
        )
        #expect(invalidations.count == 1)
        #expect(store.isActive(sessionID: "first", attachmentID: "first-panel"))

        trackFirstPanelAttachment()
        store.activate(
            sessionID: "second",
            attachmentID: "second-panel",
            eligibleSessionIDs: ["first", "second"]
        )
        #expect(invalidations.count == 2)
        #expect(!store.isActive(sessionID: "first", attachmentID: "first-panel"))
    }

    @Test func dockCompactionMatchesLegacyTerminalStatusPolicy() {
        let compactableStatuses: [PickySessionStatus] = [.completed, .blocked, .failed, .cancelled]
        let nonCompactableStatuses: [PickySessionStatus] = [.queued, .running, .waiting_for_input]

        for status in compactableStatuses {
            #expect(dockProjection(status: status).canRequestDockCompaction, "\(status) should allow dock compaction")
        }
        for status in nonCompactableStatuses {
            #expect(!dockProjection(status: status).canRequestDockCompaction, "\(status) should not allow dock compaction")
        }
        #expect(!dockProjection(status: .running, lastSummary: "Compacting the session").canRequestDockCompaction)
    }

    @Test func dockGitRefreshBucketChangesOnlyAtTwentySecondBoundaries() {
        let beforeBoundary = dockProjection(
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 119)
        )
        let withinBucket = dockProjection(
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let nextBucket = dockProjection(
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 120)
        )

        #expect(beforeBoundary.gitRefreshBucket == withinBucket.gitRefreshBucket)
        #expect(nextBucket.gitRefreshBucket == beforeBoundary.gitRefreshBucket + 1)
    }

    /// Supplementary positive control only. AppKit layout can re-evaluate either
    /// icon's body without a store mutation, so exact body counts are not a CI
    /// contract. The deterministic sibling-isolation gate is the Observation test above.
    @Test func mountedDockIconsDeliverStatusChangeToTheTarget() {
        let registry = PickySessionRegistry()
        let first = registry.sessionStore(sessionID: "first")
        let second = registry.sessionStore(sessionID: "second")
        first.replace(card: card(id: "first", status: .running))
        second.replace(card: card(id: "second", status: .running))
        registry.replaceMembership(active: ["first", "second"], archived: [])

        let evaluations = DockIconEvaluationCounter()
        let host = NSHostingView(rootView: AnyView(HStack {
            dockIcon(session: PickyHUDDockSession(store: first)) { evaluations.record("first") }
            dockIcon(session: PickyHUDDockSession(store: second)) { evaluations.record("second") }
        }))
        defer { dismantleMountedHost(host) }
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 80)
        #expect(waitForMountedHost(host) { evaluations.count(for: "first") > 0 })
        let firstInitial = evaluations.count(for: "first")

        first.replace(card: card(id: "first", status: .completed))
        #expect(waitForMountedHost(host) { evaluations.count(for: "first") > firstInitial })
    }

    @Test func diffStoreInvalidatesOnlyItsOwnMountedUtilityPanel() {
        let first = PickySessionDiffStore()
        let second = PickySessionDiffStore()
        let firstInvalidations = ProjectionInvalidationCounter()
        let secondInvalidations = ProjectionInvalidationCounter()
        let firstSubscription = first.objectWillChange.sink { _ in firstInvalidations.increment() }
        let secondSubscription = second.objectWillChange.sink { _ in secondInvalidations.increment() }
        defer {
            firstSubscription.cancel()
            secondSubscription.cancel()
        }

        first.replace(.requesting(view: .unstaged, requestID: "first-request"))

        #expect(firstInvalidations.count == 1)
        #expect(secondInvalidations.count == 0)
    }

    @Test func archiveMembershipInvalidatesOnlyWhenMembershipChanges() {
        let registry = PickySessionRegistry()
        let archived = registry.sessionStore(sessionID: "archived")
        let active = registry.sessionStore(sessionID: "active")
        archived.replace(card: card(id: "archived", status: .completed))
        active.replace(card: card(id: "active", status: .running))
        registry.replaceMembership(active: ["active"], archived: ["archived"])

        let invalidations = ProjectionInvalidationCounter()
        withObservationTracking { _ = registry.archivedSessionIDs } onChange: {
            invalidations.increment()
        }

        active.conversationStore.messageStore(message: message(id: "active-message", text: "Unrelated"))
        #expect(invalidations.count == 0)

        registry.replaceMembership(active: ["active", "archived"], archived: [])
        #expect(invalidations.count == 1)
    }

    @Test func runningCountTracksStatusTransitionsWithoutMessageOnlyInvalidation() {
        let registry = PickySessionRegistry()
        let first = registry.sessionStore(sessionID: "first")
        let second = registry.sessionStore(sessionID: "second")
        first.replace(card: card(id: "first", status: .running))
        second.replace(card: card(id: "second", status: .completed))
        registry.replaceMembership(active: ["first", "second"], archived: [])

        let invalidations = ProjectionInvalidationCounter()
        withObservationTracking { _ = registry.runningSessionCount } onChange: {
            invalidations.increment()
        }
        #expect(registry.runningSessionCount == 1)

        first.conversationStore.messageStore(message: message(id: "first-message", text: "Streaming"))
        #expect(invalidations.count == 0)
        #expect(registry.runningSessionCount == 1)

        second.replace(card: card(id: "second", status: .running))
        #expect(invalidations.count == 1)
        #expect(registry.runningSessionCount == 2)

        first.replace(card: card(id: "first", status: .completed))
        #expect(registry.runningSessionCount == 1)
    }

    private func dockProjection(
        status: PickySessionStatus,
        lastSummary: String = "",
        updatedAt: Date = PickyProjectionReplayFixtures.terminalDate
    ) -> PickySessionDockProjection {
        var session = card(id: "projection", status: status)
        session.lastSummary = lastSummary
        session.updatedAt = updatedAt
        return PickySessionDockProjection(
            metadata: PickySessionMetadata(card: session),
            todoState: nil
        )
    }

    private func dockIcon(session: PickyHUDDockSession, onBodyEvaluation: @escaping () -> Void) -> PickyHUDDockIconView {
        PickyHUDDockIconView(
            session: session,
            index: 0,
            isActive: false,
            isOpened: false,
            isPreviewed: false,
            isScreenContextArmed: false,
            isScreenContextSticky: false,
            dockSide: .right,
            shortcutNumber: nil,
            isCommandShortcutHintVisible: false,
            shouldFlashCompletion: false,
            isUnread: false,
            metrics: .medium,
            onHoverChanged: { _ in },
            onOpen: {},
            onToggleScreenContextTarget: {},
            onToggleStickyScreenContextTarget: {},
            onCompact: {},
            onArchive: {},
            onStop: {},
            onDoneFlashConsumed: {},
            onBodyEvaluation: onBodyEvaluation
        )
    }

    private func waitForMountedHost<Root: View>(
        _ host: NSHostingView<Root>,
        timeout: TimeInterval = 1,
        until condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        host.layoutSubtreeIfNeeded()
        return condition()
    }

    private func dismantleMountedHost(_ host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        host.frame = .zero
        host.layoutSubtreeIfNeeded()
    }

    /// Real persisted sessions repeat `runId` across subagent batches (each batch
    /// restarts its counter), so a per-session index keyed on it must tolerate
    /// duplicates instead of trapping while hydrating a bootstrap snapshot.
    @Test func childStoresIndexDuplicateServerIDsWithoutTrapping() {
        let subagents = PickySessionSubagentStore()
        subagents.replace([run(runId: 1, agent: "worker"), run(runId: 2, agent: "verifier"), run(runId: 1, agent: "reviewer")])
        #expect(subagents.runsState.loadedValue?.count == 3)
        #expect(subagents.run(id: 1)?.agent == "reviewer")

        let tools = PickySessionToolStore()
        tools.replace([tool(id: "call-1", name: "read"), tool(id: "call-1", name: "write")])
        #expect(tools.toolsState.loadedValue?.count == 2)
        #expect(tools.tool(id: "call-1")?.name == "write")

        let todo = PickySessionTodoStore()
        todo.replace(PickyTodoState(
            tasks: [todoTask(id: "t1", content: "first"), todoTask(id: "t1", content: "second")],
            updatedAt: PickyProjectionReplayFixtures.terminalDate
        ))
        #expect(todo.task(id: "t1")?.content == "second")

        let artifacts = PickySessionArtifactStore()
        artifacts.replace(
            artifacts: [artifact(id: "a1", title: "first"), artifact(id: "a1", title: "second")],
            changedFiles: [changedFile(path: "/tmp/f"), changedFile(path: "/tmp/f")]
        )
        #expect(artifacts.artifactsState.loadedValue?.count == 2)
        #expect(artifacts.artifact(id: "a1")?.title == "second")

        let queue = PickySessionQueueStore()
        queue.replace(
            steers: [queueItem(id: "dup", text: "first"), queueItem(id: "dup", text: "second")],
            followUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime
        )
        #expect(queue.queueState.loadedValue?.steers.count == 2)
    }

    private func tool(id: String, name: String) -> PickyToolActivity {
        PickyToolActivity(toolCallId: id, name: name, status: "succeeded")
    }

    private func todoTask(id: String, content: String) -> PickyTodoTask {
        PickyTodoTask(id: id, content: content, status: .pending, activeForm: nil, notes: nil)
    }

    private func artifact(id: String, title: String) -> PickyArtifact {
        PickyArtifact(id: id, kind: "github", title: title, path: nil, url: nil, updatedAt: PickyProjectionReplayFixtures.terminalDate)
    }

    private func changedFile(path: String) -> PickyChangedFile {
        PickyChangedFile(path: path, status: "M", summary: nil)
    }

    private func queueItem(id: String, text: String) -> PickyQueueItem {
        PickyQueueItem(text: text, enqueuedAt: PickyProjectionReplayFixtures.terminalDate, id: id)
    }

    private func run(runId: Int, agent: String) -> PickySubagentRun {
        PickySubagentRun(
            runId: runId,
            agent: agent,
            task: "task",
            displayTask: nil,
            status: .done,
            errorClass: nil,
            startedAt: PickyProjectionReplayFixtures.terminalDate,
            elapsedMs: 1,
            batchId: nil,
            pipelineId: nil,
            pipelineStepIndex: nil,
            resultPreview: nil,
            model: nil
        )
    }

    private func card(id: String, status: PickySessionStatus) -> PickySessionListViewModel.SessionCard {
        .fromAgentSession(PickyAgentSession(
            id: id,
            title: "Session \(id)",
            status: status,
            cwd: "/tmp/\(id)",
            createdAt: PickyProjectionReplayFixtures.terminalDate,
            updatedAt: PickyProjectionReplayFixtures.terminalDate,
            lastSummary: "",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: [],
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            activitySummary: .zero,
            contextUsage: nil,
            pendingExtensionUiRequest: nil,
            notifyMainOnCompletion: nil
        ))
    }

    private func message(id: String, text: String) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: .agentText,
            createdAt: PickyProjectionReplayFixtures.terminalDate,
            originatedBy: .mainAgent,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil
        )
    }
}

private final class DockIconEvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ id: String) {
        lock.withLock { counts[id, default: 0] += 1 }
    }

    func count(for id: String) -> Int {
        lock.withLock { counts[id, default: 0] }
    }
}

private final class ProjectionInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
