//
//  PickyConversationBubbleLayout.swift
//  Picky
//
//  Shared width policy for conversation bubbles.
//

import CoreGraphics
import SwiftUI

enum PickyConversationBubbleLayout {
    enum BubbleSide {
        case agent
        case user
    }

    static let bubbleRadius: CGFloat = DS.CornerRadius.extraLarge
    static let bubbleAnchorRadius: CGFloat = 4
    static let defaultMaxWidthFraction: CGFloat = 0.85
    static let oppositeSideReserve: CGFloat = 48
    static let horizontalStackSpacing: CGFloat = 0

    static func bubbleShape(side: BubbleSide) -> UnevenRoundedRectangle {
        switch side {
        case .agent:
            UnevenRoundedRectangle(
                topLeadingRadius: bubbleRadius,
                bottomLeadingRadius: bubbleAnchorRadius,
                bottomTrailingRadius: bubbleRadius,
                topTrailingRadius: bubbleRadius,
                style: .continuous
            )
        case .user:
            UnevenRoundedRectangle(
                topLeadingRadius: bubbleRadius,
                bottomLeadingRadius: bubbleRadius,
                bottomTrailingRadius: bubbleAnchorRadius,
                topTrailingRadius: bubbleRadius,
                style: .continuous
            )
        }
    }

    static func contentWidth(forDetailWidth detailWidth: CGFloat) -> CGFloat {
        PickyHUDDockLayout.detailContentWidth(for: detailWidth)
    }

    static func maxBubbleWidth(
        forDetailWidth detailWidth: CGFloat,
        fraction: CGFloat = defaultMaxWidthFraction,
        oppositeSideReserve: CGFloat = oppositeSideReserve
    ) -> CGFloat {
        let contentWidth = contentWidth(forDetailWidth: detailWidth)
        let fractionalWidth = contentWidth * max(0, fraction)
        let reserveWidth = max(0, oppositeSideReserve + horizontalStackSpacing)
        let widthAfterReserve = max(0, contentWidth - reserveWidth)
        return max(0, min(fractionalWidth, widthAfterReserve))
    }
}
