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

@main
enum PickyApp {
    @MainActor
    private static var delegate: CompanionAppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = CompanionAppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let settingsStore = PickySettingsStore()
    private var settingsSaveObserver: NSObjectProtocol?
    /// Single source of truth for the user-selected light/dark mode. Both the menu bar
    /// companion panel and the HUD overlay observe this object so flipping the toggle
    /// in the companion footer flips the entire UI surface.
    let appearanceStore: PickyAppearanceStore
    private lazy var daemonConfiguration: PickyAgentDaemonConfiguration = {
        let settings = settingsStore.load().normalizedPaths()
        let effectiveRuntimeMode = AppBundleConfiguration.realtimeOptIn ? settings.mainAgentRuntimeMode : .pi
        return PickyAgentDaemonConfiguration.development(
            defaultCwd: settings.defaultCwd,
            mainAgentCwd: settings.mainAgentCwd,
            mainAgentThinkingLevel: settings.mainAgentThinkingLevel,
            mainAgentModelPattern: settings.mainAgentModelPattern,
            pickleAgentThinkingLevel: settings.pickleAgentThinkingLevel,
            pickleAgentModelPattern: settings.pickleAgentModelPattern,
            mainAgentRuntimeMode: effectiveRuntimeMode
        )
    }()
    private lazy var daemonLauncher = PickyAgentDaemonLauncher(configuration: daemonConfiguration)
    private lazy var updaterController: PickyUpdaterController = {
        let settings = settingsStore.load()
        let controller = PickyUpdaterController(
            releaseChannel: AppBundleConfiguration.releaseChannel,
            initialPreference: settings.updateChannel,
            automaticChecksEnabled: settings.updatesAutomaticChecksEnabled
        )
        controller.willRelaunchApplication = { [weak self] in
            // Sparkle is about to swap the .app bundle. Stop bundled/child
            // picky-agentd processes first so their Node children don't crash on cwd.
            self?.agentDaemonPool.terminateAllChildren()
            self?.daemonLauncher.stop()
        }
        return controller
    }()
    /// Companion shares the HUD's `PickyAgentClientRouter`. The router
    /// (1) sends session-scoped commands to the right child daemon — the
    /// primary daemon doesn't own external pickle sessions, so a direct
    /// primary-only client would have its steer rejected with
    /// `Unknown session: …` — and (2) exposes a multi-subscriber events
    /// stream so both the HUD viewModel and CompanionManager can listen
    /// to the same daemon traffic without one of them silently missing
    /// updates. Companion no longer holds its own socket.
    ///
    /// `ownsAgentClientLifecycle: false` because the HUD owns the router
    /// (it's the one calling `connect()` / `disconnect()` from
    /// `hudOverlayManager.start()` / `stop()`). If Companion also called
    /// `disconnect()` on `stop()` it would tear the primary socket and
    /// every cached child connection out from under the HUD viewModel.
    private lazy var companionManager = CompanionManager(
        agentClient: hudAgentClientRouter,
        ownsAgentClientLifecycle: false,
        appearanceStore: appearanceStore
    )
    private lazy var hudPrimaryAgentClient = WebSocketPickyAgentClient(
        configuration: WebSocketPickyAgentClient.Configuration(
            port: daemonConfiguration.port,
            token: daemonConfiguration.token
        )
    )
    private lazy var agentDaemonPool = PickyAgentDaemonPool(
        configuration: PickyAgentDaemonPool.Configuration(
            token: daemonConfiguration.token,
            appSupportRoot: daemonConfiguration.appSupportRoot,
            settingsProvider: { PickySettingsStore().load() }
        )
    )
    private lazy var hudAgentClientRouter = PickyAgentClientRouter(
        primaryClient: hudPrimaryAgentClient,
        pool: agentDaemonPool
    )
    /// Hoisted out of `hudOverlayManager` so the onboarding coordinator can
    /// also observe it (it needs to detect when the user long-presses the demo
    /// Pickle to archive it).
    private lazy var hudSessionViewModel = PickySessionListViewModel(
        client: hudAgentClientRouter,
        manualPickleChildSpawner: hudAgentClientRouter,
        childSessionReleaser: hudAgentClientRouter
    )
    private lazy var hudOverlayManager = PickyHUDOverlayManager(
        viewModel: hudSessionViewModel,
        appearanceStore: appearanceStore,
        settingsStore: settingsStore
    )
    /// Persistent activator that decides whether the takeover overlay should
    /// run on this launch (fresh install or explicit replay via Settings).
    /// Kept as a stored property so the coordinator can mark completion through
    /// the same instance.
    private let onboardingActivator: PickyOnboardingActivator
    private var onboardingFlowController: OnboardingFlowController?
    /// Owned at the app delegate so its state survives panel teardown.
    /// `MenuBarPanelManager` reads/writes it, and `PickyDeepLinkDispatcher`
    /// routes `picky://` clicks through `present(deepLink:)`.
    private let panelNavigator = PickyPanelNavigator()

