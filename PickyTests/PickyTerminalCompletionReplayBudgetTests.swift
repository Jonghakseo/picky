//
//  PickyTerminalCompletionReplayBudgetTests.swift
//  PickyTests
//

import Combine
import Testing
@testable import Picky

@MainActor
struct PickyTerminalCompletionReplayBudgetTests {
    // v1 terminal-burst baseline retained for W7 comparison.
    private static let terminalBurstPublishBaseline = 62

    @Test func terminalReplayPublishesThePinnedV1BaselineAndProjectsCompletion() {
        let viewModel = PickyProjectionReplayFixtures.makeViewModel()
        prepareHydratedSession(in: viewModel)
        var publishCount = 0
        let cancellable = viewModel.objectWillChange.sink { publishCount += 1 }

        for event in PickyProjectionReplayFixtures.terminalReplayEvents() {
            PickyProjectionReplayFixtures.apply(PickyProjectionReplayFixtures.terminalEnvelope(event), to: viewModel)
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
        let summary = PickyProjectionReplayFixtures.terminalSession(
            status: .running,
            messages: [],
            messageJournalAvailable: false,
            artifacts: []
        )
        PickyProjectionReplayFixtures.apply(
            PickyProjectionReplayFixtures.terminalEnvelope(.sessionSnapshot(PickySessionSnapshot(sessions: [summary]))),
            to: viewModel
        )
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
            PickyProjectionReplayFixtures.terminalEnvelope(.sessionUpdated(hydrated)),
            to: viewModel
        )
    }
}
