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

    func testPruneRetainsArchivedGroupMembersButStillDropsTopLevelAndUnknown() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "archivedTop"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .teal, memberSessionIDs: ["b", "archivedMember", "gone"]))
        ])
        let changed = layout.pruneUnknownSessions(
            universe: ["a", "b"],
            retainedGroupMemberIDs: ["archivedMember", "archivedTop"]
        )
        XCTAssertTrue(changed)
        // Top-level retention does not apply: archivedTop is dropped because
        // the active universe no longer contains it.
        XCTAssertEqual(layout.entries.count, 2)
        // "gone" (neither active nor retained) is pruned; "archivedMember" is
        // kept so an archived Pickle restores back into its group.
        guard case .group(let g) = layout.entries[1] else {
            return XCTFail("expected group entry retained")
        }
        XCTAssertEqual(g.memberSessionIDs, ["b", "archivedMember"])
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

    func testMoveWithinSameTopLevelLandsOnRequestedSlot() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .session(id: "c")
        ])
        // Drag UX: `target` is the desired *final* position. From idx 0 to
        // idx 1 should produce [b, a, c]; from idx 0 to idx 2 should
        // produce [b, c, a].
        layout.move(session: "a", to: .topLevel(index: 1))
        var ids: [String] = layout.entries.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
        XCTAssertEqual(ids, ["b", "a", "c"])

        layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .session(id: "c")
        ])
        layout.move(session: "a", to: .topLevel(index: 2))
        ids = layout.entries.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
        XCTAssertEqual(ids, ["b", "c", "a"])
    }

    func testMoveSessionUpwardLandsOnRequestedSlot() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .session(id: "c")
        ])
        layout.move(session: "c", to: .topLevel(index: 0))
        let ids: [String] = layout.entries.compactMap {
            if case .session(let id) = $0 { return id }
            return nil
        }
        XCTAssertEqual(ids, ["c", "a", "b"])
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

    func testMoveGroupLandsOnRequestedSlot() {
        var layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", name: "A", color: .teal, memberSessionIDs: ["s1"])),
            .session(id: "s2"),
            .session(id: "s3"),
            .group(PickyDockGroup(id: "g4", name: "D", color: .pink, memberSessionIDs: ["s4"]))
        ])
        // Header drag UX: target = final position. Move g1 from idx 0 to
        // idx 2 should put g1 between s3 and g4 in the final array.
        layout.moveGroup(id: "g1", toTopLevelIndex: 2)
        let kinds: [String] = layout.entries.map {
            switch $0 {
            case .session(let id): return "session:\(id)"
            case .group(let g): return "group:\(g.id)"
            }
        }
        XCTAssertEqual(kinds, ["session:s2", "session:s3", "group:g1", "group:g4"])
    }

    func testMoveGroupUpwardKeepsTargetIndex() {
        var layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .session(id: "s2"),
            .group(PickyDockGroup(id: "g3", name: "C", color: .blue, memberSessionIDs: ["s3"])),
            .session(id: "s4")
        ])
        // Move g3 upward to position 0 (top of dock).
        layout.moveGroup(id: "g3", toTopLevelIndex: 0)
        let kinds: [String] = layout.entries.map {
            switch $0 {
            case .session(let id): return "session:\(id)"
            case .group(let g): return "group:\(g.id)"
            }
        }
        XCTAssertEqual(kinds, ["group:g3", "session:s1", "session:s2", "session:s4"])
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

    func testProjectorEmitsOneTopLevelSlotPerGroupInDockOrder() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", name: "Web", color: .teal, memberSessionIDs: ["s2", "s3"])),
            .session(id: "s4")
        ])
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["s1", "s2", "s3", "s4"]
        )
        XCTAssertEqual(projection.items.count, 3)
        XCTAssertEqual(projection.slots.map(\.visibleIndex), [0, 1, 2])
        XCTAssertEqual(
            projection.slots.map(\.target),
            [
                .session(id: "s1", container: .topLevel(index: 0)),
                .group(id: "g1"),
                .session(id: "s4", container: .topLevel(index: 2)),
            ]
        )
    }

    func testProjectorIgnoresLegacyCollapseStateForFolderRendering() {
        let layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", name: "Web", color: .teal, memberSessionIDs: ["s1", "s2"], isCollapsed: false)),
            .session(id: "s3")
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2", "s3"])
        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(projection.slots.map(\.visibleIndex), [0, 1])
        XCTAssertEqual(projection.slots.first?.target, .group(id: "g1"))
    }

    func testProjectorAppendsBrandNewSessionsAtBottom() {
        let layout = PickyDockLayout(entries: [.session(id: "s1")])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])
        XCTAssertEqual(projection.slots.compactMap(\.sessionID), ["s1", "s2"])
    }

    func testProjectorKeepsAGroupSlotWhenItsMembersAreNotVisible() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", name: "G", color: .teal, memberSessionIDs: ["archived"])),
            .session(id: "s2")
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])
        XCTAssertEqual(projection.slots.count, 3)
        XCTAssertEqual(projection.slots[1].target, .group(id: "g1"))
        XCTAssertEqual(projection.slots[1].visibleIndex, 1)
    }

    func testThirdTopLevelShortcutResolvesToFolderTarget() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .session(id: "s2"),
            .group(PickyDockGroup(id: "g3", memberSessionIDs: []))
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])
        XCTAssertEqual(projection.slots[2].visibleIndex, 2)
        XCTAssertEqual(projection.slots[2].target, .group(id: "g3"))
    }

    func testRenderItemsHaveStableIdentityAcrossTopLevelReorder() {
        var layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", memberSessionIDs: ["s2"]))
        ])
        let before = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])
        layout.moveGroup(id: "g1", toTopLevelIndex: 0)
        let after = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])

        XCTAssertEqual(before.items.map(\.stableID), ["session:s1", "group:g1"])
        XCTAssertEqual(after.items.map(\.stableID), ["group:g1", "session:s1"])
        XCTAssertEqual(PickyDockRenderItem.group(PickyDockGroup(id: "g1")).stableID, "group:g1")
    }

    func testCycleOrderChangesWhenTopLevelDockOrderIsReordered() {
        var layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g", memberSessionIDs: ["b", "a"])),
            .session(id: "c")
        ])
        let activeSessionIDs = ["a", "b", "c", "new"]
        let before = PickyDockProjector.cycleSessionIDs(layout: layout, activeSessionIDs: activeSessionIDs)
        layout.moveGroup(id: "g", toTopLevelIndex: 1)
        let after = PickyDockProjector.cycleSessionIDs(layout: layout, activeSessionIDs: activeSessionIDs)

        XCTAssertEqual(before, ["b", "a", "c", "new"])
        XCTAssertEqual(after, ["c", "b", "a", "new"])
    }

    func testScrollTargetUsesOwningFolderForGroupedActiveSession() {
        let layout = PickyDockLayout(entries: [
            .session(id: "s1"),
            .group(PickyDockGroup(id: "g1", memberSessionIDs: ["s2"]))
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["s1", "s2"])

        XCTAssertEqual(projection.scrollTargetID(forSessionID: "s1"), "session:s1")
        XCTAssertEqual(projection.scrollTargetID(forSessionID: "s2"), "group:g1")
    }

    func testHiddenArchivedMemberOrderingUsesFullMemberIndexPolicy() {
        let memberIDs = ["hidden1", "hidden2", "m1", "m2", "m3"]
        let activeIDs: Set<String> = ["m1", "m2", "m3"]
        let insertionIndex = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: 3,
            memberSessionIDs: memberIDs,
            activeSessionIDs: activeIDs
        )
        XCTAssertEqual(insertionIndex, memberIDs.count)
        var layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g1", memberSessionIDs: memberIDs)),
            .session(id: "loose")
        ])
        layout.move(session: "loose", to: .group(id: "g1", memberIndex: insertionIndex))
        XCTAssertEqual(layout.group(withID: "g1")?.memberSessionIDs, memberIDs + ["loose"])
    }

    // MARK: - Create with members

    func testCreateGroupWithMembersRemovesFromPreviousContainers() {
        var layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b"),
            .group(PickyDockGroup(
                id: "g1", name: "Old", color: .teal,
                memberSessionIDs: ["c", "d"]
            )),
            .session(id: "e")
        ])
        // Simulate VM logic by hand: remove members, append a new group.
        let pickedMembers = ["a", "c", "e"]
        var orderedMembers: [String] = []
        var seen = Set<String>()
        for memberID in pickedMembers where !seen.contains(memberID) {
            seen.insert(memberID)
            _ = layout.removeSession(memberID)
            orderedMembers.append(memberID)
        }
        let newGroup = PickyDockGroup(
            id: "g2", name: "product", color: .amber,
            memberSessionIDs: orderedMembers
        )
        layout.entries.append(.group(newGroup))

        // Top-level entries left: b, g1(only d), e was removed from top, so just
        // b and g1, plus the new g2 at the end.
        let kinds: [String] = layout.entries.map {
            switch $0 {
            case .session(let id): return "session:\(id)"
            case .group(let g): return "group:\(g.id)"
            }
        }
        XCTAssertEqual(kinds, ["session:b", "group:g1", "group:g2"])

        // g1 lost c, kept d.
        guard case .group(let oldGroup) = layout.entries[1] else {
            return XCTFail("expected g1 to remain in place")
        }
        XCTAssertEqual(oldGroup.memberSessionIDs, ["d"])

        // g2 has the picked members in the requested order.
        guard case .group(let createdGroup) = layout.entries.last else {
            return XCTFail("expected g2 to be the last entry")
        }
        XCTAssertEqual(createdGroup.memberSessionIDs, ["a", "c", "e"])
    }

    // MARK: - Color defaults

    func testNewGroupsDefaultToGray() {
        XCTAssertEqual(PickyDockGroupColor.defaultColor, .gray)
    }

    func testPaletteUsesNotionDisplayOrder() {
        XCTAssertEqual(
            PickyDockGroupColor.palette,
            [.gray, .amber, .teal, .blue, .purple, .pink, .red]
        )
    }

    // MARK: - Drag drop resolution (PickyDockDropResolver)

    func testFolderDropUsesFullMemberIndexWhenArchivedMembersPrecedeVisibleRows() {
        var layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "g", memberSessionIDs: ["archived", "active"]))
        ])
        let projection = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["loose", "active"]
        )
        let slotCandidates = projection.slots.compactMap { slot -> PickyDockDropResolver.SlotCandidate? in
            guard let container = slot.container else { return nil }
            return .init(container: container, center: 0)
        }
        let group = try! XCTUnwrap(layout.group(withID: "g"))
        let groupCandidate = PickyDockDropResolver.EmptyGroupCandidate(
            groupID: group.id,
            memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 0,
                memberSessionIDs: group.memberSessionIDs,
                activeSessionIDs: ["loose", "active"]
            ),
            center: 100
        )

        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 100,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: [groupCandidate],
            layout: layout,
            slotPitch: 100
        )

        XCTAssertEqual(destination, .group(id: "g", memberIndex: 1))
        layout.move(session: "loose", to: try! XCTUnwrap(destination))
        XCTAssertEqual(layout.group(withID: "g")?.memberSessionIDs, ["archived", "loose", "active"])
    }

    func testDropInsideBottomFolderBoundsUsesTheFolderCandidate() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty", memberSessionIDs: []))
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["loose"])
        let slotCandidates = projection.slots.compactMap { slot -> PickyDockDropResolver.SlotCandidate? in
            guard let container = slot.container else { return nil }
            return .init(container: container, center: 0)
        }

        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 100,
            slotCandidates: slotCandidates,
            emptyGroupCandidates: [.init(groupID: "empty", center: 100)],
            layout: layout,
            slotPitch: 100,
            groupDropHalfExtent: 35
        )

        XCTAssertEqual(destination, .group(id: "empty", memberIndex: 0))
    }

    func testDragPastBottomFolderBoundsAppendsAtTopLevel() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty", memberSessionIDs: []))
        ])

        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 145,
            slotCandidates: [.init(container: .topLevel(index: 0), center: 0)],
            emptyGroupCandidates: [.init(groupID: "empty", center: 100)],
            layout: layout,
            slotPitch: 100,
            groupDropHalfExtent: 35
        )

        XCTAssertEqual(destination, .topLevel(index: 2))
    }

    /// When the last entry is an ungrouped session, dragging past it appends at
    /// the top level as before.
    func testDragPastBottomUngroupedSessionAppendsTopLevel() {
        let layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ])
        let result = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "a",
            cursorAxis: 180,
            slotCandidates: [
                .init(container: .topLevel(index: 0), center: 0),
                .init(container: .topLevel(index: 1), center: 100)
            ],
            emptyGroupCandidates: [],
            layout: layout,
            slotPitch: 100
        )
        XCTAssertEqual(result, .topLevel(index: 2))
    }

    func testDragPastTopFolderBoundsInsertsAtTopLevelZero() {
        let layout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "g", memberSessionIDs: [])),
            .session(id: "b")
        ])
        let result = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "b",
            cursorAxis: -45,
            slotCandidates: [.init(container: .topLevel(index: 1), center: 100)],
            emptyGroupCandidates: [.init(groupID: "g", center: 0)],
            layout: layout,
            slotPitch: 100,
            groupDropHalfExtent: 35
        )
        XCTAssertEqual(result, .topLevel(index: 0))
    }

    /// Top escape still works when the first entry is an ungrouped session.
    func testDragAboveTopUngroupedSessionInsertsAtTopLevelZero() {
        let layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .session(id: "b")
        ])
        let result = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "b",
            cursorAxis: -80,
            slotCandidates: [
                .init(container: .topLevel(index: 0), center: 0),
                .init(container: .topLevel(index: 1), center: 100)
            ],
            emptyGroupCandidates: [],
            layout: layout,
            slotPitch: 100
        )
        XCTAssertEqual(result, .topLevel(index: 0))
    }
}
