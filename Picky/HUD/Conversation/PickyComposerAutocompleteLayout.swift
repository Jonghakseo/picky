//
//  PickyComposerAutocompleteLayout.swift
//  Picky
//
//  Layout primitives for the composer's autocomplete overlay.
//

import SwiftUI

enum PickyComposerAutocompletePlacementPolicy {
    static func popupOrigin(
        composerBounds: CGRect,
        popupSize: CGSize,
        spacing: CGFloat = DS.Spacing.xs
    ) -> CGPoint {
        CGPoint(
            x: composerBounds.minX,
            y: composerBounds.minY - popupSize.height - spacing
        )
    }
}

/// Places the autocomplete popup outside the composer's measured bounds. This
/// keeps the composer/card height stable while avoiding SwiftUI alignment-guide
/// behavior that can place conditional overlay content below the editor.
struct PickyComposerAutocompleteOverlayLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard let composer = subviews.first else { return }
        composer.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )

        guard subviews.count > 1 else { return }
        let popup = subviews[1]
        let popupProposal = ProposedViewSize(width: bounds.width, height: nil)
        let popupSize = popup.sizeThatFits(popupProposal)
        let origin = PickyComposerAutocompletePlacementPolicy.popupOrigin(
            composerBounds: bounds,
            popupSize: popupSize
        )
        popup.place(at: origin, anchor: .topLeading, proposal: popupProposal)
    }
}
