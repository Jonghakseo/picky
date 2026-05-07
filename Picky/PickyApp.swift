//
//  PickyApp.swift
//  Picky
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import AppKit
import ServiceManagement
import UserNotifications

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@main
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let settingsStore = PickySettingsStore()
    /// Single source of truth for the user-selected light/dark mode. Both the menu bar
    /// companion panel and the HUD overlay observe this object so flipping the toggle
    /// in the companion footer flips the entire UI surface.
    let appearanceStore: PickyAppearanceStore
    private lazy var daemonConfiguration: PickyAgentDaemonConfiguration = {
        let settings = settingsStore.load().normalizedPaths()
        return PickyAgentDaemonConfiguration.development(
            defaultCwd: settings.defaultCwd,
            mainAgentThinkingLevel: settings.mainAgentThinkingLevel
        )
    }()
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
        ),
        appearanceStore: appearanceStore
    )

    override init() {
        self.appearanceStore = PickyAppearanceStore(settingsStore: settingsStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Picky: Starting...")
        print("🎯 Picky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        UNUserNotificationCenter.current().delegate = self

        PickyAnalytics.configure()
        PickyAnalytics.trackAppOpened()

        if !Self.isRunningUnitTests {
            daemonLauncher.start()
            hudOverlayManager.start()
        }
        // Wire the appearance store and shared settings store into singletons that live
        // outside the SwiftUI tree (markdown report viewer / terminal overlay) so every
        // secondary NSPanel flips with the rest of the app and the user's per-panel zoom
        // level (⌘+ / ⌘- / ⌘0) round-trips through the same settings file.
        PickyReportViewerPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyTerminalOverlayPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager, appearanceStore: appearanceStore)
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

extension CompanionAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
