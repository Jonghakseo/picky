//
//  PickyFullscreenModeController.swift
//  Picky
//
//  Owns the mode transition between the compact HUD dock and fullscreen
//  workspace. It deliberately does not mutate Pickle sessions.
//

import Foundation

@MainActor
protocol PickyFullscreenCoordinating: AnyObject {
    var isOpen: Bool { get }
    func open(sessionID: String?)
    func close()
    func toggle(sessionID: String?)
}

@MainActor
final class PickyFullscreenModeController {
    private let fullscreenCoordinator: PickyFullscreenCoordinating
    private let hudVisibilityController: PickyHUDVisibilityControlling

    init(
        fullscreenCoordinator: PickyFullscreenCoordinating,
        hudVisibilityController: PickyHUDVisibilityControlling
    ) {
        self.fullscreenCoordinator = fullscreenCoordinator
        self.hudVisibilityController = hudVisibilityController
    }

    var isFullscreenOpen: Bool {
        fullscreenCoordinator.isOpen
    }

    func open(sessionID: String?) {
        if hudVisibilityController.isHUDVisibleForFullscreen {
            hudVisibilityController.hideForFullscreen()
        }
        fullscreenCoordinator.open(sessionID: sessionID)
    }

    func close() {
        guard fullscreenCoordinator.isOpen else {
            if !hudVisibilityController.isHUDVisibleForFullscreen {
                hudVisibilityController.restoreAfterFullscreen()
            }
            return
        }
        fullscreenCoordinator.close()
    }

    func fullscreenDidClose() {
        if !hudVisibilityController.isHUDVisibleForFullscreen {
            hudVisibilityController.restoreAfterFullscreen()
        }
    }

    func toggle(sessionID: String?) {
        if fullscreenCoordinator.isOpen {
            close()
        } else {
            open(sessionID: sessionID)
        }
    }
}

extension PickyFullscreenCoordinator: PickyFullscreenCoordinating {}
