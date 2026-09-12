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

/// A leaf control that moved away from the legacy combined settings page.
/// Keeping this distinct from its hosting group lets old deep links reach the
/// control itself rather than merely the nearest Hub category.
enum PickyHubSettingsLeaf: Equatable {
    case cursorBubbles
    case notifications
    case builtinTools

    var group: PickyHubSettingsGroup {
        switch self {
        case .cursorBubbles: .overlay
        case .notifications: .privacy
        case .builtinTools: .agents
        }
    }

    var scrollTargetID: String {
        switch self {
        case .cursorBubbles: "hub.settings.leaf.cursorBubbles"
        case .notifications: "hub.settings.leaf.notifications"
        case .builtinTools: "hub.settings.leaf.builtinTools"
        }
    }

    var disclosure: PickyHubSettingsDisclosureTarget? {
        switch self {
        case .builtinTools: .agentTools
        case .cursorBubbles, .notifications: nil
        }
    }
}

enum PickyHubSettingsDisclosureTarget: Hashable {
    case agentTools
}

/// A one-shot request carries a fresh ID so repeated links to the same leaf
/// still scroll and expand the control after an earlier request was consumed.
struct PickyHubSettingsNavigationRequest: Equatable {
    let id: UUID
    let group: PickyHubSettingsGroup
    let leaf: PickyHubSettingsLeaf?

    init(group: PickyHubSettingsGroup, leaf: PickyHubSettingsLeaf? = nil, id: UUID = UUID()) {
        self.id = id
        self.group = group
        self.leaf = leaf
    }
}

/// View state consumed directly by `PickyHubSettingsPage`. It names the same
/// scroll anchors rendered by that page, so a route cannot be accepted and
/// silently leave a required disclosure collapsed.
struct PickyHubSettingsNavigationState: Equatable {
    private(set) var expandedDisclosures: Set<PickyHubSettingsDisclosureTarget> = []

    mutating func apply(_ request: PickyHubSettingsNavigationRequest) -> String {
        if let disclosure = request.leaf?.disclosure {
            expandedDisclosures.insert(disclosure)
        }
        return request.leaf?.scrollTargetID ?? request.group.id
    }

    func isExpanded(_ disclosure: PickyHubSettingsDisclosureTarget) -> Bool {
        expandedDisclosures.contains(disclosure)
    }

    mutating func setExpanded(_ disclosure: PickyHubSettingsDisclosureTarget, to isExpanded: Bool) {
        if isExpanded {
            expandedDisclosures.insert(disclosure)
        } else {
            expandedDisclosures.remove(disclosure)
        }
    }
}

struct PickyHubPageScrollResetRequest: Equatable {
    let page: PickyHubPage
    let token: UInt64
}

@MainActor
final class PickyHubNavigator: ObservableObject {
    @Published var selectedPage: PickyHubPage = .dashboard
    @Published private(set) var pageScrollResetRequest: PickyHubPageScrollResetRequest?
    @Published var isWindowVisible = false
    private var nextPageScrollResetToken: UInt64 = 0

    var shouldRefreshStatistics: Bool {
        isWindowVisible && (selectedPage == .dashboard || selectedPage == .statistics)
    }
    /// One-shot settings request consumed by the mounted Settings page.
    @Published private(set) var pendingSettingsNavigation: PickyHubSettingsNavigationRequest?

    /// Compatibility projection for existing group-only callers and tests.
    var pendingSettingsGroup: PickyHubSettingsGroup? { pendingSettingsNavigation?.group }
    /// One-shot tab request consumed by the Statistics page.
    @Published var pendingStatisticsTab: PickyHubStatisticsTab?
    /// One-shot scroll target consumed by the Statistics page (mockup anchors
    /// `work-pattern` / `pickle-records`).
    @Published var pendingStatisticsAnchor: PickyHubStatisticsAnchor?

    func select(_ page: PickyHubPage) {
        selectedPage = page
        nextPageScrollResetToken &+= 1
        pageScrollResetRequest = PickyHubPageScrollResetRequest(
            page: page,
            token: nextPageScrollResetToken
        )
    }

    func showStatistics(tab: PickyHubStatisticsTab = .work, anchor: PickyHubStatisticsAnchor? = nil) {
        pendingStatisticsTab = tab
        pendingStatisticsAnchor = anchor
        selectedPage = .statistics
    }

    func showSettings(group: PickyHubSettingsGroup, leaf: PickyHubSettingsLeaf? = nil) {
        pendingSettingsNavigation = PickyHubSettingsNavigationRequest(group: group, leaf: leaf)
        selectedPage = .settings
    }

    func consumePendingSettingsNavigation() -> PickyHubSettingsNavigationRequest? {
        defer { pendingSettingsNavigation = nil }
        return pendingSettingsNavigation
    }

    func apply(deepLink: PickyDeepLink) {
        switch deepLink.tab {
        case .status:
            selectedPage = .dashboard
        case .messages:
            selectedPage = .conversation
        case .settings:
            if let leaf = deepLink.settingsLeaf {
                showSettings(group: leaf.group, leaf: leaf)
            } else {
                showSettings(group: deepLink.settingsRoute.map(PickyHubSettingsGroup.hosting) ?? .general)
            }
        case .hub(let page):
            selectedPage = page
        }
    }
}

enum PickyHubStatisticsAnchor: String {
    case workPattern
    case pickleRecords
}
