//
//  PickyCursorBubblePlacement.swift
//  Picky
//
//  Pure placement logic for cursor-anchored bubbles.
//

import CoreGraphics

/// Picks a placement for a cursor-anchored bubble that stays within the host
/// screen. The function tries the four corners around the cursor in priority
/// order (bottom-right → bottom-left → top-right → top-left) and falls back
/// to clamping when no candidate fits. Pure logic so it can be unit tested.
struct PickyCursorBubblePlacement: Equatable {
    enum Side: Equatable { case bottomRight, bottomLeft, topRight, topLeft }
    let topLeading: CGPoint
    let side: Side

    static func compute(
        cursorPosition: CGPoint,
        bubbleSize: CGSize,
        screenSize: CGSize,
        horizontalGap: CGFloat = 12,
        verticalGap: CGFloat = 20,
        edgePadding: CGFloat = 8
    ) -> PickyCursorBubblePlacement {
        let candidates: [(Side, CGPoint)] = [
            (.bottomRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y + verticalGap)),
            (.bottomLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y + verticalGap)),
            (.topRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y - verticalGap - bubbleSize.height)),
            (.topLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y - verticalGap - bubbleSize.height)),
        ]

        for (side, origin) in candidates {
            let fitsHorizontally = origin.x >= edgePadding
                && origin.x + bubbleSize.width + edgePadding <= screenSize.width
            let fitsVertically = origin.y >= edgePadding
                && origin.y + bubbleSize.height + edgePadding <= screenSize.height
            if fitsHorizontally && fitsVertically {
                return PickyCursorBubblePlacement(topLeading: origin, side: side)
            }
        }

        let fallbackSide = candidates[0].0
        let fallbackOrigin = candidates[0].1
        let maxX = max(edgePadding, screenSize.width - bubbleSize.width - edgePadding)
        let maxY = max(edgePadding, screenSize.height - bubbleSize.height - edgePadding)
        let clampedX = min(max(fallbackOrigin.x, edgePadding), maxX)
        let clampedY = min(max(fallbackOrigin.y, edgePadding), maxY)
        return PickyCursorBubblePlacement(
            topLeading: CGPoint(x: clampedX, y: clampedY),
            side: fallbackSide
        )
    }
}
