//
//  PickyCursorBubblePlacementTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyCursorBubblePlacementTests {
    private let screenSize = CGSize(width: 1440, height: 900)
    private let bubbleSize = CGSize(width: 200, height: 40)

    @Test func prefersBottomRightWhenCursorHasRoomEverywhere() {
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: CGPoint(x: 400, y: 400),
            bubbleSize: bubbleSize,
            screenSize: screenSize
        )

        #expect(placement.side == .bottomRight)
        #expect(placement.topLeading.x == CGFloat(412))
        #expect(placement.topLeading.y == CGFloat(420))
    }

    @Test func flipsToBottomLeftWhenRightEdgeWouldClip() {
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: CGPoint(x: 1380, y: 400),
            bubbleSize: bubbleSize,
            screenSize: screenSize
        )

        #expect(placement.side == .bottomLeft)
        #expect(placement.topLeading.x == CGFloat(1380 - 12 - 200))
    }

    @Test func flipsToTopRightWhenBottomEdgeWouldClip() {
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: CGPoint(x: 400, y: 880),
            bubbleSize: bubbleSize,
            screenSize: screenSize
        )

        #expect(placement.side == .topRight)
        #expect(placement.topLeading.y == CGFloat(880 - 20 - 40))
    }

    @Test func flipsToTopLeftWhenBottomAndRightWouldClip() {
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: CGPoint(x: 1380, y: 880),
            bubbleSize: bubbleSize,
            screenSize: screenSize
        )

        #expect(placement.side == .topLeft)
        #expect(placement.topLeading.x == CGFloat(1380 - 12 - 200))
        #expect(placement.topLeading.y == CGFloat(880 - 20 - 40))
    }

    @Test func usesCurrentLargerBubbleSizeWhenChoosingSide() {
        let cursorPosition = CGPoint(x: 1_250, y: 400)
        let previousPlacement = PickyCursorBubblePlacement.compute(
            cursorPosition: cursorPosition,
            bubbleSize: CGSize(width: 100, height: 40),
            screenSize: screenSize
        )
        let currentPlacement = PickyCursorBubblePlacement.compute(
            cursorPosition: cursorPosition,
            bubbleSize: CGSize(width: 240, height: 80),
            screenSize: screenSize
        )

        #expect(previousPlacement.side == .bottomRight)
        #expect(currentPlacement.side == .bottomLeft)
        #expect(currentPlacement.topLeading.x == CGFloat(1_250 - 12 - 240))
        #expect(currentPlacement.topLeading.y == CGFloat(420))
    }

    @Test func clampsToScreenWhenNoCornerFits() {
        let cramped = CGSize(width: 180, height: 200)
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: CGPoint(x: 90, y: 100),
            bubbleSize: bubbleSize,
            screenSize: cramped
        )

        // Falls back to bottom-right candidate, then clamps to keep the bubble
        // inside the available area on each axis.
        #expect(placement.side == .bottomRight)
        #expect(placement.topLeading.x == CGFloat(8))
        #expect(placement.topLeading.y == CGFloat(120))
    }
}
