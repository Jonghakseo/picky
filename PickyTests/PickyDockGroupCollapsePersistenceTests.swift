//
//  PickyDockGroupCollapsePersistenceTests.swift
//  PickyTests
//
//  A group's expanded/collapsed state is durable dock layout: it survives a
//  reload and changes only through an explicit toggle.
//

import XCTest
@testable import Picky

@MainActor
final class PickyDockGroupCollapsePersistenceTests: XCTestCase {
    func testLoadingKeepsEachGroupsStoredStateWithoutRewriting() {
        let store = CollapseRecordingStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "open", memberSessionIDs: ["one"], isCollapsed: false)),
            .group(PickyDockGroup(id: "closed", memberSessionIDs: ["two"], isCollapsed: true))
        ]))

        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertEqual(controller.layout.group(withID: "open")?.isCollapsed, false)
        XCTAssertEqual(controller.layout.group(withID: "closed")?.isCollapsed, true)
        XCTAssertTrue(store.savedLayouts.isEmpty)
    }

    func testTogglingAGroupPersistsTheNewStateOnce() {
        let store = CollapseRecordingStore(layout: PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g", memberSessionIDs: ["one"], isCollapsed: true))
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(controller.setGroupCollapsed(id: "g", collapsed: false))
        XCTAssertFalse(controller.setGroupCollapsed(id: "g", collapsed: false))

        XCTAssertEqual(store.savedLayouts.count, 1)
        XCTAssertEqual(store.savedLayouts.last?.group(withID: "g")?.isCollapsed, false)
    }

    func testNewGroupsOpenExpandedSoTheirMembersShow() {
        let store = CollapseRecordingStore(layout: PickyDockLayout(entries: [.session(id: "one")]))
        let controller = PickySessionDockLayoutController(store: store)

        let groupID = controller.createGroup(name: "Review", withMemberIDs: ["one"])

        XCTAssertEqual(controller.layout.group(withID: groupID)?.isCollapsed, false)
        let projection = PickyDockProjector.project(layout: controller.layout, visibleSessionIDs: ["one"])
        XCTAssertEqual(projection.shortcutSessionIDs, ["one"])
    }
}

@MainActor
private final class CollapseRecordingStore: PickyDockLayoutStoring {
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
