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

    var permissions: PickyPermissionMonitor { companionManager.permissions }
}