    override init() {
        self.appearanceStore = PickyAppearanceStore(settingsStore: settingsStore)
        self.onboardingActivator = PickyOnboardingActivator(settingsStore: settingsStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Picky: Starting...")
        print("🎯 Picky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Apply the persisted language choice before any SwiftUI host is
        // built so the very first frame already renders in the chosen
        // language. Subsequent in-app switches go through the same
        // `apply(_:)` path from the settings UI.
        LocaleManager.shared.apply(settingsStore.load().appLanguage)

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        UNUserNotificationCenter.current().delegate = self
        PickyAppMenuInstaller.install(updaterController: updaterController.standardController)
        // Touch the lazy property so Sparkle starts checking on launch when
        // the build channel allows it. Updater stays inert on alpha builds.
        _ = updaterController
        settingsSaveObserver = NotificationCenter.default.addObserver(
            forName: .pickySettingsDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let updated = self.settingsStore.load()
            self.updaterController.updateChannelPreference(updated.updateChannel)
            self.updaterController.updateAutomaticChecksPreference(updated.updatesAutomaticChecksEnabled)
            // Re-applying the same choice is cheap and idempotent; this
            // keeps the language in sync when the settings JSON is edited
            // externally (tests, debug tooling).
            LocaleManager.shared.apply(updated.appLanguage)
        }

        PickyAnalytics.configure()
        PickyAnalytics.trackAppOpened()

        if !Self.isRunningUnitTests {
            // Make sure the default Picky workspace exists before the daemon
            // starts so the always-on Picky main agent always has a valid cwd
            // (with our seed AGENTS.md) to load. Idempotent — never overwrites
            // user edits.
            PickyWorkspaceSeeder.seedDefaultWorkspace()
            // Bundled pi-extensions install is opt-in via the Status tab so
            // Picky never modifies `~/.pi/agent` on launch without consent.
            daemonLauncher.start()
            hudOverlayManager.start()
        }
        wireExternalEntryProvider(on: hudAgentClientRouter)
        // Wire the appearance store and shared settings store into singletons that live
        // outside the SwiftUI tree (markdown report viewer / terminal overlay) so every
        // secondary NSPanel flips with the rest of the app and the user's per-panel zoom
        // level (⌘+ / ⌘- / ⌘0) round-trips through the same settings file.
        PickyReportViewerPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyToolHistoryPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyTerminalOverlayPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            appearanceStore: appearanceStore,
            updaterController: updaterController,
            navigator: panelNavigator
        )
        // Wire the conversation-card `picky://` link handler to the panel
        // manager. The dispatcher is a singleton so any markdown surface
        // (HUD agent bubbles, companion message bubbles) can route through
        // the same path without each view having to know how to find the
        // panel manager.
        PickyDeepLinkDispatcher.shared.configure { [weak self] link in
            self?.menuBarPanelManager?.present(deepLink: link)
        }
        companionManager.start()
        // Auto-open the panel only when the user still needs to finish setup
        // (macOS permissions or local Pi runtime). Mirrors what the prerequisites
        // surface gates on so launch matches the panel's own visibility logic.
        if !companionManager.allPrerequisitesMet {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        // Show the interactive demo on a fresh install (or whenever the user
        // hits "Replay onboarding" in Settings). Prerequisites take priority
        // so the user fixes blockers before we hand them a guided tour they
        // can't actually complete.
        if companionManager.allPrerequisitesMet && onboardingActivator.shouldShowOnboarding {
            // Cursor-bubble onboarding: no takeover panel, guidance lives in the
            // Picky cursor's speech bubble, real shortcut/dictation pipelines
            // fire as usual and submissions are intercepted before the daemon.
            let controller = OnboardingFlowController(
                activator: onboardingActivator,
                companionManager: companionManager,
                hudRouter: hudAgentClientRouter,
                hudViewModel: hudSessionViewModel
            )
            onboardingFlowController = controller
            controller.start()
        }
        registerAsLoginItemIfNeeded()
    }

    /// Wires the router's `externalEntryContextProvider` so CLI submissions can
    /// reuse the same context capture pipeline used by voice/text entries. The
    /// closure runs on the MainActor (router-isolated), reuses
    /// `PickyVoiceContextCaptureCoordinator`, and falls back to a transcript-only
    /// context if screen capture fails so the CLI call still gets through with a
    /// usable packet.
    ///
    /// After capture succeeds, the closure also pushes an
    /// `externalContextCaptured` event into the companion's interaction
    /// coordinator so the cursor flips into the processing/loading state while
    /// the daemon turns the request into a quickReply — without this, the
    /// reducer never sees a corresponding user input and the cursor would skip
    /// straight from idle to the response bubble.
    private func wireExternalEntryProvider(on router: PickyAgentClientRouter) {
        router.externalEntryContextProvider = { [weak self] request in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            let coordinator = PickyVoiceContextCaptureCoordinator()
            let transcript = request.text ?? ""
            guard let result = try await coordinator.captureContext(transcript: transcript, source: "cli") else {
                throw PickyAgentClientRouterError.externalEntryProviderUnavailable
            }
            self.companionManager.noteExternalSubmission(text: transcript, context: result.contextPacket)
            return result.contextPacket
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = settingsSaveObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsSaveObserver = nil
        }
        companionManager.stop()
        hudOverlayManager.stop()
        agentDaemonPool.terminateAllChildren()
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

    /// Notification identifiers are emitted by `PickySessionListViewModel.notification(for:)`
    /// as `\(sessionID):completed`, `\(sessionID):failed`, or `\(sessionID):waiting:\(requestID)`.
    /// Session IDs are `session-<uuid>` (no colons), so the substring before the first colon is
    /// the session ID we want to focus in the HUD dock.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let sessionID = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identifier
        Task { @MainActor [weak self] in
            self?.hudOverlayManager.focusSession(id: sessionID)
            completionHandler()
        }
    }
}
