//
//  PickyHUDDockGroupCard.swift
//  Picky
//
//  Expanded group card for the list dock. Header and member rows share one
//  tinted card so members never read as loose Pickles: the tint stays visible
//  in the resting icon lane, and a fixed gap keeps adjacent open groups apart.
//  Collapsed groups keep their bare header. Lengths must stay in sync with
//  `PickyHUDDockRailLayoutPolicy.listLength`.
//

import SwiftUI

struct PickyHUDDockGroupCard: ViewModifier {
    let group: PickyDockGroup
    let orientation: PickyHUDDockOrientation
    let metrics: PickyHUDDockMetrics
    /// A dragged Pickle targets this group. The card owns the highlight while
    /// expanded; a collapsed header draws its own.
    let isDropTargeted: Bool
    let isFirst: Bool
    let isLast: Bool

    func body(content: Content) -> some View {
        if group.isCollapsed {
            // Vertical headers keep their original top gap; horizontal folder
            // cells sit flush like any other cell.
            content.padding(.top, orientation == .vertical && !isFirst ? metrics.groupHeaderTopGap : 0)
        } else if orientation == .vertical {
            content
                .padding(.bottom, metrics.groupCardInnerBottom)
                .background(cardFill(crossInset: 0))
                .overlay(cardStroke(crossInset: 0))
                .padding(.top, isFirst ? 0 : metrics.groupCardOuterGap)
                .padding(.bottom, isLast ? 0 : metrics.groupCardOuterGap)
        } else {
            content
                .background(cardFill(crossInset: metrics.groupCardHorizontalCrossInset))
                .overlay(cardStroke(crossInset: metrics.groupCardHorizontalCrossInset))
                .padding(.leading, isFirst ? 0 : metrics.groupCardOuterGap)
                .padding(.trailing, isLast ? 0 : metrics.groupCardOuterGap)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.groupCardCornerRadius, style: .continuous)
    }

    private func cardFill(crossInset: CGFloat) -> some View {
        shape
            .fill(group.color.accent.opacity(
                isDropTargeted ? metrics.groupCardDropTintOpacity : metrics.groupCardTintOpacity
            ))
            .padding(.vertical, crossInset)
            .allowsHitTesting(false)
    }

    /// Drawn above the rows so hover and selection fills cannot hide it.
    @ViewBuilder
    private func cardStroke(crossInset: CGFloat) -> some View {
        if isDropTargeted {
            shape
                .strokeBorder(DS.Colors.accentText, lineWidth: 1.2)
                .padding(.vertical, crossInset)
                .allowsHitTesting(false)
        }
    }
}
