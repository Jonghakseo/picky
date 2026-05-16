//
//  PickyHUDPlacement.swift
//  Picky
//
//  Per-panel reactive placement state shared between PickyHUDOverlayManager and the
//  SwiftUI HUD view. Exposes the max card height and horizontal dock side so the
//  HUD adapts to wherever the user has dragged or reset the dock.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PickyHUDPlacement: ObservableObject {
    /// Largest height the conversation card may take before its internal ScrollView
    /// (`PickyConversationListView`) starts handling overflow. Computed by the overlay
    /// manager from `dockTopAnchoredMaxPanelHeight - dockShadowVerticalPadding`,
    /// optionally clamped by the visible-frame breathing-room cap. Updated whenever
    /// the user drags the dock anchor or the screen configuration changes.
    @Published var availableCardMaxHeight: CGFloat
    /// Horizontal edge where the dock is anchored. Updated immediately when the user
    /// drags across the screen midpoint or resets the handle so SwiftUI can mirror
    /// the card/dock order without rebuilding the hosting view.
    @Published var dockSide: PickyHUDDockSide
    /// S/M/L size preset for the dock rail. The overlay manager updates this from
    /// Settings without rebuilding the hosting view, preserving HUD hover/open state.
    @Published var dockSizePreset: PickyHUDDockSizePreset
    /// User-resized card size for this display. Nil means the card uses the
    /// built-in default width and automatic content-driven height.
    @Published var cardSize: PickyHUDCardSize?
    /// Transparent panel width required for the current dock side, dock size,
    /// session count, and card width. The overlay manager keeps this in sync so
    /// SwiftUI lays out to the same width AppKit applies to the NSPanel.
    @Published var panelWidth: CGFloat

    var cardWidth: CGFloat { cardSize?.width ?? PickyHUDCardSize.defaultWidth }
    var fixedCardHeight: CGFloat? { cardSize?.height }

    /// Default fallback used while the placement hasn't been hydrated yet (e.g. during
    /// the brief window between panel creation and the first `syncPanelsForCurrentScreens`
    /// pass on launch). Matches the historical fixed cap so first-frame layout matches
    /// the prior behavior.
    nonisolated static let defaultAvailableCardMaxHeight: CGFloat = 1080

    init(
        availableCardMaxHeight: CGFloat = PickyHUDPlacement.defaultAvailableCardMaxHeight,
        dockSide: PickyHUDDockSide = .right,
        dockSizePreset: PickyHUDDockSizePreset = .medium,
        cardSize: PickyHUDCardSize? = nil,
        panelWidth: CGFloat = PickyHUDDockLayout.panelWidth
    ) {
        self.availableCardMaxHeight = availableCardMaxHeight
        self.dockSide = dockSide
        self.dockSizePreset = dockSizePreset
        self.cardSize = cardSize
        self.panelWidth = panelWidth
    }
}
