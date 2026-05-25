//
//  PickyPanelNavigator.swift
//  Picky
//
//  External navigation state for the menu bar companion panel. The panel
//  view used to hold tab + settings-route selection in private `@State`,
//  which meant nothing outside the view could open a particular screen.
//  The navigator hoists that state up so `MenuBarPanelManager` (and, by
//  extension, the deep-link dispatcher) can drive the panel from anywhere.
//
//  Conversation-card `picky://` links flow through here:
//    markdown link click
//      -> PickyDeepLinkDispatcher.handle
//      -> MenuBarPanelManager.present(deepLink:)
//      -> PickyPanelNavigator.apply(deepLink:)
//      -> CompanionPanelView observes & switches.
//

import Combine
import SwiftUI

@MainActor
final class PickyPanelNavigator: ObservableObject {
    @Published var selectedTab: CompanionPanelTab = .status
    @Published var settingsRoute: CompanionPanelSettingsRoute = .index
    /// Status tab's inner navigation. Mirrors `settingsRoute` so the
    /// Feedback page is reached as a Status sub-route rather than a
    /// panel-level overlay — that way switching tabs hides Feedback without
    /// losing its draft, exactly like Settings sub-pages.
    @Published var statusRoute: CompanionPanelStatusRoute = .index

    /// Routes the panel to whatever the deep link points at. Callers that
    /// also need to make the panel visible should call
    /// `MenuBarPanelManager.present(deepLink:)` instead — it folds visibility
    /// and navigation into one step so the two can't drift.
    func apply(deepLink: PickyDeepLink) {
        switch deepLink.tab {
        case .status:
            selectedTab = .status
            settingsRoute = .index
            statusRoute = .index
        case .messages:
            // Messages used to be a top-level tab but now lives as a
            // sub-page under Status. The deep-link path stays valid so
            // already-emitted `picky://panel/messages` links keep landing on
            // the right surface — they just drill into the Status sub-page
            // instead of switching tabs.
            selectedTab = .status
            settingsRoute = .index
            statusRoute = .messages
        case .settings:
            selectedTab = .settings
            settingsRoute = deepLink.settingsRoute ?? .index
            statusRoute = .index
        }
    }
}
