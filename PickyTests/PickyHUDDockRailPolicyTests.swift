//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//
//  Characterization coverage for pure dock-rail layout, render-plan, and
//  drag-geometry decisions extracted from PickyHUDDockRailView.
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockRailPolicyTests {
    @Test func renderPlanKeepsSessionAndGroupOrderAndFallsBackForStrayMembers() {
        let group = PickyDockGroup(id: "group", name: "Work", memberSessionIDs: ["member"])
        let units = PickyHUDDockRenderPolicy.renderUnits(from: [
            .session(id: "first"),
            .groupHeader(group: group),
            .groupMember(groupID: group.id, sessionID: "member", color: group.color),
            .session(id: "last"),
            .groupMember(groupID: "missing", sessionID: "stray", color: .teal),
        ])

        #expect(units.map(\.id) == ["session:first", "group:group", "session:last", "session:stray"])
        guard case .group(let renderedGroup, let members) = units[1].kind else {
            Issue.record("Expected the second render unit to be the group")
            return
        }
        #expect(renderedGroup.id == group.id)
        #expect(members.map(\.sessionID) == ["member"])
    }

    @Test func layoutCountsHeadersAndEmptyTilesWithoutDependingOnTheView() {
        let expanded = PickyDockGroup(id: "expanded", memberSessionIDs: [])
        let collapsed = PickyDockGroup(id: "collapsed", memberSessionIDs: [], isCollapsed: true)
        let projection = PickyDockProjection(
            items: [
                .groupHeader(group: expanded),
                .collapsedGroup(group: collapsed, topMemberSessionID: nil),
                .session(id: "loose"),
            ],
            slots: [
                PickyDockSlot(sessionID: "loose", container: .topLevel(index: 2), visibleIndex: 0),
            ]
        )
        let metrics = PickyHUDDockMetrics(preset: .medium)

        #expect(PickyHUDDockRailLayoutPolicy.groupHeaderCount(in: projection.items) == 2)
        #expect(PickyHUDDockRailLayoutPolicy.emptyGroupDropTileCount(in: projection) == 2)
        #expect(PickyHUDDockRailLayoutPolicy.horizontalCrossSize(projection: projection, metrics: metrics) > metrics.railWidth)

        let vertical = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 1,
            isAddSlotExpanded: false,
            dockSide: .right,
            projection: projection,
            metrics: metrics
        )
        let horizontal = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 1,
            isAddSlotExpanded: false,
            dockSide: .bottom,
            projection: projection,
            metrics: metrics
        )
        #expect(vertical > 0)
        #expect(horizontal > 0)
        #expect(vertical != horizontal)
    }

    @Test func dragGeometryRespectsDockAxisAndOutwardDirection() {
        let translation = CGSize(width: 30, height: 45)
        let metrics = PickyHUDDockMetrics(preset: .medium)

        #expect(PickyHUDDockDragGeometry.axisDelta(translation, orientation: .horizontal) == 30)
        #expect(PickyHUDDockDragGeometry.axisDelta(translation, orientation: .vertical) == 45)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .left) == 30)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .right) == -30)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .top) == 45)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .bottom) == -45)
        #expect(PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics) == metrics.railWidth * 0.5 + 40)
        #expect(PickyHUDDockDragGeometry.slotPitch(orientation: .horizontal, metrics: metrics) == metrics.sessionTileWidth + metrics.sessionSpacing)
        #expect(PickyHUDDockDragGeometry.slotPitch(orientation: .vertical, metrics: metrics) == metrics.sessionTileHeight + metrics.sessionSpacing)
    }
}
