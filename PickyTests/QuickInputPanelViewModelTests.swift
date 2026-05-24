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

        viewModel.screenshotState = .annotated
        #expect(viewModel.screenshotState == .annotated)

        viewModel.screenshotState = .gated
        #expect(viewModel.screenshotState == .gated)

        viewModel.screenshotState = .attached
        #expect(viewModel.screenshotState == .attached)
    }

    @Test
    func managerUpdateScreenshotStatePropagatesToViewModel() {
        let manager = QuickInputPanelManager()

        manager.updateScreenshotState(.annotated)
        #expect(manager.viewModelForTesting.screenshotState == .annotated)

        manager.updateScreenshotState(.gated)
        #expect(manager.viewModelForTesting.screenshotState == .gated)
    }
}
