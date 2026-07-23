//
//  QuickInputPanelViewModelTests.swift
//  PickyTests
//
//  Covers Quick Input view-model state shared by history and submission flows.
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct QuickInputPanelViewModelTests {
    @Test
    func managerRecentMessagesPropagateToViewModel() {
        let manager = QuickInputPanelManager()
        let message = PickyMainAgentMessage(
            role: .user,
            text: "Where did the last reply go?",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        manager.updateRecentMessages([message])

        #expect(manager.viewModelForTesting.recentMessages == [message])
    }

    @Test
    func presentationIDAdvancesForEveryPanelPresentation() {
        let viewModel = QuickInputPanelViewModel()

        viewModel.beginPresentation()
        #expect(viewModel.presentationID == 1)

        viewModel.beginPresentation()
        #expect(viewModel.presentationID == 2)
    }

    @Test
    func historyBackgroundSolidifiesOnUserScrollAndResetsOnPresentation() {
        let viewModel = QuickInputPanelViewModel()
        #expect(viewModel.historyBackgroundMode == .lightweight)

        viewModel.markHistoryUserScroll()
        #expect(viewModel.historyBackgroundMode == .solid)

        viewModel.markHistoryUserScroll()
        #expect(viewModel.historyBackgroundMode == .solid)

        viewModel.beginPresentation()
        #expect(viewModel.historyBackgroundMode == .lightweight)
    }

    @Test
    func managerRemainsLogicallyVisibleWhileAnOptimisticSubmissionIsInFlight() {
        let manager = QuickInputPanelManager()

        manager.viewModelForTesting.isSending = true

        #expect(manager.isPanelVisible)
    }

    @Test
    func pickleRecipientPresentationHidesMainHistoryAndNamesTarget() {
        let viewModel = QuickInputPanelViewModel()

        viewModel.beginPresentation(recipient: .pickle(sessionID: "pickle-a", label: "Investigate logs"))

        #expect(viewModel.recipient == .pickle(sessionID: "pickle-a", label: "Investigate logs"))
        #expect(viewModel.recipient.prompt == "Message Investigate logs…")
        #expect(!viewModel.recipient.showsMainAgentHistory)
    }

    @Test
    func submitDeliversTheRecipientCapturedForThisPresentation() {
        let viewModel = QuickInputPanelViewModel()
        let recipient = QuickInputRecipientProjection.pickle(sessionID: "pickle-a", label: "Investigate logs")
        var submittedRecipient: QuickInputRecipientProjection?
        viewModel.beginPresentation(recipient: recipient)
        viewModel.draftText = "Continue from the error"
        viewModel.onSubmit = { _, recipient in submittedRecipient = recipient }

        viewModel.submit()

        #expect(submittedRecipient == recipient)
    }

    @Test
    func failedSendRestoresPickleRecipientUntilAnExplicitMainPresentation() {
        let manager = QuickInputPanelManager()
        let recipient = QuickInputRecipientProjection.pickle(sessionID: "pickle-a", label: "Investigate logs")
        let viewModel = manager.viewModelForTesting
        viewModel.beginPresentation(recipient: recipient)
        viewModel.isSending = true

        manager.panelDidFinishSending(success: false, errorMessage: nil)

        #expect(viewModel.recipient == recipient)
        #expect(viewModel.recipient.prompt == "Message Investigate logs…")
        #expect(!viewModel.recipient.showsMainAgentHistory)

        manager.dismiss()
        manager.presentPanel(near: .zero, recipient: .main)

        #expect(viewModel.recipient == .main)

        manager.dismiss()
    }
}
