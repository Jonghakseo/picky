//
//  PickyHubDependencies.swift
//  Picky
//
//  Everything the hub window needs from the rest of the app, gathered in one
//  value so the window controller and every page share the same instances.
//

import Foundation

@MainActor
struct PickyHubDependencies {
    let companionManager: CompanionManager
    let sessionListViewModel: PickySessionListViewModel
    let settingsViewModel: PickySettingsViewModel
    let settingsStore: PickySettingsStore
    let appearanceStore: PickyAppearanceStore
    let fontScaleStore: PickyAppFontScaleStore
    let hudVisibilityStore: PickyHUDVisibilityStore
    let updaterController: PickyUpdaterController
    let pluginReloadController: PickyPluginReloadController
    let agentClient: any PickyAgentClient
    let navigator: PickyHubNavigator
    let modalHost: PickyHubModalHost
    let statisticsStore: PickyHubStatisticsStore
    let quickStartLauncher: PickyHubQuickStartLauncher
    let pluginCatalog: PickyHubPluginCatalogViewModel
    /// Absent under unit tests and whenever the app runs without the remote
    /// hub composed, so the settings section renders its unavailable state.
    let remoteAccess: PickyRemoteAccessController?
    /// Subscription plan limits. Absent under unit tests, which hides the section.
    var usageLimitsStore: PickyUsageLimitsStore? = nil

    var permissions: PickyPermissionMonitor { companionManager.permissions }
}

extension PickyHubDependencies {
    /// Opens a Pickle from any Hub page. Mirrors Quick Start resume: an archived
    /// Pickle returns to the dock first so the HUD can present it. Only Pickles
    /// still on this Mac (open or archived) can be opened.
    var pickleOpener: PickyPickleOpener {
        let sessions = sessionListViewModel
        let launcher = quickStartLauncher
        return PickyPickleOpener(
            canOpen: { id in
                sessions.sessions.contains { $0.id == id } || sessions.archivedSessions.contains { $0.id == id }
            },
            open: { id in
                if sessions.archivedSessions.contains(where: { $0.id == id }) {
                    sessions.unarchive(sessionID: id)
                }
                launcher.openSessionInHUD(sessionID: id)
            }
        )
    }
}
