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
    private let onDidClose: @MainActor () -> Void
    private var windowController: PickyFullscreenWindowController?

    init(
        viewModel: PickySessionListViewModel,
        stateStore: PickyFullscreenStateStore? = nil,
        onDidClose: @escaping @MainActor () -> Void = { }
    ) {
        self.viewModel = viewModel
        self.stateStore = stateStore ?? PickyFullscreenStateStore()
        self.onDidClose = onDidClose
        super.init()
    }

    var isOpen: Bool {
        windowController != nil
    }

    func open(sessionID: String?) {
        if let sessionID {
            stateStore.selectedSessionID = sessionID
        } else if stateStore.selectedSessionID == nil {
            stateStore.selectedSessionID = viewModel.selectedSessionID
        }

        if let windowController {
            windowController.show()
            return
        }

        let controller = PickyFullscreenWindowController(
            viewModel: viewModel,
            stateStore: stateStore,
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
