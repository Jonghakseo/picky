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

    @Test func mountedDockIconsRefreshOnlyTheStatusTarget() {
        let registry = PickySessionRegistry()
        let first = registry.sessionStore(sessionID: "first")
        let second = registry.sessionStore(sessionID: "second")
        first.replace(card: card(id: "first", status: .running))
        second.replace(card: card(id: "second", status: .running))
        registry.replaceMembership(active: ["first", "second"], archived: [])

        let evaluations = DockIconEvaluationCounter()
        let host = NSHostingView(rootView: HStack {
            dockIcon(session: PickyHUDDockSession(store: first)) { evaluations.record("first") }
            dockIcon(session: PickyHUDDockSession(store: second)) { evaluations.record("second") }
        })
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 80)
        #expect(waitForMountedHost(host) {
            evaluations.count(for: "first") > 0 && evaluations.count(for: "second") > 0
        })
        let firstInitial = evaluations.count(for: "first")
        let secondInitial = evaluations.count(for: "second")

        first.conversationStore.messageStore(message: message(id: "first-message", text: "Streaming"))
        host.layoutSubtreeIfNeeded()
        #expect(evaluations.count(for: "first") == firstInitial)
        #expect(evaluations.count(for: "second") == secondInitial)

        first.replace(card: card(id: "first", status: .completed))
        #expect(waitForMountedHost(host) { evaluations.count(for: "first") > firstInitial })
        #expect(evaluations.count(for: "second") == secondInitial)
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
            onHover: {},
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
