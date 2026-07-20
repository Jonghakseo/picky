//
//  PickySecureSurfaceWindowCoordinatorTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickySecureSurfaceWindowCoordinatorTests {
    @Test func hidesEveryVisibleAlwaysOnTopWindowWhileAppStoreIsFrontmost() {
        let hud = FakeSecureSurfaceWindow(isVisible: true)
        let quickInput = FakeSecureSurfaceWindow(isVisible: true)
        let cursorOverlay = FakeSecureSurfaceWindow(isVisible: true)
        let hiddenPanel = FakeSecureSurfaceWindow(isVisible: false)
        let coordinator = makeCoordinator(windows: [hud, quickInput, cursorOverlay, hiddenPanel])

        coordinator.apply(frontmostBundleID: "com.apple.AppStore")

        #expect(coordinator.isSuppressed)
        #expect(hud.orderOutCallCount == 1)
        #expect(quickInput.orderOutCallCount == 1)
        #expect(cursorOverlay.orderOutCallCount == 1)
        #expect(hiddenPanel.orderOutCallCount == 0)
    }

    @Test func restoresOnlyWindowsThatWereVisibleBeforeAppStoreActivation() {
        let hud = FakeSecureSurfaceWindow(isVisible: true)
        let hiddenPanel = FakeSecureSurfaceWindow(isVisible: false)
        let coordinator = makeCoordinator(windows: [hud, hiddenPanel])

        coordinator.apply(frontmostBundleID: "com.apple.AppStore")
        coordinator.apply(frontmostBundleID: "com.apple.Safari")

        #expect(!coordinator.isSuppressed)
        #expect(hud.orderFrontCallCount == 1)
        #expect(hiddenPanel.orderFrontCallCount == 0)
    }

    @Test func leavesNormalLevelWindowsUntouched() {
        let reportWindow = FakeSecureSurfaceWindow(isVisible: true, isSuppressionCandidate: false)
        let coordinator = makeCoordinator(windows: [reportWindow])

        coordinator.apply(frontmostBundleID: "com.apple.AppStore")
        coordinator.apply(frontmostBundleID: "com.apple.Safari")

        #expect(reportWindow.orderOutCallCount == 0)
        #expect(reportWindow.orderFrontCallCount == 0)
    }

    @Test func hidesWindowsThatAppearAfterAppStoreIsAlreadyFrontmost() {
        let hud = FakeSecureSurfaceWindow(isVisible: true)
        let quickInput = FakeSecureSurfaceWindow(isVisible: false)
        let coordinator = makeCoordinator(windows: [hud, quickInput])

        coordinator.apply(frontmostBundleID: "com.apple.AppStore")
        quickInput.isVisible = true
        coordinator.apply(frontmostBundleID: "com.apple.AppStore")

        #expect(quickInput.orderOutCallCount == 1)
        #expect(!quickInput.isVisible)
    }

    private func makeCoordinator(
        windows: [FakeSecureSurfaceWindow]
    ) -> PickySecureSurfaceWindowCoordinator {
        PickySecureSurfaceWindowCoordinator(
            frontmostBundleIDProvider: { nil },
            windowsProvider: { windows.map { $0 as PickySecureSurfaceManagedWindow } }
        )
    }
}

@MainActor
private final class FakeSecureSurfaceWindow: PickySecureSurfaceManagedWindow {
    var isVisible: Bool
    let isSecureSurfaceSuppressionCandidate: Bool
    private(set) var orderOutCallCount = 0
    private(set) var orderFrontCallCount = 0

    init(isVisible: Bool, isSuppressionCandidate: Bool = true) {
        self.isVisible = isVisible
        self.isSecureSurfaceSuppressionCandidate = isSuppressionCandidate
    }

    func orderOut(_ sender: Any?) {
        orderOutCallCount += 1
        isVisible = false
    }

    func orderFrontRegardless() {
        orderFrontCallCount += 1
        isVisible = true
    }
}
