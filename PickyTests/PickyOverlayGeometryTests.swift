//
//  PickyOverlayGeometryTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyOverlayGeometryTests {
    private let screenFrame = CGRect(x: 100, y: 200, width: 1440, height: 900)

    @Test func convertsAppKitScreenPointToSwiftUILocalCoordinates() {
        let point = PickyOverlayGeometry.swiftUICoordinates(
            for: CGPoint(x: 160, y: 980),
            in: screenFrame
        )

        #expect(point.x == CGFloat(60))
        #expect(point.y == CGFloat(120))
    }

    @Test func cursorBuddyPositionAppliesDefaultOffsetAfterCoordinateConversion() {
        let point = PickyOverlayGeometry.cursorBuddyPosition(
            for: CGPoint(x: 160, y: 980),
            in: screenFrame
        )

        #expect(point.x == CGFloat(90))
        #expect(point.y == CGFloat(140))
    }

    @Test func targetBelongsToScreenWhenPointFallsInsideExpandedScreenFrame() {
        let belongs = PickyOverlayGeometry.targetBelongsToScreen(
            screenLocation: CGPoint(x: 99.5, y: 199.5),
            displayFrame: nil,
            screenFrame: screenFrame
        )

        #expect(belongs)
    }

    @Test func targetBelongsToScreenWhenDisplayFrameOverlapsEvenIfPointDoesNot() {
        let belongs = PickyOverlayGeometry.targetBelongsToScreen(
            screenLocation: CGPoint(x: -1000, y: -1000),
            displayFrame: screenFrame.insetBy(dx: 100, dy: 100),
            screenFrame: screenFrame
        )

        #expect(belongs)
    }

    @Test func targetDoesNotBelongToScreenWhenPointAndDisplayFrameAreElsewhere() {
        let belongs = PickyOverlayGeometry.targetBelongsToScreen(
            screenLocation: CGPoint(x: 3000, y: 3000),
            displayFrame: CGRect(x: 3000, y: 3000, width: 500, height: 500),
            screenFrame: screenFrame
        )

        #expect(!belongs)
    }

    @Test func clampsPointToScreenSize() {
        let point = PickyOverlayGeometry.clamped(
            CGPoint(x: -20, y: 920),
            to: CGSize(width: 1440, height: 900)
        )

        #expect(point.x == CGFloat(0))
        #expect(point.y == CGFloat(900))
    }
}
