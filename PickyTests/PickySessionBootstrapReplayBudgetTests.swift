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
        let first = PickyProjectionReplayFixtures.makeViewModelWithSelectionStore(selectedSessionID: "bootstrap-001")
        let second = PickyProjectionReplayFixtures.makeViewModel(selectedSessionID: "bootstrap-001")
        let secondEvents = PickyProjectionEventFixtures()

        applyFullReplay(to: first.viewModel)
        applyFullReplay(to: second, using: secondEvents)

        let expectedArchivedIDs = Set(PickyProjectionReplayFixtures.lightweightBootstrapSessions().filter { $0.archived == true }.map(\.id))
        #expect(first.viewModel.sessions.count + first.viewModel.archivedSessions.count == 94)
        #expect(Set(first.viewModel.archivedSessions.map(\.id)) == expectedArchivedIDs)
        #expect(first.viewModel.selectedSessionID == "bootstrap-001")
        #expect(first.selectionStore.selectedSessionID == "bootstrap-001")
        #expect(first.viewModel.sessions.map(\.id) == second.sessions.map(\.id))
        #expect(first.viewModel.archivedSessions.map(\.id) == second.archivedSessions.map(\.id))
    }

    /// The v2 bootstrap streams one snapshot per session. Until the completion
    /// frame lands, a session that has not arrived yet is unknown, not absent,
    /// so the persisted selection has to survive the whole wave.
    @Test func bootstrapWaveBeforeTheSelectedSessionKeepsThePersistedSelection() {
        let harness = PickyProjectionReplayFixtures.makeViewModelWithSelectionStore(selectedSessionID: "bootstrap-001")
        let wave = PickyProjectionReplayFixtures.bootstrapSnapshotEvents(using: events)
        let selectedEnvelopeID = "bootstrap-bootstrap-001"

        for envelope in wave.prefix(while: { $0.id != selectedEnvelopeID }) {
            PickyProjectionReplayFixtures.apply(envelope, to: harness.viewModel)
        }

        #expect(harness.viewModel.sessions.contains { $0.id == "bootstrap-001" } == false)
        #expect(harness.selectionStore.selectedSessionID == "bootstrap-001")

        for envelope in wave.drop(while: { $0.id != selectedEnvelopeID }) {
            PickyProjectionReplayFixtures.apply(envelope, to: harness.viewModel)
        }
        harness.viewModel.apply(.sessionProjectionBootstrapCompletion(removedSessionIDs: [], isPrimary: true))

        #expect(harness.viewModel.selectedSessionID == "bootstrap-001")
        #expect(harness.selectionStore.selectedSessionID == "bootstrap-001")
    }

    @Test func bootstrapCompletionDropsASelectionTheDaemonNeverSent() {
        let harness = PickyProjectionReplayFixtures.makeViewModelWithSelectionStore(selectedSessionID: "deleted-elsewhere")

        for envelope in PickyProjectionReplayFixtures.bootstrapSnapshotEvents(using: events) {
            PickyProjectionReplayFixtures.apply(envelope, to: harness.viewModel)
        }
        #expect(harness.selectionStore.selectedSessionID == "deleted-elsewhere")

        harness.viewModel.apply(.sessionProjectionBootstrapCompletion(removedSessionIDs: [], isPrimary: true))

        #expect(harness.viewModel.selectedSessionID == "bootstrap-093")
        #expect(harness.selectionStore.selectedSessionID == nil)
    }

    /// Archiving is the one membership change a snapshot can prove on its own,
    /// so it must still demote a selection pointing at the archived Pickle.
    @Test func snapshotThatArchivesTheSelectedSessionStillClearsThePersistedSelection() {
        let harness = PickyProjectionReplayFixtures.makeViewModelWithSelectionStore(selectedSessionID: "bootstrap-001")
        let active = PickyProjectionReplayFixtures.lightweightBootstrapSessions().first { $0.id == "bootstrap-001" }!

        PickyProjectionReplayFixtures.apply(events.snapshotEnvelope(id: "active", session: active), to: harness.viewModel)
        #expect(harness.selectionStore.selectedSessionID == "bootstrap-001")

        let archived = PickyProjectionReplayFixtures.bootstrapSession(
            id: active.id,
            index: 1,
            status: active.status,
            archived: true,
            messages: [],
            messageJournalAvailable: false
        )
        PickyProjectionReplayFixtures.apply(events.snapshotEnvelope(id: "archived", session: archived), to: harness.viewModel)

        #expect(harness.viewModel.archivedSessions.map(\.id) == ["bootstrap-001"])
        #expect(harness.viewModel.selectedSessionID == nil)
        #expect(harness.selectionStore.selectedSessionID == nil)
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
        using builder: PickyProjectionEventFixtures? = nil
    ) {
        let builder = builder ?? events
        for envelope in PickyProjectionReplayFixtures.bootstrapSnapshotEvents(using: builder) {
            PickyProjectionReplayFixtures.apply(envelope, to: viewModel)
        }
        viewModel.apply(.sessionProjectionBootstrapCompletion(removedSessionIDs: [], isPrimary: true))
        for session in PickyProjectionReplayFixtures.hydratedBootstrapSessions() {
            PickyProjectionReplayFixtures.apply(
                builder.snapshotEnvelope(id: "hydration-\(session.id)", session: session),
                to: viewModel
            )
        }
    }
}
