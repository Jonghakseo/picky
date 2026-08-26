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

        let empty = PickyHUDDockGroupDropCandidateBuilder.emptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            orientation: .vertical
        )
        let filled = PickyHUDDockGroupDropCandidateBuilder.nonEmptyCandidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: ["loose", "member"],
            groupDropFrames: frames,
            orientation: .vertical
        )

        #expect(empty.map { $0.groupID } == ["empty"])
        #expect(empty.first?.center == 97)
        #expect(empty.first?.halfExtent == 27)
        #expect(filled.map { $0.groupID } == ["filled"])
        #expect(filled.first?.center == 197)
        #expect(filled.first?.halfExtent == 27)
    }
}
