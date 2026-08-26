//
//  PickyHUDWorkingFolderPickerCoordinator.swift
//  Picky
//
//  Owns the app-wide working-folder panel lifecycle so repeated HUD actions
//  cannot present overlapping panels or leak temporary HUD window levels.
//

import AppKit
import Foundation

@MainActor
protocol PickyHUDWorkingFolderPanelPresenting: AnyObject {
    func begin(completion: @escaping (NSApplication.ModalResponse, URL?) -> Void)
}

@MainActor
protocol PickyHUDWorkingFolderLevelControlling: AnyObject {
    func lowerHUDPanels() -> @MainActor () -> Void
}

@MainActor
final class PickyHUDWorkingFolderPickerCoordinator {
    static let shared = PickyHUDWorkingFolderPickerCoordinator()

    private let presenter: any PickyHUDWorkingFolderPanelPresenting
    private let levelController: any PickyHUDWorkingFolderLevelControlling
    private var activePresentationID: UUID?

    var isPresenting: Bool { activePresentationID != nil }

    convenience init() {
        self.init(
            presenter: PickyHUDWorkingFolderOpenPanelPresenter(),
            levelController: PickyHUDWorkingFolderLevelController()
        )
    }

    init(
        presenter: any PickyHUDWorkingFolderPanelPresenting,
        levelController: any PickyHUDWorkingFolderLevelControlling
    ) {
        self.presenter = presenter
        self.levelController = levelController
    }

    @discardableResult
    func beginSelection(onSelection: @escaping (URL) -> Void) -> Bool {
        guard activePresentationID == nil else { return false }

        let presentationID = UUID()
        activePresentationID = presentationID
        let restoreHUDLevels = levelController.lowerHUDPanels()

        presenter.begin { [self] response, url in
            guard activePresentationID == presentationID else { return }
            activePresentationID = nil
            restoreHUDLevels()

            guard response == .OK, let url else { return }
            onSelection(url)
        }
        return true
    }
}

@MainActor
private final class PickyHUDWorkingFolderOpenPanelPresenter: PickyHUDWorkingFolderPanelPresenting {
    private var activePanel: NSOpenPanel?

    func begin(completion: @escaping (NSApplication.ModalResponse, URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.prompt = "Start"
        panel.message = "Choose the folder where the new Pickle should run."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        activePanel = panel

        panel.begin { [self] response in
            let selectedURL = panel.url
            activePanel = nil
            completion(response, selectedURL)
        }
    }
}

@MainActor
private final class PickyHUDWorkingFolderLevelController: PickyHUDWorkingFolderLevelControlling {
    func lowerHUDPanels() -> @MainActor () -> Void {
        let originalLevels = NSApp.windows.compactMap { window -> (PickyHUDPanel, NSWindow.Level)? in
            guard let panel = window as? PickyHUDPanel else { return nil }
            return (panel, panel.level)
        }
        originalLevels.forEach { panel, _ in
            panel.level = .floating
        }
        return {
            originalLevels.forEach { panel, level in
                panel.level = level
            }
        }
    }
}

enum PickyHUDWorkingFolderTargetPolicy {
    static func resolvedGroupID(_ requestedGroupID: String?, in layout: PickyDockLayout) -> String? {
        guard let requestedGroupID,
              layout.group(withID: requestedGroupID) != nil
        else { return nil }
        return requestedGroupID
    }
}
