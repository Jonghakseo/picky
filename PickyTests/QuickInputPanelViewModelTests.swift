//
//  QuickInputPanelViewModelTests.swift
//  PickyTests
//
//  Covers the screenshot-attachment indicator state on QuickInputPanelViewModel
//  so the trailing camera icon's three modes stay distinguishable.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct QuickInputPanelViewModelTests {
    @Test
    func defaultScreenshotStateIsAttached() {
        let viewModel = QuickInputPanelViewModel()
        #expect(viewModel.screenshotState == .attached)
    }

    @Test
    func screenshotStateUpdatesArePublished() {
        let viewModel = QuickInputPanelViewModel()

        viewModel.screenshotState = .gated
        #expect(viewModel.screenshotState == .gated)

        viewModel.screenshotState = .attached
        #expect(viewModel.screenshotState == .attached)
    }

    @Test
    func managerUpdateScreenshotStatePropagatesToViewModel() {
        let manager = QuickInputPanelManager()

        manager.updateScreenshotState(.gated)
        #expect(manager.viewModelForTesting.screenshotState == .gated)

        manager.updateScreenshotState(.attached)
        #expect(manager.viewModelForTesting.screenshotState == .attached)
    }

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
    func managerRemainsLogicallyVisibleWhileAnOptimisticSubmissionIsInFlight() {
        let manager = QuickInputPanelManager()

        manager.viewModelForTesting.isSending = true

        #expect(manager.isPanelVisible)
    }
}
