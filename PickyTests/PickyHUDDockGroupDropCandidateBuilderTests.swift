//
//  PickyHUDDockGroupDropCandidateBuilderTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockGroupDropCandidateBuilderTests {
    @Test func railProjectionBuildsEmptyAndFilledHeaderCandidatesSeparately() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty")),
            .group(PickyDockGroup(id: "filled", memberSessionIDs: ["member"])),
        ])
        let slots = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["loose", "member"]).slots
        let frames: [String: CGRect] = [
            "empty": CGRect(x: 10, y: 70, width: 196, height: 24),
            "filled": CGRect(x: 10, y: 170, width: 196, height: 24),
        ]
        let metrics = PickyHUDDockMetrics(preset: .large)

        let empty = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            topEntryExtents: ["group:empty": .init(lower: 900, upper: 924)],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )
        let filled = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            topEntryExtents: ["group:filled": .init(lower: 900, upper: 924)],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )

        #expect(empty.map { $0.groupID } == ["empty"])
        #expect(empty.first?.center == 82)
        #expect(empty.first?.halfExtent == 12)
        #expect(filled.map { $0.groupID } == ["filled"])
        #expect(filled.first?.center == 182)
        #expect(filled.first?.halfExtent == 12)
    }

    @Test func missingOrEmptyMeasuredFrameFallsBackToTheHeaderAtTheGroupsLeadingEdge() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "filled", memberSessionIDs: ["member"])),
        ])
        let slots = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["loose", "member"]
        ).slots
        let metrics = PickyHUDDockMetrics(preset: .large)
        let groupLeadingEdge: CGFloat = 100
        let headerHalf = metrics.groupHeaderHeight(fontScale: 1) * 0.5

        let candidates = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: ["filled": .zero],
            topEntryExtents: ["group:filled": .init(lower: groupLeadingEdge, upper: groupLeadingEdge + 200)],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )
        let expectedCenter = groupLeadingEdge + headerHalf
        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: expectedCenter,
            slotCandidates: [.init(container: .topLevel(index: 0), center: 0)],
            emptyGroupCandidates: [],
            nonEmptyGroupCandidates: candidates,
            layout: layout,
            slotPitch: PickyHUDDockDragGeometry.slotPitch(orientation: .vertical, metrics: metrics, fontScale: 1)
        )

        #expect(candidates.map(\.groupID) == ["filled"])
        #expect(candidates.first?.center == expectedCenter)
        #expect(candidates.first?.halfExtent == headerHalf)
        #expect(destination == .group(id: "filled", memberIndex: 0))
    }
}
