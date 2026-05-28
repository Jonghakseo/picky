//
//  PickyFullscreenModeControllerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
@Suite("PickyFullscreenModeController")
struct PickyFullscreenModeControllerTests {
    @Test func openHidesHUDBeforeOpeningFullscreen() {
        let fullscreen = FakeFullscreenCoordinator()
        let hud = FakeHUDVisibilityController()
        let controller = PickyFullscreenModeController(
            fullscreenCoordinator: fullscreen,
            hudVisibilityController: hud
        )

        controller.open(sessionID: "session-1")

        #expect(hud.hideCount == 1)
        #expect(fullscreen.openedSessionIDs == [Optional("session-1")])
        #expect(!hud.isHUDVisibleForFullscreen)
    }

    @Test func repeatedOpenDoesNotHideHUDAgain() {
        let fullscreen = FakeFullscreenCoordinator()
        let hud = FakeHUDVisibilityController()
        let controller = PickyFullscreenModeController(
            fullscreenCoordinator: fullscreen,
            hudVisibilityController: hud
        )

        controller.open(sessionID: "session-1")
        controller.open(sessionID: "session-2")

        #expect(hud.hideCount == 1)
        #expect(fullscreen.openedSessionIDs == [Optional("session-1"), Optional("session-2")])
    }

    @Test func fullscreenCloseRestoresHUDOnce() {
        let fullscreen = FakeFullscreenCoordinator()
        let hud = FakeHUDVisibilityController()
        let controller = PickyFullscreenModeController(
            fullscreenCoordinator: fullscreen,
            hudVisibilityController: hud
        )

        controller.open(sessionID: nil)
        fullscreen.isOpen = false
        controller.fullscreenDidClose()
        controller.fullscreenDidClose()

        #expect(hud.restoreCount == 1)
        #expect(hud.isHUDVisibleForFullscreen)
    }

    @Test func closeWithoutOpenRestoresOnlyIfHUDIsHidden() {
        let fullscreen = FakeFullscreenCoordinator()
        let hud = FakeHUDVisibilityController()
        let controller = PickyFullscreenModeController(
            fullscreenCoordinator: fullscreen,
            hudVisibilityController: hud
        )

        controller.close()
        #expect(hud.restoreCount == 0)

        hud.hideForFullscreen()
        controller.close()
        #expect(hud.restoreCount == 1)
    }
}

@MainActor
private final class FakeFullscreenCoordinator: PickyFullscreenCoordinating {
    var isOpen = false
    private(set) var openedSessionIDs: [String?] = []
    private(set) var closeCount = 0

    func open(sessionID: String?) {
        isOpen = true
        openedSessionIDs.append(sessionID)
    }

    func close() {
        closeCount += 1
        isOpen = false
    }

    func toggle(sessionID: String?) {
        if isOpen {
            close()
        } else {
            open(sessionID: sessionID)
        }
    }
}

@MainActor
private final class FakeHUDVisibilityController: PickyHUDVisibilityControlling {
    private(set) var isHUDVisibleForFullscreen = true
    private(set) var hideCount = 0
    private(set) var restoreCount = 0

    func hideForFullscreen() {
        guard isHUDVisibleForFullscreen else { return }
        isHUDVisibleForFullscreen = false
        hideCount += 1
    }

    func restoreAfterFullscreen() {
        guard !isHUDVisibleForFullscreen else { return }
        isHUDVisibleForFullscreen = true
        restoreCount += 1
    }
}
