//
//  PickyDockGroupingTests.swift
//  PickyTests
//
//  Coverage for the persisted dock-layout model and the
//  layout-to-render projection that drives the Pickle dock rail with
//  user-created groups.
//

import XCTest
@testable import Picky

final class PickyDockGroupingTests: XCTestCase {

    // MARK: - Layout mutations

    func testAppendNewSessionIsIdempotent() {
        var layout = PickyDockLayout.empty
        XCTAssertTrue(layout.appendNewSessionIfMissing("a"))
        XCTAssertTrue(layout.appendNewSessionIfMissing("b"))
        XCTAssertFalse(layout.appendNewSessionIfMissing("a"))
        XCTAssertEqual(layout.entries.count, 2)
    }

    func testPruneUnknownDropsTopLevelAndGroupMembers() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .teal, memberSessionIDs: ["b", "c"])),
            .session(id: "d")
        ])
        let changed = layout.pruneUnknownSessions(universe: ["a", "b"])
        XCTAssertTrue(changed)
        // a remains (top-level); g1 keeps only b; d removed entirely.
        XCTAssertEqual(layout.entries.count, 2)
        guard case .group(let g) = layout.entries[1] else {
            return XCTFail("expected group entry retained")
        }
        XCTAssertEqual(g.memberSessionIDs, ["b"])
    }

    func testMoveSessionAcrossContainersIsAtomic() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .blue, memberSessionIDs: ["b"])),
            .session(id: "c")
        ])
        layout.move(session: "a", to: .group(id: "g1", memberIndex: 0))
        XCTAssertNil(layout.container(forSessionID: "a").flatMap { container -> Int? in
            if case .topLevel = container { return 1 }
            return nil
        })
        guard case .group(let g) = layout.entries.first(where: {
            if case .group = $0 { return true }
            return false
        }) else { return XCTFail("group missing") }
        XCTAssertEqual(g.memberSessionIDs, ["a", "b"])
    }

    func testMoveWithinSameTopLevelAdjustsForSelfRemoval() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .session(id: "c")
        ])
        // Move a down to position 2 (between b and c, then after c). Naive
        // remove+insert at idx 2 would land at the very end; adjusted move
        // keeps the request semantically meaningful.
        layout.move(session: "a", to: .topLevel(index: 2))
        let ids: [String] = layout.entries.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
        XCTAssertEqual(ids, ["b", "a", "c"])
    }

    func testUngroupKeepsMembersInOriginalSlot() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .pink, memberSessionIDs: ["b", "c"])),
            .session(id: "d")
        ])
        let removed = layout.removeGroup(id: "g1", keepMembers: true)
        XCTAssertEqual(removed, [])
        let ids: [String] = layout.entries.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
    }

    func testDeleteGroupReturnsMemberIDsForArchive() {
        var layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", name: "G", color: .red, memberSessionIDs: ["b", "c"]))
        ])
        let archived = layout.removeGroup(id: "g1", keepMembers: false)
        XCTAssertEqual(archived, ["b", "c"])
        XCTAssertTrue(layout.entries.isEmpty)
    }

    // MARK: - Projection

    func testProjectorEmitsHeadersAndMembersInOrder() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(
                id: "g1", name: "Web", color: .teal,
                memberSessionIDs: ["s2", "s3"]
            )),
            .session(id: "s4")
        ])
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["s1", "s2", "s3", "s4"]
        )
        XCTAssertEqual(projection.items.count, 5) // session + header + 2 members + session
        XCTAssertEqual(projection.slots.map(\.sessionID), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(projection.slots.map(\.visibleIndex), [0, 1, 2, 3])
    }

    func testProjectorCollapsedGroupEmitsSingleSlot() {
        let layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(
                id: "g1", name: "Web", color: .teal,
                memberSessionIDs: ["s1", "s2", "s3"], isCollapsed: true
            )),
            .session(id: "s4")
        ])
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["s1", "s2", "s3", "s4"]
        )
        // Collapsed group emits one render item + ungrouped session = 2 items.
        XCTAssertEqual(projection.items.count, 2)
        // Slot 0 represents the collapsed group's top member; slot 1 = s4.
        XCTAssertEqual(projection.slots.map(\.sessionID), ["s1", "s4"])
        XCTAssertEqual(projection.slots.map(\.visibleIndex), [0, 1])
    }

    func testProjectorAppendsBrandNewSessionsAtBottom() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1")
        ])
        // s2 unknown to the layout — should appear last (bottom of dock).
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["s1", "s2"]
        )
        XCTAssertEqual(projection.slots.map(\.sessionID), ["s1", "s2"])
    }

    func testProjectorSkipsSessionsNotInVisibleUniverse() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .teal, memberSessionIDs: ["s2", "s3"])),
            .session(id: "s4")
        ])
        // Pretend s3 is older than the visible cap.
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["s1", "s2", "s4"]
        )
        XCTAssertEqual(projection.slots.map(\.sessionID), ["s1", "s2", "s4"])
        XCTAssertEqual(projection.slots.map(\.visibleIndex), [0, 1, 2])
    }

    // MARK: - Color rotation

    func testGroupColorRotationCyclesPalette() {
        let palette = PickyDockGroupColor.palette
        for i in 0..<(palette.count * 2) {
            let expected = palette[i % palette.count]
            XCTAssertEqual(
                PickyDockGroupColor.nextColor(forExistingGroupCount: i),
                expected,
                "color rotation off at i=\(i)"
            )
        }
    }
}
