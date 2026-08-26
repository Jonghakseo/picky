//
//  PickyHUDDockGroupDropCandidateBuilderTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockGroupDropCandidateBuilderTests {
    @Test func railProjectionBuildsEmptyAndFilledFolderCandidatesSeparately() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty")),
            .group(PickyDockGroup(id: "filled", memberSessionIDs: ["member"])),
        ])
        let slots = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["loose", "member"]).slots
        let frames: [String: CGRect] = [
            "empty": CGRect(x: 10, y: 70, width: 54, height: 54),
            "filled": CGRect(x: 10, y: 170, width: 54, height: 54),
        ]
        let metrics = PickyHUDDockMetrics(preset: .large)

        let empty = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            topEntryCenters: ["group:empty": 900],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )
        let filled = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            topEntryCenters: ["group:filled": 900],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )

        #expect(empty.map { $0.groupID } == ["empty"])
        #expect(empty.first?.center == 97)
        #expect(empty.first?.halfExtent == 27)
        #expect(filled.map { $0.groupID } == ["filled"])
        #expect(filled.first?.center == 197)
        #expect(filled.first?.halfExtent == 27)
    }

    @Test func missingOrEmptyMeasuredFrameFallsBackToTheVisibleBadgeRange() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "filled", memberSessionIDs: ["member"])),
        ])
        let slots = PickyDockProjector.project(
            layout: layout,
            visibleSessionIDs: ["loose", "member"]
        ).slots
        let metrics = PickyHUDDockMetrics(preset: .large)
        let topEntryCenter: CGFloat = 100

        let candidates = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: ["filled": .zero],
            topEntryCenters: ["group:filled": topEntryCenter],
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        )
        let titleAndSpacing = PickyHUDDockGroupHeaderPresentation.labelHeight(
            metrics: metrics,
            fontScale: 1
        ) + metrics.groupHeaderContentSpacing

        let expectedCenter = topEntryCenter + titleAndSpacing * 0.5
        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: expectedCenter,
            slotCandidates: [.init(container: .topLevel(index: 0), center: 0)],
            emptyGroupCandidates: [],
            nonEmptyGroupCandidates: candidates,
            layout: layout,
            slotPitch: metrics.sessionTileHeight + metrics.sessionSpacing
        )

        #expect(candidates.map(\.groupID) == ["filled"])
        #expect(candidates.first?.center == expectedCenter)
        #expect(candidates.first?.halfExtent == metrics.sessionTileHeight * 0.5)
        #expect(destination == .group(id: "filled", memberIndex: 0))
    }
}
