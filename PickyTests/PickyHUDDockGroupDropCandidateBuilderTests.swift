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
        let centers: [String: CGFloat] = ["group:empty": 100, "group:filled": 200]

        let empty = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            topEntryCenters: centers
        )
        let filled = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            topEntryCenters: centers
        )

        #expect(empty.map { $0.groupID } == ["empty"])
        #expect(filled.map { $0.groupID } == ["filled"])
    }
}
