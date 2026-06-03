//
//  PickyHUDDockGroupCollapsePolicyTests.swift
//  PickyTests
//
//  Characterization coverage for per-display HUD dock group collapse behavior
//  before moving it out of PickyHUDView.
//

import Testing
@testable import Picky

struct PickyHUDDockGroupCollapsePolicyTests {
    @Test func toggleUsesOverrideOrLayoutDefaultAndClosesOpenMemberOnlyWhenCollapsing() {
        let group = PickyDockGroup(
            id: "g1",
            name: "Backend",
            color: .teal,
            memberSessionIDs: ["s1", "s2"],
            isCollapsed: false
        )

        let collapse = PickyHUDDockGroupCollapsePolicy.toggleResult(
            groupID: "g1",
            groups: [group],
            overrides: [:],
            openedSessionID: "s2"
        )
        #expect(collapse.overrides == ["g1": true])
        #expect(collapse.willCollapse)
        #expect(collapse.sessionIDToClose == "s2")

        let expand = PickyHUDDockGroupCollapsePolicy.toggleResult(
            groupID: "g1",
            groups: [group],
            overrides: ["g1": true],
            openedSessionID: "s2"
        )
        #expect(expand.overrides == ["g1": false])
        #expect(!expand.willCollapse)
        #expect(expand.sessionIDToClose == nil)
    }

    @Test func toggleDoesNotCloseOpenSessionOutsideGroup() {
        let group = PickyDockGroup(
            id: "g1",
            color: .blue,
            memberSessionIDs: ["s1", "s2"]
        )

        let result = PickyHUDDockGroupCollapsePolicy.toggleResult(
            groupID: "g1",
            groups: [group],
            overrides: [:],
            openedSessionID: "outside"
        )

        #expect(result.overrides == ["g1": true])
        #expect(result.willCollapse)
        #expect(result.sessionIDToClose == nil)
    }

    @Test func expandForOpeningClearsCollapsedOverrideOnlyWhenTargetMemberIsCollapsed() {
        let collapsedGroup = PickyDockGroup(
            id: "g1",
            color: .pink,
            memberSessionIDs: ["s1", "s2"],
            isCollapsed: true
        )
        let expandedGroup = PickyDockGroup(
            id: "g2",
            color: .amber,
            memberSessionIDs: ["s3"],
            isCollapsed: false
        )

        let expand = PickyHUDDockGroupCollapsePolicy.expandResultForOpening(
            sessionID: "s2",
            groups: [collapsedGroup, expandedGroup],
            overrides: ["g2": true]
        )
        #expect(expand.overrides == ["g1": false, "g2": true])
        #expect(expand.didExpand)

        let noChange = PickyHUDDockGroupCollapsePolicy.expandResultForOpening(
            sessionID: "s3",
            groups: [collapsedGroup, expandedGroup],
            overrides: [:]
        )
        #expect(noChange.overrides == [:])
        #expect(!noChange.didExpand)
    }

    @Test func effectiveCollapsePrefersPerDisplayOverrideOverLayoutDefault() {
        let defaultCollapsed = PickyDockGroup(
            id: "g1",
            memberSessionIDs: ["s1"],
            isCollapsed: true
        )
        let defaultExpanded = PickyDockGroup(
            id: "g2",
            memberSessionIDs: ["s2"],
            isCollapsed: false
        )

        #expect(PickyHUDDockGroupCollapsePolicy.isCollapsed(
            groupID: "g1",
            groups: [defaultCollapsed, defaultExpanded],
            overrides: [:]
        ))
        #expect(!PickyHUDDockGroupCollapsePolicy.isCollapsed(
            groupID: "g1",
            groups: [defaultCollapsed, defaultExpanded],
            overrides: ["g1": false]
        ))
        #expect(PickyHUDDockGroupCollapsePolicy.isCollapsed(
            groupID: "g2",
            groups: [defaultCollapsed, defaultExpanded],
            overrides: ["g2": true]
        ))
        #expect(!PickyHUDDockGroupCollapsePolicy.isCollapsed(
            groupID: "missing",
            groups: [defaultCollapsed, defaultExpanded],
            overrides: [:]
        ))
    }
}
