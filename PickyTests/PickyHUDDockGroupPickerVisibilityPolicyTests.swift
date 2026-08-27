//
//  PickyHUDPickerAnchorVisibilityPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickerAnchorVisibilityPolicyTests {
    @Test func nonOverflowAllowsEveryRenderedGroupWithoutGeometry() {
        #expect(PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: ["left", "right"],
            badgeFrames: [:],
            viewportFrame: .zero,
            needsScroll: false
        ) == ["left", "right"])
    }

    @Test func horizontalViewportIncludesOnlyIntersectingBadge() {
        let anchors = PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: ["before", "visible", "after"],
            badgeFrames: [
                "before": CGRect(x: 0, y: 10, width: 20, height: 20),
                "visible": CGRect(x: 110, y: 10, width: 20, height: 20),
                "after": CGRect(x: 240, y: 10, width: 20, height: 20)
            ],
            viewportFrame: CGRect(x: 100, y: 0, width: 100, height: 50),
            needsScroll: true
        )

        #expect(anchors == ["visible"])
    }

    @Test func verticalViewportIncludesOnlyIntersectingBadge() {
        let anchors = PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: ["above", "visible", "below"],
            badgeFrames: [
                "above": CGRect(x: 10, y: 0, width: 20, height: 20),
                "visible": CGRect(x: 10, y: 110, width: 20, height: 20),
                "below": CGRect(x: 10, y: 240, width: 20, height: 20)
            ],
            viewportFrame: CGRect(x: 0, y: 100, width: 50, height: 100),
            needsScroll: true
        )

        #expect(anchors == ["visible"])
    }

    @Test func edgeIntersectionIsAnEligiblePopoverAnchor() {
        #expect(PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: ["edge"],
            badgeFrames: ["edge": CGRect(x: 95, y: 0, width: 20, height: 20)],
            viewportFrame: CGRect(x: 100, y: 0, width: 100, height: 20),
            needsScroll: true
        ) == ["edge"])
    }

    @Test func missingScrollableGeometryFallsBackWithoutChangingRelayTargetOrIdentity() {
        let request = PickyHUDDockGroupPickerRequest(groupID: "offscreen")
        let anchors = PickyHUDPickerAnchorVisibilityPolicy.visibleAnchorGroupIDs(
            renderedGroupIDs: ["offscreen"],
            badgeFrames: [:],
            viewportFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            needsScroll: true
        )
        let presentation = PickyHUDDockGroupPickerRelayPolicy.presentation(
            request: request,
            renderedGroupIDs: anchors,
            hasUntargetedAddAnchor: true
        )

        #expect(presentation == .untargeted(targetGroupID: "offscreen"))
        #expect(PickyHUDDockGroupPickerPresentationIdentity.requestID(
            forAnchorGroupID: nil,
            activeAnchorGroupID: nil,
            activeRequest: request
        ) == request.id)
    }
}
