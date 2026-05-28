//
//  PickyFullscreenCoordinator.swift
//  Picky
//
//  AppKit lifecycle coordinator for the fullscreen workspace shell.
//

import AppKit

@MainActor
final class PickyFullscreenCoordinator: NSObject {
    private let viewModel: PickySessionListViewModel
    private let stateStore: PickyFullscreenStateStore
    private let appearanceStore: PickyAppearanceStore
    private let fontScaleStore: PickyAppFontScaleStore
    private let onDidClose: @MainActor () -> Void
    private var windowController: PickyFullscreenWindowController?

    init(
        viewModel: PickySessionListViewModel,
        stateStore: PickyFullscreenStateStore? = nil,
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        onDidClose: @escaping @MainActor () -> Void = { }
    ) {
        self.viewModel = viewModel
        self.stateStore = stateStore ?? PickyFullscreenStateStore()
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.onDidClose = onDidClose
        super.init()
    }

    var isOpen: Bool {
        windowController != nil
    }

    func open(sessionID: String?) {
        stateStore.selectedSessionID = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: sessionID,
            storedSelectedSessionID: stateStore.selectedSessionID,
            viewModelSelectedSessionID: viewModel.selectedSessionID,
            candidates: PickyFullscreenSessionSelection.candidates(from: viewModel.sessions)
        )

        if let windowController {
            windowController.show()
            return
        }

        let controller = PickyFullscreenWindowController(
            viewModel: viewModel,
            stateStore: stateStore,
            appearanceStore: appearanceStore,
            fontScaleStore: fontScaleStore,
            onClose: { [weak self] closedController in
                self?.windowDidClose(closedController)
            }
        )
        windowController = controller
        controller.show()
    }

    func close() {
        guard let controller = windowController else { return }
        controller.closeWindow()
    }

    func toggle(sessionID: String?) {
        if isOpen {
            close()
        } else {
            open(sessionID: sessionID)
        }
    }

    private func windowDidClose(_ closedController: PickyFullscreenWindowController) {
        guard windowController === closedController else { return }
        windowController = nil
        onDidClose()
    }
}
