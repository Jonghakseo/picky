//
//  PickyHubNavigator.swift
//  Picky
//
//  Window-level navigation state for the hub. Lives outside the SwiftUI tree
//  so the status item, `picky://` deep links, and the dashboard's "see all"
//  links can all route the same instance, and so the selection survives the
//  window being closed and reopened.
//

import Combine
import Foundation

/// The seven settings groups rendered on the Settings page, in mockup order.
enum PickyHubSettingsGroup: String, CaseIterable, Identifiable {
    case general
    case agents
    case voice
    case overlay
    case workspace
    case privacy
    case advanced

    var id: String { rawValue }

    /// Legacy `picky://settings/<route>` links resolve to the group that now
    /// hosts that route's controls.
    static func hosting(_ route: CompanionPanelSettingsRoute) -> PickyHubSettingsGroup {
        switch route {
        case .index, .general, .onboarding: .general
        case .oauth, .mainAgent, .builtinTools: .agents
        case .voice, .shortcuts: .voice
        case .overlayAndNotifications: .overlay
        case .pickle: .workspace
        }
    }
}

enum PickyHubStatisticsTab: String, CaseIterable, Identifiable {
    case work
    case usage

    var id: String { rawValue }
}

@MainActor
final class PickyHubNavigator: ObservableObject {
    @Published var selectedPage: PickyHubPage = .dashboard
    /// One-shot scroll target consumed by the Settings page on appear/change.
    @Published var pendingSettingsGroup: PickyHubSettingsGroup?
    /// One-shot tab request consumed by the Statistics page.
    @Published var pendingStatisticsTab: PickyHubStatisticsTab?
    /// One-shot scroll target consumed by the Statistics page (mockup anchors
    /// `work-pattern` / `pickle-records`).
    @Published var pendingStatisticsAnchor: PickyHubStatisticsAnchor?

    func select(_ page: PickyHubPage) {
        selectedPage = page
    }

    func showStatistics(tab: PickyHubStatisticsTab = .work, anchor: PickyHubStatisticsAnchor? = nil) {
        pendingStatisticsTab = tab
        pendingStatisticsAnchor = anchor
        selectedPage = .statistics
    }

    func showSettings(group: PickyHubSettingsGroup) {
        pendingSettingsGroup = group
        selectedPage = .settings
    }

    func apply(deepLink: PickyDeepLink) {
        switch deepLink.tab {
        case .status:
            selectedPage = .dashboard
        case .messages:
            selectedPage = .conversation
        case .settings:
            showSettings(group: deepLink.settingsRoute.map(PickyHubSettingsGroup.hosting) ?? .general)
        case .hub(let page):
            selectedPage = page
        }
    }
}

enum PickyHubStatisticsAnchor: String {
    case workPattern
    case pickleRecords
}
