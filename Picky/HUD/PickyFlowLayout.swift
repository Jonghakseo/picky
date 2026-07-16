//
//  PickyFlowLayout.swift
//  Picky
//
//  Leading-only flow layout for compact, wrap-friendly chip rows.
//

import SwiftUI

struct PickyFlowLayout: Layout {
    let itemSpacing: CGFloat
    let rowSpacing: CGFloat

    init(itemSpacing: CGFloat = DS.Spacing.sm, rowSpacing: CGFloat = DS.Spacing.sm) {
        self.itemSpacing = itemSpacing
        self.rowSpacing = rowSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let availableWidth = proposedWidth(from: proposal)
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + itemSpacing + size.width > availableWidth {
                maxRowWidth = max(maxRowWidth, rowWidth)
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }

            if rowWidth > 0 {
                rowWidth += itemSpacing
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }

        guard rowWidth > 0 else { return .zero }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight

        return CGSize(
            width: proposal.width?.isFinite == true ? proposal.width! : maxRowWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + itemSpacing + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += rowHeight + rowSpacing
                rowHeight = 0
            }

            if origin.x > bounds.minX {
                origin.x += itemSpacing
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func proposedWidth(from proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return .greatestFiniteMagnitude }
        return max(0, width)
    }
}
