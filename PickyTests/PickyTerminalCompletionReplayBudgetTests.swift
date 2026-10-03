//
//  PickyTerminalCompletionReplayBudgetTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickyTerminalCompletionReplayBudgetTests {
    // Pinned on the v2 replay shape: 11 transaction frames for the captured
    // terminal burst. The retired v1 event burst published 59 for the same
    // user-visible outcome.
    private static let terminalBurstPublishBaseline = 35
    private let events = PickyProjectionEventFixtures()

    @Test func terminalReplayPublishesThePinnedBaselineAndProjectsCompletion() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        prepareHydratedSession(in: viewModel)
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        for envelope in PickyProjectionReplayFixtures.terminalReplayEnvelopes(using: events) {
            PickyProjectionReplayFixtures.apply(envelope, to: viewModel)
        }

        let card = viewModel.sessions.first { $0.id == PickyProjectionReplayFixtures.terminalSessionID }
        #expect(publishCount == Self.terminalBurstPublishBaseline)
        #expect(card?.status == .completed)
        #expect(card?.lastSummary == "Completed the investigation.")
        #expect(card?.artifacts.count == 1)
        #expect(card?.messages.count == 3)
        #expect(viewModel.pendingDoneFlashSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        #expect(viewModel.unreadSessionIDs.contains(PickyProjectionReplayFixtures.terminalSessionID))
        withExtendedLifetime(cancellable) {}
    }

    private func prepareHydratedSession(in viewModel: PickySessionListViewModel) {
        let hydrated = PickyProjectionReplayFixtures.terminalSession(
            status: .running,
            messages: [
                PickyProjectionReplayFixtures.terminalMessage(
                    id: "initial-user",
                    kind: .userText,
                    text: "Investigate the completion path."
                ),
            ],
            messageJournalAvailable: true,
            artifacts: []
        )
        PickyProjectionReplayFixtures.apply(
            events.snapshotEnvelope(
                id: "terminal-bootstrap",
                session: hydrated,
                timestamp: PickyProjectionReplayFixtures.terminalDate
            ),
            to: viewModel
        )
    }
}
