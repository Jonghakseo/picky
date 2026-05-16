//
//  PickyHighlightTagPlacement.swift
//  Picky
//
//  Pure placement logic for pointer-highlight tags.
//

import CoreGraphics

struct PickyHighlightTagPlacement: Equatable {
    enum TailEdge { case left, right, top, bottom }
    let topLeading: CGPoint
    let tailEdge: TailEdge

    static func compute(
        targetCenter: CGPoint,
        ringOuterRadius: CGFloat,
        tagSize: CGSize,
        screenSize: CGSize
    ) -> PickyHighlightTagPlacement {
        let gap: CGFloat = 12
        let edgePadding: CGFloat = 8
        let leftSpace = targetCenter.x - ringOuterRadius - gap
        let rightSpace = screenSize.width - targetCenter.x - ringOuterRadius - gap

        if rightSpace >= tagSize.width + edgePadding,
           rightSpace >= leftSpace {
            let originX = targetCenter.x + ringOuterRadius + gap
            let originY = targetCenter.y - tagSize.height / 2
            return PickyHighlightTagPlacement(
                topLeading: CGPoint(x: originX, y: clampY(originY, height: tagSize.height, screenSize: screenSize)),
                tailEdge: .left
            )
        }

        if leftSpace >= tagSize.width + edgePadding {
            let originX = targetCenter.x - ringOuterRadius - gap - tagSize.width
            let originY = targetCenter.y - tagSize.height / 2
            return PickyHighlightTagPlacement(
                topLeading: CGPoint(x: originX, y: clampY(originY, height: tagSize.height, screenSize: screenSize)),
                tailEdge: .right
            )
        }

        // Not enough horizontal space — anchor below or above the ring.
        let belowOrigin = CGPoint(
            x: clampX(targetCenter.x - tagSize.width / 2, width: tagSize.width, screenSize: screenSize),
            y: targetCenter.y + ringOuterRadius + gap
        )
        let belowFits = belowOrigin.y + tagSize.height + edgePadding <= screenSize.height
        if belowFits {
            return PickyHighlightTagPlacement(topLeading: belowOrigin, tailEdge: .top)
        }
        let aboveOrigin = CGPoint(
            x: clampX(targetCenter.x - tagSize.width / 2, width: tagSize.width, screenSize: screenSize),
            y: targetCenter.y - ringOuterRadius - gap - tagSize.height
        )
        return PickyHighlightTagPlacement(topLeading: aboveOrigin, tailEdge: .bottom)
    }

    private static func clampX(_ x: CGFloat, width: CGFloat, screenSize: CGSize) -> CGFloat {
        let minX: CGFloat = 8
        let maxX = max(minX, screenSize.width - width - 8)
        return min(max(x, minX), maxX)
    }

    private static func clampY(_ y: CGFloat, height: CGFloat, screenSize: CGSize) -> CGFloat {
        let minY: CGFloat = 8
        let maxY = max(minY, screenSize.height - height - 8)
        return min(max(y, minY), maxY)
    }
}
