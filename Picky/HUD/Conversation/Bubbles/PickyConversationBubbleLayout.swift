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
    /// A 720pt cap keeps 13pt prose near a 90–100 character measure on wide
    /// cards. Structured code and table blocks retain the relative width cap
    /// so their dedicated horizontal scroll / column layouts remain useful.
    static let narrativeMaxWidth: CGFloat = 720
    static let oppositeSideReserve: CGFloat = 48
    static let horizontalStackSpacing: CGFloat = 0

    enum ContentKind {
        case narrative
        case structured
    }

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
        oppositeSideReserve: CGFloat = oppositeSideReserve,
        contentKind: ContentKind = .structured
    ) -> CGFloat {
        let contentWidth = contentWidth(forDetailWidth: detailWidth)
        let fractionalWidth = contentWidth * max(0, fraction)
        let reserveWidth = max(0, oppositeSideReserve + horizontalStackSpacing)
        let widthAfterReserve = max(0, contentWidth - reserveWidth)
        let relativeWidth = max(0, min(fractionalWidth, widthAfterReserve))

        switch contentKind {
        case .narrative:
            return min(relativeWidth, narrativeMaxWidth)
        case .structured:
            return relativeWidth
        }
    }

    /// Code blocks and tables use dedicated renderers with horizontal overflow,
    /// so preserving the existing relative cap keeps technical output usable.
    static func contentKind(for markdown: String) -> ContentKind {
        for block in PickyReportMarkdownRenderer().blocks(from: markdown) {
            switch block {
            case .codeBlock, .table:
                return .structured
            case .heading, .paragraph, .bullet:
                continue
            }
        }
        return .narrative
    }
}
