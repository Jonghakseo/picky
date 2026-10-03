//
//  PickySessionBootstrapReplayBudgetTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickySessionBootstrapReplayBudgetTests {
    private let events = PickyProjectionEventFixtures()

    @Test func historicalCompletedHydrationDoesNotDeliverNotificationsOrAttentionEffects() {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickyProjectionReplayFixtures.makeViewModel(notificationCenter: notifications, selectedSessionID: "bootstrap-001")

        applyFullReplay(to: viewModel)

        #expect(notifications.delivered.isEmpty)
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
        #expect(viewModel.unreadSessionIDs.isEmpty)
    }

    @Test func fullHydrationRetainsArchiveMembershipSelectionAndStableOrder() {
        let first = PickyProjectionReplayFixtures.makeViewModel()
        let second = PickyProjectionReplayFixtures.makeViewModel()
        let secondEvents = PickyProjectionEventFixtures()

        // The v2 bootstrap streams one snapshot per session, so the user can
        // only have a resolvable selection once the membership wave lands. The
        // contract under test is that the following hydration wave, which
        // replaces every card with its full journal, does not steal it.
        applyFullReplay(to: first) { first.select(sessionID: "bootstrap-001") }
        applyFullReplay(to: second, using: secondEvents) { second.select(sessionID: "bootstrap-001") }

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
            events.snapshotEnvelope(id: "unavailable-summary", session: unavailable),
            to: viewModel
        )
        PickyProjectionReplayFixtures.apply(
            events.snapshotEnvelope(id: "unavailable-hydration", session: unavailable),
            to: viewModel
        )

        let card = viewModel.sessions.first { $0.id == unavailable.id }
        #expect(card?.messages.isEmpty == true)
        #expect(viewModel.sessions.count + viewModel.archivedSessions.count == 1)
    }

    private func applyFullReplay(
        to viewModel: PickySessionListViewModel,
        using builder: PickyProjectionEventFixtures? = nil,
        afterMembershipWave: (() -> Void)? = nil
    ) {
        let builder = builder ?? events
        for envelope in PickyProjectionReplayFixtures.bootstrapSnapshotEvents(using: builder) {
            PickyProjectionReplayFixtures.apply(envelope, to: viewModel)
        }
        viewModel.apply(.sessionProjectionBootstrapCompletion(removedSessionIDs: [], isPrimary: true))
        afterMembershipWave?()
        for session in PickyProjectionReplayFixtures.hydratedBootstrapSessions() {
            PickyProjectionReplayFixtures.apply(
                builder.snapshotEnvelope(id: "hydration-\(session.id)", session: session),
                to: viewModel
            )
        }
    }
}
