//
//  PickyHUDWorkingFolderPickerCoordinatorTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
private final class WorkingFolderPanelPresenterProbe: PickyHUDWorkingFolderPanelPresenting {
    private(set) var beginCount = 0
    private var completions: [(NSApplication.ModalResponse, URL?) -> Void] = []

    func begin(completion: @escaping (NSApplication.ModalResponse, URL?) -> Void) {
        beginCount += 1
        completions.append(completion)
    }

    func complete(at index: Int = 0, response: NSApplication.ModalResponse, url: URL? = nil) {
        completions[index](response, url)
    }
}

@MainActor
private final class WorkingFolderHUDLevelControllerProbe: PickyHUDWorkingFolderLevelControlling {
    private(set) var lowerCount = 0
    private(set) var restoreCount = 0
    var events: [String] = []

    func lowerHUDPanels() -> @MainActor () -> Void {
        lowerCount += 1
        events.append("lower")
        return { [weak self] in
            self?.restoreCount += 1
            self?.events.append("restore")
        }
    }
}

@MainActor
struct PickyHUDWorkingFolderPickerCoordinatorTests {
    @Test func duplicatePresentationIsRejectedUntilTheActivePanelCompletes() {
        let presenter = WorkingFolderPanelPresenterProbe()
        let levels = WorkingFolderHUDLevelControllerProbe()
        let coordinator = PickyHUDWorkingFolderPickerCoordinator(
            presenter: presenter,
            levelController: levels
        )

        let firstStarted = coordinator.beginSelection { _ in }
        let duplicateStarted = coordinator.beginSelection { _ in }

        #expect(firstStarted)
        #expect(!duplicateStarted)
        #expect(presenter.beginCount == 1)
        #expect(levels.lowerCount == 1)

        presenter.complete(response: .cancel)

        #expect(!coordinator.isPresenting)
        #expect(levels.restoreCount == 1)
        #expect(coordinator.beginSelection { _ in })
        #expect(presenter.beginCount == 2)
    }

    @Test func acceptedSelectionRestoresHUDLevelsBeforeDeliveringTheFolder() {
        let presenter = WorkingFolderPanelPresenterProbe()
        let levels = WorkingFolderHUDLevelControllerProbe()
        let coordinator = PickyHUDWorkingFolderPickerCoordinator(
            presenter: presenter,
            levelController: levels
        )
        var selectedPath: String?

        coordinator.beginSelection { url in
            levels.events.append("selection")
            selectedPath = url.path
        }
        presenter.complete(response: .OK, url: URL(fileURLWithPath: "/tmp/project"))

        #expect(selectedPath == "/tmp/project")
        #expect(levels.events == ["lower", "restore", "selection"])
        #expect(levels.restoreCount == 1)
    }

    @Test func cancelledSelectionRestoresHUDLevelsWithoutDeliveringAFolder() {
        let presenter = WorkingFolderPanelPresenterProbe()
        let levels = WorkingFolderHUDLevelControllerProbe()
        let coordinator = PickyHUDWorkingFolderPickerCoordinator(
            presenter: presenter,
            levelController: levels
        )
        var selectionCount = 0

        coordinator.beginSelection { _ in selectionCount += 1 }
        presenter.complete(response: .cancel)

        #expect(selectionCount == 0)
        #expect(levels.restoreCount == 1)
        #expect(!coordinator.isPresenting)
    }

    @Test func removedTargetGroupFallsBackToUngroupedPlacement() {
        let layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "existing"))
        ])

        #expect(PickyHUDWorkingFolderTargetPolicy.resolvedGroupID("existing", in: layout) == "existing")
        #expect(PickyHUDWorkingFolderTargetPolicy.resolvedGroupID("removed", in: layout) == nil)
        #expect(PickyHUDWorkingFolderTargetPolicy.resolvedGroupID(nil, in: layout) == nil)
    }
}
