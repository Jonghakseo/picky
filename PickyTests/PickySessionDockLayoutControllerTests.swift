//
//  PickySessionDockLayoutControllerTests.swift
//  PickyTests
//
//  Characterization coverage for the dock-layout controller that owns
//  persistence + ViewModel-facing dock layout mutations.
//

import XCTest
@testable import Picky

@MainActor
final class PickySessionDockLayoutControllerTests: XCTestCase {
    func testReconcileMigratesLegacyManualOrderIntoEmptyLayout() {
        let store = FakeDockLayoutStore(layout: .empty)
        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(controller.reconcile(activeSessionIDs: ["new", "b", "a"], legacyManualOrder: ["b", "a", "missing"]))

        XCTAssertEqual(controller.layout.sessionIDs, ["a", "b", "new"])
        XCTAssertEqual(store.savedLayouts.map(\.sessionIDs), [["a", "b", "new"]])
    }

    func testReconcileAppendsNewActiveSessionsAtDockBottom() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [.session(id: "old")]))
        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(controller.reconcile(activeSessionIDs: ["new", "old"], legacyManualOrder: []))

        XCTAssertEqual(controller.layout.sessionIDs, ["old", "new"])
        XCTAssertEqual(store.savedLayouts.map(\.sessionIDs), [["old", "new"]])
    }

    func testReconcilePrunesUnknownSessionsAndGroupMembers() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .teal, memberSessionIDs: ["b", "missing"])),
            .session(id: "gone")
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        XCTAssertTrue(controller.reconcile(activeSessionIDs: ["a", "b"], legacyManualOrder: []))

        XCTAssertEqual(controller.layout.entryDescriptions, ["session:a", "group:g[b]"])
        XCTAssertEqual(store.savedLayouts.map(\.entryDescriptions), [["session:a", "group:g[b]"]])
    }

    func testCreateGroupTrimsNameDedupesMembersAndRemovesPreviousContainers() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .group(PickyDockGroup(id: "old", name: "Old", color: .blue, memberSessionIDs: ["c", "d"])),
            .session(id: "e")
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        let groupID = controller.createGroup(name: "  Product  ", withMemberIDs: ["a", "c", "a", "e"])

        XCTAssertEqual(controller.layout.entryDescriptions, ["session:b", "group:old[d]", "group:\(groupID)[a,c,e]"])
        guard case .group(let created) = controller.layout.entries.last else {
            return XCTFail("expected created group at bottom")
        }
        XCTAssertEqual(created.name, "Product")
        XCTAssertEqual(created.color, PickyDockGroupColor.defaultColor)
        XCTAssertEqual(store.savedLayouts.last?.entryDescriptions, ["session:b", "group:old[d]", "group:\(groupID)[a,c,e]"])
    }

    func testRemoveGroupKeepingMembersSplicesMembersBackAndPersists() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .teal, memberSessionIDs: ["b", "c"])),
            .session(id: "d")
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        let removed = controller.removeGroup(id: "g", keepMembers: true)

        XCTAssertEqual(removed, [])
        XCTAssertEqual(controller.layout.sessionIDs, ["a", "b", "c", "d"])
        XCTAssertEqual(store.savedLayouts.map(\.sessionIDs), [["a", "b", "c", "d"]])
    }

    func testRemoveGroupForArchiveReturnsMemberIDsAndPersists() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .red, memberSessionIDs: ["b", "c"]))
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        let removed = controller.removeGroup(id: "g", keepMembers: false)

        XCTAssertEqual(removed, ["b", "c"])
        XCTAssertEqual(controller.layout.sessionIDs, ["a"])
        XCTAssertEqual(store.savedLayouts.map(\.sessionIDs), [["a"]])
    }

    func testArchivedGroupMemberIsRetainedAndRestoresIntoOriginalGroup() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .teal, memberSessionIDs: ["b", "c"]))
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        // Archive "b": it leaves the active universe but is still known
        // (archived), so its group membership must be retained.
        XCTAssertFalse(controller.reconcile(
            activeSessionIDs: ["c", "a"],
            archivedSessionIDs: ["b"],
            legacyManualOrder: []
        ))
        XCTAssertEqual(controller.layout.entryDescriptions, ["session:a", "group:g[b,c]"])

        // Unarchive "b": it re-enters the active universe and stays inside its
        // original group at its original member position instead of leaking
        // out to the top level.
        XCTAssertFalse(controller.reconcile(
            activeSessionIDs: ["b", "c", "a"],
            archivedSessionIDs: [],
            legacyManualOrder: []
        ))
        XCTAssertEqual(controller.layout.entryDescriptions, ["session:a", "group:g[b,c]"])
        // No layout change was ever persisted across the archive/restore cycle.
        XCTAssertEqual(store.savedLayouts.map(\.entryDescriptions), [])
    }

    func testDeletedGroupMemberIsPrunedWhenNeitherActiveNorArchived() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .teal, memberSessionIDs: ["b", "gone"]))
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        // "gone" is permanently deleted: absent from both active and archived
        // universes, so it must be pruned from the group.
        XCTAssertTrue(controller.reconcile(
            activeSessionIDs: ["b", "a"],
            archivedSessionIDs: [],
            legacyManualOrder: []
        ))
        XCTAssertEqual(controller.layout.entryDescriptions, ["session:a", "group:g[b]"])
    }

    func testArchivedGroupMembersReconcileBackAsUngroupedBottomSessionsWhenUnarchived() {
        let store = FakeDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g", name: "G", color: .red, memberSessionIDs: ["b", "c"]))
        ]))
        let controller = PickySessionDockLayoutController(store: store)

        _ = controller.removeGroup(id: "g", keepMembers: false)
        XCTAssertTrue(controller.reconcile(activeSessionIDs: ["c", "b", "a"], legacyManualOrder: []))

        XCTAssertEqual(controller.layout.entryDescriptions, ["session:a", "session:b", "session:c"])
        XCTAssertEqual(store.savedLayouts.map(\.entryDescriptions), [
            ["session:a"],
            ["session:a", "session:b", "session:c"]
        ])
    }

    func testSaveFailureDoesNotCrashAndStillUpdatesControllerLayout() {
        let store = FakeDockLayoutStore(layout: .empty)
        store.errorToThrow = FakeDockLayoutStore.SaveError.failed
        var errors: [Error] = []
        let controller = PickySessionDockLayoutController(store: store) { errors.append($0) }

        XCTAssertTrue(controller.reconcile(activeSessionIDs: ["a"], legacyManualOrder: []))

        XCTAssertEqual(controller.layout.sessionIDs, ["a"])
        XCTAssertEqual(store.savedLayouts.map(\.sessionIDs), [])
        XCTAssertEqual(errors.count, 1)
    }
}

private final class FakeDockLayoutStore: PickyDockLayoutStoring {
    enum SaveError: Error { case failed }

    private var storedLayout: PickyDockLayout
    var savedLayouts: [PickyDockLayout] = []
    var errorToThrow: Error?

    init(layout: PickyDockLayout) {
        self.storedLayout = layout
    }

    func load() -> PickyDockLayout {
        storedLayout
    }

    func save(_ layout: PickyDockLayout) throws {
        if let errorToThrow { throw errorToThrow }
        storedLayout = layout
        savedLayouts.append(layout)
    }
}

private extension PickyDockLayout {
    var sessionIDs: [String] {
        entries.flatMap { entry -> [String] in
            switch entry {
            case .session(let id): [id]
            case .group(let group): group.memberSessionIDs
            }
        }
    }

    var entryDescriptions: [String] {
        entries.map { entry in
            switch entry {
            case .session(let id): "session:\(id)"
            case .group(let group): "group:\(group.id)[\(group.memberSessionIDs.joined(separator: ","))]"
            }
        }
    }
}
