//
//  PickyCursorBubblePlacement.swift
//  Picky
//
//  Pure placement logic for cursor-anchored bubbles.
//

import CoreGraphics
import SwiftUI

/// Measures the current bubble and places it around the cursor in the same
/// layout pass. Keeping measurement and placement together avoids the
/// one-frame size mismatch produced by GeometryReader preference feedback.
struct PickyCursorBubblePlacementLayout: Layout {
    var cursorPosition: CGPoint
    let screenSize: CGSize
    var horizontalGap: CGFloat = 12
    var verticalGap: CGFloat = 20
    var sideOrder: [PickyCursorBubblePlacement.Side] = PickyCursorBubblePlacement.defaultSideOrder

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cursorPosition.x, cursorPosition.y) }
        set { cursorPosition = CGPoint(x: newValue.first, y: newValue.second) }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? screenSize.width,
            height: proposal.height ?? screenSize.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard let bubble = subviews.first else { return }
        let bubbleProposal = ProposedViewSize.unspecified
        let bubbleSize = bubble.sizeThatFits(bubbleProposal)
        let placement = PickyCursorBubblePlacement.compute(
            cursorPosition: cursorPosition,
            bubbleSize: bubbleSize,
            screenSize: screenSize,
            horizontalGap: horizontalGap,
            verticalGap: verticalGap,
            sideOrder: sideOrder
        )
        bubble.place(
            at: CGPoint(
                x: bounds.minX + placement.topLeading.x,
                y: bounds.minY + placement.topLeading.y
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bubbleSize.width, height: bubbleSize.height)
        )
    }
}

/// Picks a placement for a cursor-anchored bubble that stays within the host
/// screen. The function tries the four corners around the cursor in priority
/// order (bottom-right → bottom-left → top-right → top-left) and falls back
/// to clamping when no candidate fits. Pure logic so it can be unit tested.
struct PickyCursorBubblePlacement: Equatable {
    enum Side: Equatable { case bottomRight, bottomLeft, topRight, topLeft }
    static let defaultSideOrder: [Side] = [.bottomRight, .bottomLeft, .topRight, .topLeft]
    let topLeading: CGPoint
    let side: Side

    static func compute(
        cursorPosition: CGPoint,
        bubbleSize: CGSize,
        screenSize: CGSize,
        horizontalGap: CGFloat = 12,
        verticalGap: CGFloat = 20,
        edgePadding: CGFloat = 8,
        sideOrder: [Side] = defaultSideOrder
    ) -> PickyCursorBubblePlacement {
        let candidates: [(Side, CGPoint)] = [
            (.bottomRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y + verticalGap)),
            (.bottomLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y + verticalGap)),
            (.topRight, CGPoint(x: cursorPosition.x + horizontalGap, y: cursorPosition.y - verticalGap - bubbleSize.height)),
            (.topLeft, CGPoint(x: cursorPosition.x - horizontalGap - bubbleSize.width, y: cursorPosition.y - verticalGap - bubbleSize.height)),
        ]

        let orderedCandidates = sideOrder.compactMap { preferredSide in
            candidates.first(where: { $0.0 == preferredSide })
        }
        for (side, origin) in orderedCandidates {
            let fitsHorizontally = origin.x >= edgePadding
                && origin.x + bubbleSize.width + edgePadding <= screenSize.width
            let fitsVertically = origin.y >= edgePadding
                && origin.y + bubbleSize.height + edgePadding <= screenSize.height
            if fitsHorizontally && fitsVertically {
                return PickyCursorBubblePlacement(topLeading: origin, side: side)
            }
        }

        let fallback = orderedCandidates.first ?? candidates[0]
        let fallbackSide = fallback.0
        let fallbackOrigin = fallback.1
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
