//
//  PickySessionBootstrapReplayBudgetTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickySessionBootstrapReplayBudgetTests {
    // v1 baselines retained for W7 comparison. Pin exact ObservableObject
    // publications rather than a range so fan-out regressions are visible.
    private static let snapshotOnlyPublishBaseline = 201
    private static let snapshotAndHydrationPublishBaseline = 1_053

    @Test func lightweightSnapshotPublishesThePinnedV1Baseline() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.bootstrapSnapshotEvent(), to: viewModel)

        #expect(publishCount == Self.snapshotOnlyPublishBaseline)
        withExtendedLifetime(cancellable) {}
    }

    @Test func lightweightSnapshotAndHydrationsPublishThePinnedV1Baseline() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        applyFullReplay(to: viewModel)

        #expect(publishCount == Self.snapshotAndHydrationPublishBaseline)
        withExtendedLifetime(cancellable) {}
    }

    @Test func historicalCompletedHydrationDoesNotDeliverNotificationsOrAttentionEffects() {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(notificationCenter: notifications, selectedSessionID: "bootstrap-001")

        applyFullReplay(to: viewModel)

        #expect(notifications.delivered.isEmpty)
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
        #expect(viewModel.unreadSessionIDs.isEmpty)
    }

    @Test func fullHydrationRetainsArchiveMembershipSelectionAndStableOrder() {
        let first = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")
        let second = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")

        applyFullReplay(to: first)
        applyFullReplay(to: second)

        let expectedArchivedIDs = Set(PickyProjectionReplayFixtures.lightweightBootstrapSessions().filter { $0.archived == true }.map(\.id))
        #expect(first.sessions.count + first.archivedSessions.count == 94)
        #expect(Set(first.archivedSessions.map(\.id)) == expectedArchivedIDs)
        #expect(first.selectedSessionID == "bootstrap-001")
        #expect(first.sessions.map(\.id) == second.sessions.map(\.id))
        #expect(first.archivedSessions.map(\.id) == second.archivedSessions.map(\.id))
    }

    @Test func unavailableJournalHydrationStaysEmptyInsteadOfRetainingConversationState() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")
        let unavailable = PickyProjectionReplayFixtures.bootstrapSession(
            id: "unavailable-journal",
            index: 95,
            status: .running,
            archived: false,
            messages: [],
            messageJournalAvailable: false
        )

        PickyProjectionReplayFixtures.apply(
            PickyProjectionReplayFixtures.bootstrapEnvelope(
                id: "unavailable-summary",
                event: .sessionSnapshot(PickySessionSnapshot(sessions: [unavailable]))
            ),
            to: viewModel
        )
        PickyProjectionReplayFixtures.apply(
            PickyProjectionReplayFixtures.bootstrapEnvelope(
                id: "unavailable-hydration",
                event: .sessionUpdated(unavailable)
            ),
            to: viewModel
        )

        let card = viewModel.sessions.first { $0.id == unavailable.id }
        #expect(card?.messages.isEmpty == true)
        #expect(viewModel.sessions.count + viewModel.archivedSessions.count == 1)
    }

    private func applyFullReplay(to viewModel: PickySessionListViewModel) {
        PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.bootstrapSnapshotEvent(), to: viewModel)
        for session in PickyProjectionReplayFixtures.hydratedBootstrapSessions() {
            PickyProjectionReplayFixtures.apply(
                PickyProjectionReplayFixtures.bootstrapEnvelope(id: "hydration-\(session.id)", event: .sessionUpdated(session)),
                to: viewModel
            )
        }
    }
}
