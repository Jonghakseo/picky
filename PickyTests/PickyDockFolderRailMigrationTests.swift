//
//  PickyDockFolderRailMigrationTests.swift
//  PickyTests
//
//  Folder-rail migration closes legacy expanded groups and writes the result
//  immediately, rather than leaving persisted and runtime layouts divergent.
//

import XCTest
@testable import Picky

@MainActor
final class PickyDockFolderRailMigrationTests: XCTestCase {
    func testLoadingLegacyExpandedGroupsWritesThroughTheAllClosedLayoutOnce() {
        let store = FolderRailMigrationStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "a", memberSessionIDs: ["one"], isCollapsed: false)),
            .group(PickyDockGroup(id: "b", memberSessionIDs: ["two"], isCollapsed: false))
        ]))

        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(controller.layout.groups.allSatisfy(\.isCollapsed))
        XCTAssertEqual(store.savedLayouts.count, 1)
        XCTAssertTrue(store.savedLayouts[0].groups.allSatisfy(\.isCollapsed))
    }

    func testLoadingAnAlreadyClosedLayoutDoesNotWriteAgain() {
        let store = FolderRailMigrationStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "a", memberSessionIDs: ["one"], isCollapsed: true))
        ]))

        _ = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(store.savedLayouts.isEmpty)
    }
}

@MainActor
private final class FolderRailMigrationStore: PickyDockLayoutStoring {
    private var storedLayout: PickyDockLayout
    var savedLayouts: [PickyDockLayout] = []

    init(layout: PickyDockLayout) {
        storedLayout = layout
    }

    func load() -> PickyDockLayout { storedLayout }

    func enqueueSave(
        _ layout: PickyDockLayout,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        storedLayout = layout
        savedLayouts.append(layout)
        completion(.success(()))
    }
}
