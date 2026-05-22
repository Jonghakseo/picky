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
    /// Watches the main thread for spin (TextKit race, runaway SwiftUI body
    /// updates, etc.). When the UI stops responding for several seconds, the
    /// watchdog captures a `sample` snapshot and spawns the alert helper so
    /// the user can recover without force-quitting. Owned here so the
    /// observer + helper lifecycle matches the app's.
    private var mainThreadWatchdog: PickyMainThreadWatchdog?
    private var mainThreadWatchdogResponder: PickyWatchdogResponder?
    private var mainThreadWatchdogWakeObserver: NSObjectProtocol?
    /// Single source of truth for the user-selected light/dark mode. Both the menu bar
    /// companion panel and the HUD overlay observe this object so flipping the toggle
    /// in the companion footer flips the entire UI surface.
    let appearanceStore: PickyAppearanceStore
    private lazy var daemonConfiguration: PickyAgentDaemonConfiguration = {
        let settings = settingsStore.load().normalizedPaths()
        let effectiveRuntimeMode = AppBundleConfiguration.effectiveRuntimeMode
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
        recentPickleFolderStore: PickySettingsRecentPickleFolderStore(settingsStore: settingsStore),
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
    /// PICKY_REALTIME_OPT_IN=1 builds need Realtime auth to do anything
    /// useful. The gate surfaces a single boot-time / post-onboarding alert
    /// when the user has not signed in yet. Opt-in=0 builds construct it too,
    /// but `evaluate()` short-circuits on `.pi` runtime so the alert never
    /// fires there. Created lazily so the closure that opens Settings can
    /// capture `self.menuBarPanelManager` after it is wired up.
    private lazy var realtimeAuthGate: PickyRealtimeAuthGate = PickyRealtimeAuthGate(
        openSettings: { [weak self] in
            self?.menuBarPanelManager?.present(
                deepLink: PickyDeepLink(tab: .settings, settingsRoute: .mainAgent)
            )
        }
    )
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

        guard !Self.isRunningUnitTests else {
            print("🎯 Picky: Unit test host detected; skipping app services and permission probes")
            return
        }

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
            self.updaterController.updateAutomaticChecksPreference(updated.updatesAutomaticChecksEnabled)
            // Re-applying the same choice is cheap and idempotent; this
            // keeps the language in sync when the settings JSON is edited
            // externally (tests, debug tooling).
            LocaleManager.shared.apply(updated.appLanguage)
            // PICKY_REALTIME_OPT_IN=1: settings save fires whenever
            // onboarding marks completion or the user toggles auth fields.
            // Re-evaluating the gate here means the same alert presenter
            // handles "onboarding just finished, user still hasn't signed
            // in" without needing a dedicated onboarding completion hook.
            // No-op on opt-in=0 builds and de-duped per session inside the
            // gate.
            self.realtimeAuthGate.evaluate()
        }

        PickyAnalytics.configure()
        PickyAnalytics.trackAppOpened()

        if !Self.isRunningUnitTests {
            // Start the main-thread watchdog as early as possible so any
            // launch-time spin (long SwiftUI initial render, blocked daemon
            // wait, etc.) is also covered.
            startMainThreadWatchdog()
            // Make sure the default Picky workspace exists before the daemon
            // starts so the always-on Picky main agent always has a valid cwd
            // (with our seed AGENTS.md) to load. Idempotent — never overwrites
            // user edits.
            PickyWorkspaceSeeder.seedDefaultWorkspace(
                mainAgentRuntimeMode: AppBundleConfiguration.effectiveRuntimeMode
            )
            // Bundled pi-extensions install is opt-in via the Status tab so
            // Picky never modifies `~/.pi/agent` on launch without consent.
            daemonLauncher.start()
            hudOverlayManager.start()
            // Best-effort install of /usr/local/bin/picky when we can do it
            // without prompting for credentials. Anything that would require
            // admin auth (typical fresh /usr/local/bin) is left for the user
            // to confirm explicitly via Settings → Install Shell Command.
            autoInstallShellCommandIfPermitted()
        }
        wireExternalEntryProvider(on: hudAgentClientRouter)
        wirePushToTalkControlHandler(on: hudAgentClientRouter)
        // Wire the appearance store and shared settings store into singletons that live
        // outside the SwiftUI tree (markdown report viewer / terminal overlay) so every
        // secondary NSPanel flips with the rest of the app and the user's per-panel zoom
        // level (⌘+ / ⌘- / ⌘0) round-trips through the same settings file.
        PickyReportViewerPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyToolHistoryPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyTerminalOverlayPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
        PickyDiffViewerPresenter.shared.configure(appearanceStore: appearanceStore, settingsStore: settingsStore)
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

        // PICKY_REALTIME_OPT_IN=1 builds: if the user has not signed in to
        // Codex/ChatGPT or pasted a Platform/Azure API key, agentd's connect
        // will fail before any PTT or text turn can succeed. Surface a
        // boot-time alert that opens Settings on click; the PTT and text
        // entry guards inside CompanionManager still fail closed if the user
        // dismisses this and tries to talk anyway, so the alert is purely an
        // anti-confusion measure. Skip during onboarding because the demo
        // never reaches the daemon; PickyRealtimeAuthGate runs again as soon
        // as the onboarding controller marks completion.
        if onboardingFlowController == nil && !Self.isRunningUnitTests {
            realtimeAuthGate.evaluate()
        }
    }

    /// Try to drop the `/usr/local/bin/picky` wrapper into place silently. We
    /// only act on a clean slot in a user-writable parent directory; stale or
    /// foreign wrappers are left for the panel banner / Settings flow so the
    /// user can confirm the change. Anyone who explicitly uninstalled the
    /// command from Settings has `shellCommandAutoInstallOptedOut == true`
    /// and will be skipped here.
    private func autoInstallShellCommandIfPermitted() {
        let settings = settingsStore.load()
        guard !settings.shellCommandAutoInstallOptedOut else { return }
        switch ShellCommandInstaller.installSilentlyIfPossible() {
        case .installed(let path):
            print("🎯 Picky: auto-installed picky CLI at \(path.path)")
        case .skippedAlreadyPresent:
            break
        case .skippedNeedsAdmin:
            print("🎯 Picky: picky CLI auto-install skipped (requires admin). Use Settings → Install Shell Command.")
        case .skippedMissingCli:
            print("🎯 Picky: picky CLI auto-install skipped (dist/cli.js missing in bundle)")
        }
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

    private func wirePushToTalkControlHandler(on router: PickyAgentClientRouter) {
        router.pushToTalkControlHandler = { [weak self] request in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            self.companionManager.controlPushToTalkFromExternal(action: request.action)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        if let observer = settingsSaveObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsSaveObserver = nil
        }
        stopMainThreadWatchdog()
        companionManager.stop()
        hudOverlayManager.stop()
        agentDaemonPool.terminateAllChildren()
        daemonLauncher.stop()
    }

    private func startMainThreadWatchdog() {
        let settings = settingsStore.load()
        guard settings.mainThreadWatchdogEnabled else {
            print("🎯 Picky: main-thread watchdog disabled by setting")
            return
        }
        let logsDir = PickyAppSupport.defaultRoot().appendingPathComponent("Logs", isDirectory: true)
        let store = PickyWatchdogSampleStore(directory: logsDir)
        let responder = PickyWatchdogResponder(
            pid: ProcessInfo.processInfo.processIdentifier,
            capturer: store,
            launcher: PickyWatchdogHelperLauncher()
        )
        let watchdog = PickyMainThreadWatchdog { [weak responder] in
            responder?.handleSpinDetected()
        }
        watchdog.start()
        mainThreadWatchdog = watchdog
        mainThreadWatchdogResponder = responder

        mainThreadWatchdogWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak watchdog] _ in
            watchdog?.noteWoke(at: Date())
        }
    }

    private func stopMainThreadWatchdog() {
        if let observer = mainThreadWatchdogWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            mainThreadWatchdogWakeObserver = nil
        }
        mainThreadWatchdog?.stop()
        mainThreadWatchdog = nil
        mainThreadWatchdogResponder = nil
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private static var isRunningUnitTests: Bool {
        PickyRuntimeEnvironment.isRunningUnitTests
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
