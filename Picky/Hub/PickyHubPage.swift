//
//  PickyHubPage.swift
//  Picky
//
//  The seven top-level destinations of the Picky hub window. Raw values stay
//  English so persisted selection and debug logs never depend on translation.
//

import Foundation
import SwiftUI

enum PickyHubPage: String, CaseIterable, Identifiable, Codable {
    case dashboard
    case statistics
    case guides
    case quickStart
    case plugins
    case conversation
    case settings

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .dashboard: "hub.nav.dashboard"
        case .statistics: "hub.nav.statistics"
        case .guides: "hub.nav.guides"
        case .quickStart: "hub.nav.quickStart"
        case .plugins: "hub.nav.plugins"
        case .conversation: "hub.nav.conversation"
        case .settings: "hub.nav.settings"
        }
    }

    var title: String {
        switch self {
        case .dashboard: L10n.t("hub.nav.dashboard")
        case .statistics: L10n.t("hub.nav.statistics")
        case .guides: L10n.t("hub.nav.guides")
        case .quickStart: L10n.t("hub.nav.quickStart")
        case .plugins: L10n.t("hub.nav.plugins")
        case .conversation: L10n.t("hub.nav.conversation")
        case .settings: L10n.t("hub.nav.settings")
        }
    }

    /// SF Symbol standing in for the lucide glyphs used by the mockup.
    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .statistics: "chart.line.uptrend.xyaxis"
        case .guides: "book"
        case .quickStart: "bolt"
        case .plugins: "powerplug"
        case .conversation: "bubble.left"
        case .settings: "slider.horizontal.3"
        }
    }

    /// Path component used by `picky://hub/<page>` deep links.
    static func fromDeepLinkPath(_ path: String) -> PickyHubPage? {
        switch path.lowercased() {
        case "dashboard", "home", "": .dashboard
        case "statistics", "stats": .statistics
        case "guides", "updates": .guides
        case "quickstart", "quick-start": .quickStart
        case "plugins", "extensions": .plugins
        case "conversation", "messages": .conversation
        case "settings": .settings
        default: nil
        }
    }
}
