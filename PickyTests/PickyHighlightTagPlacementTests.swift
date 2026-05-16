//
//  PickyHighlightTagPlacementTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyHighlightTagPlacementTests {
    private let screenSize = CGSize(width: 1440, height: 900)

    @Test func anchorsTagOnLeftWhenTargetSitsNearRightEdge() {
        let placement = PickyHighlightTagPlacement.compute(
            targetCenter: CGPoint(x: 1420, y: 450),
            ringOuterRadius: 27,
            tagSize: CGSize(width: 140, height: 22),
            screenSize: screenSize
        )

        #expect(placement.tailEdge == .right)
        #expect(placement.topLeading.x == CGFloat(1241))
    }

    @Test func anchorsTagOnRightWhenSpaceFavorsRight() {
        let placement = PickyHighlightTagPlacement.compute(
            targetCenter: CGPoint(x: 80, y: 200),
            ringOuterRadius: 27,
            tagSize: CGSize(width: 140, height: 22),
            screenSize: screenSize
        )

        #expect(placement.tailEdge == .left)
        #expect(placement.topLeading.x == CGFloat(119))
    }

    @Test func fallsBelowWhenNeitherSideHasRoom() {
        let narrowScreen = CGSize(width: 200, height: 600)
        let placement = PickyHighlightTagPlacement.compute(
            targetCenter: CGPoint(x: 100, y: 200),
            ringOuterRadius: 27,
            tagSize: CGSize(width: 180, height: 22),
            screenSize: narrowScreen
        )

        #expect(placement.tailEdge == .top)
        #expect(placement.topLeading.y == CGFloat(239))
    }

    @Test func fallsAboveWhenBelowDoesNotFit() {
        let cramped = CGSize(width: 200, height: 260)
        let placement = PickyHighlightTagPlacement.compute(
            targetCenter: CGPoint(x: 100, y: 240),
            ringOuterRadius: 27,
            tagSize: CGSize(width: 180, height: 22),
            screenSize: cramped
        )

        #expect(placement.tailEdge == .bottom)
        #expect(placement.topLeading.y < CGFloat(240))
    }
}
