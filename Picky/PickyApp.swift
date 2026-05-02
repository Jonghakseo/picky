//
//  PickyApp.swift
//  Picky
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct PickyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives primarily in the menu bar panel managed by the AppDelegate.
        // A compact Settings scene is kept for local paths and diagnostics.
        Settings {
            PickySettingsView(viewModel: PickySettingsViewModel())
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let settingsStore = PickySettingsStore()
    private lazy var daemonConfiguration = PickyAgentDaemonConfiguration.development(defaultCwd: settingsStore.load().normalizedPaths().defaultCwd)
    private lazy var daemonLauncher = PickyAgentDaemonLauncher(configuration: daemonConfiguration)
    private lazy var companionManager = CompanionManager(
        agentClient: WebSocketPickyAgentClient(
            configuration: WebSocketPickyAgentClient.Configuration(
                port: daemonConfiguration.port,
                token: daemonConfiguration.token
            )
        )
    )
    private lazy var hudOverlayManager = PickyHUDOverlayManager(
        viewModel: PickySessionListViewModel(
            client: WebSocketPickyAgentClient(
                configuration: WebSocketPickyAgentClient.Configuration(
                    port: daemonConfiguration.port,
                    token: daemonConfiguration.token
                )
            )
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Picky: Starting...")
        print("🎯 Picky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        PickyAnalytics.configure()
        PickyAnalytics.trackAppOpened()

        if !Self.isRunningUnitTests {
            daemonLauncher.start()
            hudOverlayManager.start()
        }
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel only when the user still needs to grant permissions.
        if !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        hudOverlayManager.stop()
        daemonLauncher.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") || $0.contains("xctest") }
    }

    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Picky: Registered as login item")
            } catch {
                print("⚠️ Picky: Failed to register as login item: \(error)")
            }
        }
    }

}
