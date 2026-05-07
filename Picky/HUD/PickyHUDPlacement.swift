//
//  PickyHUDPlacement.swift
//  Picky
//
//  Per-panel reactive placement state shared between PickyHUDOverlayManager and the
//  SwiftUI HUD view. Currently exposes the max card height the conversation card may
//  grow to, which is derived from the live dock anchor percent and the screen's
//  visible frame so the HUD adapts to wherever the user has dragged the dock.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PickyHUDPlacement: ObservableObject {
    /// Largest height the conversation card may take before its internal ScrollView
    /// (`PickyConversationListView`) starts handling overflow. Computed by the overlay
    /// manager from `dockTopAnchoredMaxPanelHeight - 2 * dockShadowVerticalPadding`,
    /// optionally clamped by the visible-frame breathing-room cap. Updated whenever
    /// the user drags the dock anchor or the screen configuration changes.
    @Published var availableCardMaxHeight: CGFloat

    /// Default fallback used while the placement hasn't been hydrated yet (e.g. during
    /// the brief window between panel creation and the first `syncPanelsForCurrentScreens`
    /// pass on launch). Matches the historical fixed cap so first-frame layout matches
    /// the prior behavior.
    static let defaultAvailableCardMaxHeight: CGFloat = 1080

    init(availableCardMaxHeight: CGFloat = PickyHUDPlacement.defaultAvailableCardMaxHeight) {
        self.availableCardMaxHeight = availableCardMaxHeight
    }
}
