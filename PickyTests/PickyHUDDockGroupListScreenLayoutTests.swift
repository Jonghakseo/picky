//
//  PickyHUDDockGroupListScreenLayoutTests.swift
//  PickyTests
//
//  The child panel consumes SwiftUI's top-left HUD geometry but AppKit expects
//  a bottom-left screen frame. Keep that conversion independently testable.
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockGroupListScreenLayoutTests {
    @Test func convertsTopLeftHUDOriginToBottomLeftScreenFrame() {
        let hudPanelFrame = CGRect(x: 400, y: 200, width: 540, height: 500)
        let origin = CGPoint(x: 62, y: 120)
        let panelSize = CGSize(width: 260, height: 342)

        let frame = PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudPanelFrame,
            swiftUIOrigin: origin,
            panelSize: panelSize
        )

        let expectedX: CGFloat = 462
        let expectedY: CGFloat = 238
        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.y == expectedY)
        #expect(frame.size == panelSize)
    }

    @Test func mapsVisibleScreenBoundsIntoHUDRootCoordinates() {
        let visibleFrame = CGRect(x: 10, y: 20, width: 1_000, height: 700)
        let hudPanelFrame = CGRect(x: 40, y: 100, width: 540, height: 800)

        let bounds = PickyHUDDockGroupListScreenLayout.hudRootBounds(
            visibleFrame: visibleFrame,
            hudPanelFrame: hudPanelFrame
        )

        let expectedX: CGFloat = -30
        let expectedY: CGFloat = 180
        #expect(bounds.origin.x == expectedX)
        #expect(bounds.origin.y == expectedY)
        #expect(bounds.size == visibleFrame.size)
    }

    @Test func convertsScreenPointToTheSameTopLeftPanelCoordinatesUsedByRowCenters() {
        let panelFrame = CGRect(x: 400, y: 200, width: 300, height: 360)
        let local = PickyHUDDockGroupListScreenLayout.panelLocalPoint(
            screenPoint: CGPoint(x: 460, y: 500),
            panelFrame: panelFrame
        )

        let expected = CGPoint(x: 60, y: 60)
        #expect(local == expected)
    }

    @Test func convertsTheExactPanelLocalRowFrameToScreenSpace() {
        let frame = PickyHUDDockGroupListScreenLayout.screenFrame(
            panelLocalFrame: CGRect(x: 24, y: 52, width: 212, height: 38),
            panelFrame: CGRect(x: -900, y: 200, width: 260, height: 320)
        )

        #expect(frame == CGRect(x: -876, y: 430, width: 212, height: 38))
    }

    @Test func selectingAClosedRowRequestsOpeningTheSessionAndClosesTheList() {
        let result = PickyHUDDockGroupListInteractionPolicy.selectionResult(
            sessionID: "pickle-2",
            openedSessionID: "pickle-1",
            openGroupID: "group-a"
        )

        #expect(result.sessionAction == .open(sessionID: "pickle-2"))
        #expect(result.openGroupID == nil)
    }

    @Test func selectingTheOpenedRowRequestsClosingTheSessionAndClosesTheList() {
        let result = PickyHUDDockGroupListInteractionPolicy.selectionResult(
            sessionID: "pickle-2",
            openedSessionID: "pickle-2",
            openGroupID: "group-a"
        )

        #expect(result.sessionAction == .close(sessionID: "pickle-2"))
        #expect(result.openGroupID == nil)
    }

    @Test func changingDockSideInvalidatesTheOpenListAnchor() {
        #expect(PickyHUDDockGroupListInteractionPolicy.openGroupIDAfterDockSideChanged() == nil)
    }
}
