//
//  PickyApp.swift
//  Picky
//
//  Menu bar companion app. Opening Hub temporarily gives Picky a Dock icon
//  and regular app activation; closing Hub returns to menu bar-only operation.
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
        PickyRuntimeEnvironment.resetUnitTestUserDefaults()
        let app = NSApplication.shared
        if PickyRuntimeEnvironment.isRunningUnitTests && !PickyRuntimeEnvironment.runsPrePushUIEffectTests {
            // Offscreen tests need AppKit, not permission to activate on the
            // developer's desktop. Set this before the application run loop.
            app.setActivationPolicy(.prohibited)
        }
        let delegate = CompanionAppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

/// Manages the companion lifecycle: creates the status item + hub window and
/// starts the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: PickyStatusItemController?
    private var hubWindowController: PickyHubWindowController?
    private let settingsStore = PickySettingsStore()
    private lazy var settingsPersistence = PickySettingsPersistenceCoordinator.shared(for: settingsStore)
    private let settingsTerminationDrain = PickySettingsTerminationDrain()
    private lazy var settingsMutationCoordinator = PickySettingsMutationCoordinator(
        store: settingsStore,
        persistence: settingsPersistence
    )
    private lazy var notificationPreferencesStore = PickyNotificationPreferencesStore(settingsStore: settingsStore)
    private var settingsSaveObserver: NSObjectProtocol?
    private var localeChangeObserver: NSObjectProtocol?
    /// Single bounded snapshot used to distinguish the prior crash/force-quit
    /// from a clean app termination after the next launch.
    private lazy var lifecycleDiagnosticsStore = PickyLifecycleDiagnosticsStore(
        logsDirectory: PickyAppSupport.defaultRoot().appendingPathComponent("Logs", isDirectory: true)
    )
    /// Watches the main thread for spin (TextKit race, runaway SwiftUI body
    /// updates, etc.). When the UI stops responding for several seconds, the
    /// watchdog captures a `sample` snapshot and spawns the alert helper so
    /// the user can recover without force-quitting. Owned here so the
    /// observer + helper lifecycle matches the app's.
    private var mainThreadWatchdog: PickyMainThreadWatchdog?
    private var mainThreadWatchdogResponder: PickyWatchdogResponder?
    private var mainThreadWatchdogWorkspaceObservers: [NSObjectProtocol] = []
    private var mainThreadWatchdogDistributedObservers: [NSObjectProtocol] = []
    private let mainThreadWatchdogNotificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.jonghakseo.picky.watchdog.notifications"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    /// Single source of truth for the user-selected light/dark mode. Both the menu bar
    /// companion panel and the HUD overlay observe this object so footer icon actions
    /// update the entire UI surface.
    let appearanceStore: PickyAppearanceStore
    /// Single source of truth for whether the HUD dock panels are shown. Hiding the
    /// panels does not stop their shared session/client lifecycle.
    let hudVisibilityStore: PickyHUDVisibilityStore
    /// Single source of truth for the global app font scale (⌘+ / ⌘- / ⌘0).
    /// Injected at every NSPanel hosting root so the HUD, Conversation, Companion,
    /// Settings, and Feedback surfaces all scale together. Detached report and
    /// terminal panels still keep their own per-panel zoom, multiplied on top of
    /// this global scale.
    let fontScaleStore: PickyAppFontScaleStore
    private lazy var daemonConfiguration: PickyAgentDaemonConfiguration = {
        let settings = settingsStore.load().normalizedPaths()
        return PickyAgentDaemonConfiguration.development(
            defaultCwd: settings.defaultCwd,
            mainAgentCwd: settings.mainAgentCwd,
            mainAgentThinkingLevel: settings.mainAgentThinkingLevel,
            mainAgentModelPattern: settings.mainAgentModelPattern,
            pickleAgentThinkingLevel: settings.pickleAgentThinkingLevel,
            pickleAgentModelPattern: settings.pickleAgentModelPattern,
            piBinaryPath: settings.piBinaryPath,
            piCodingAgentDir: settings.piCodingAgentDir
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
            self?.agentDaemonPool.terminateAllChildren(waitForExit: true)
            self?.daemonLauncher.stopAndWaitForExit()
            self?.lifecycleDiagnosticsStore.markCurrentRunClean(reason: .update)
        }
        controller.confirmReadyUpdateInstall = { [weak self] in
            self?.confirmReadyUpdateInstall()
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
        voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator(
            contextPreflightPreparation: { [weak self] in
                await self?.hubWindowController?.restoreExternalForegroundForVoiceContextCapture()
            }
        ),
        appearanceStore: appearanceStore,
        fontScaleStore: fontScaleStore
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
        pool: agentDaemonPool,
        notificationPreferencesProvider: notificationPreferencesStore,
        supportsSessionProjectionV2: true
    )
    private lazy var hudActualPanelVisibilityStore = PickyHUDActualPanelVisibilityStore()
    /// Completion effects are app-owned. The durable child envelope already
    /// contains the selected Main Picky and macOS channels.
    private lazy var completionNotificationCoordinator = PickyCompletionNotificationCoordinator(
        isConversationCardVisible: { [weak self] sessionID in
            self?.hudActualPanelVisibilityStore.isConversationCardVisible(sessionID: sessionID) ?? false
        },
        deliverMain: { [weak self] envelope in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            try await self.hudAgentClientRouter.deliverCompletionToPrimary(envelope)
        }
    )
    /// Hoisted out of `hudOverlayManager` so other app-level collaborators can
    /// observe the same session list instance.
    private lazy var hudSessionViewModel = PickySessionListViewModel(
        client: hudAgentClientRouter,
        isConversationCardVisible: { [weak self] sessionID in
            self?.hudActualPanelVisibilityStore.isConversationCardVisible(sessionID: sessionID) ?? false
        },
        notificationPreferencesProvider: notificationPreferencesStore,
        recentPickleFolderStore: PickySettingsRecentPickleFolderStore(settingsStore: settingsStore),
        dockLayoutStore: PickySettingsDockLayoutStore(settingsStore: settingsStore),
        manualPickleChildSpawner: hudAgentClientRouter,
        childSessionReleaser: hudAgentClientRouter,
        projectionOwnerReconnector: hudAgentClientRouter
    )
    private lazy var hudOverlayManager = PickyHUDOverlayManager(
        viewModel: hudSessionViewModel,
        appearanceStore: appearanceStore,
        fontScaleStore: fontScaleStore,
        visibilityStore: hudVisibilityStore,
        actualPanelVisibilityStore: hudActualPanelVisibilityStore,
        settingsStore: settingsStore,
        composerDictation: companionManager.composerDictation
    )
    /// Orders Picky's own always-on-top windows out while a macOS secure
    /// authorization surface (such as App Store download confirmation) is active.
    private let secureSurfaceWindowCoordinator = PickySecureSurfaceWindowCoordinator()
    /// Shared with the plugin manager UI. Subscribes to the agent client for
    /// `pluginsReloaded` broadcasts and exposes a single async `reload()` the
    /// extensions section invokes after install/uninstall.
    private lazy var pluginReloadController = PickyPluginReloadController(client: hudAgentClientRouter)
    /// Subscription plan limits shared by the Hub, the menu bar, and the HUD.
    private lazy var usageLimitsStore = PickyUsageLimitsStore(client: hudAgentClientRouter)
    private var usageStatusItemsController: PickyUsageStatusItemsController?
    /// Owned at the app delegate so hub page selection survives the window
    /// being closed. `PickyDeepLinkDispatcher` routes `picky://` clicks
    /// through `present(deepLink:)`.
    private let hubNavigator = PickyHubNavigator()
    private let hubModalHost = PickyHubModalHost()
    private let hubForegroundContextPreserver = PickyHubForegroundContextPreserver()
    private nonisolated let appActivationRouter: PickyAppActivationRouter
    private lazy var hubSettingsViewModel = PickySettingsViewModel(store: settingsStore, persistence: settingsPersistence)
    /// Remote phone access. Composed only outside unit tests, and only after
    /// the session list and companion exist, because the hub hands phone
    /// requests straight to them. Nothing listens until the user turns the
    /// setting on; `apply(settings:)` below is what starts and stops it.
    private var remoteAccessController: PickyRemoteAccessController?
    private lazy var remoteDictationTranscriber = PickyRemoteDictationTranscriber()
    private lazy var remoteMainAgentAdapter = PickyRemoteMainAgentAdapter(companion: companionManager)
    /// Bounded, redacted `picky-debug` trace buffer. Always on: it records
    /// metadata about ordinary keyboard/voice input too, not just injected
    /// debug commands.
    private var debugTraceRecorder: PickyDebugTraceRecorder?
    /// Stable per-launch identity reported in the debug snapshot.
    private let debugInstanceID = UUID().uuidString

    override init() {
        self.appActivationRouter = PickyAppActivationRouter()
        self.appearanceStore = PickyAppearanceStore(settingsStore: settingsStore)
        self.hudVisibilityStore = PickyHUDVisibilityStore(settingsStore: settingsStore)
        self.fontScaleStore = PickyAppFontScaleStore(settingsStore: settingsStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Picky: Starting...")
        print("🎯 Picky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        let launchSettings = settingsStore.load()
        // Capture the settings that are baked into the running app / primary
        // daemon at launch so the Settings footer can offer a relaunch only
        // when a later edit actually needs one.
        PickyRestartSettingsSnapshotStore.captureIfNeeded(settings: launchSettings)
        // Apply the persisted language choice before any SwiftUI host is
        // built so the very first frame already renders in the chosen
        // language. Subsequent in-app switches go through the same
        // `apply(_:)` path from the settings UI.
        LocaleManager.shared.apply(launchSettings.appLanguage)

        guard !Self.isRunningUnitTests else {
            print("🎯 Picky: Unit test host detected; skipping app services and permission probes")
            return
        }

        _ = lifecycleDiagnosticsStore.recordLaunch(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        )

        PickyRuntimeEnvironment.userDefaults.register(defaults: ["NSInitialToolTipDelay": 0])
        UNUserNotificationCenter.current().delegate = self
        PickyAppMenuInstaller.install(updaterController: updaterController)
        // AppKit chrome resolves its titles once; rebuild it after a runtime
        // language switch so it matches the SwiftUI surfaces.
        localeChangeObserver = NotificationCenter.default.addObserver(
            forName: LocaleManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            PickyAppMenuInstaller.install(updaterController: self.updaterController)
            self.statusItemController?.refreshLocalizedLabels()
            self.usageStatusItemsController?.update()
        }
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
            self.remoteAccessController?.apply(settings: updated.remoteAccess)
            // Re-applying the same choice is cheap and idempotent; this
            // keeps the language in sync when the settings JSON is edited
            // externally (tests, debug tooling).
            LocaleManager.shared.apply(updated.appLanguage)
        }

        PickyAnalytics.configure()
        PickyAnalytics.trackAppOpened()
        // The router must have its registry-backed bridge source before the
        // daemon can accept a v2 handoff or CLI request.
        wireDockGroupsProvider(on: hudAgentClientRouter)
        hudAgentClientRouter.completionNotificationCoordinator = completionNotificationCoordinator

        if !Self.isRunningUnitTests {
            // Start the main-thread watchdog as early as possible so any
            // launch-time spin (long SwiftUI initial render, blocked daemon
            // wait, etc.) is also covered.
            startMainThreadWatchdog()
            // Make sure the default Picky workspace exists before the daemon
            // starts so the always-on Picky main agent always has a valid cwd
            // (with our seed AGENTS.md) to load. Idempotent — never overwrites
            // user edits.
            PickyWorkspaceSeeder.seedDefaultWorkspace()
            // Bundled pi-extensions install is opt-in via the Status tab so
            // Picky never modifies `~/.pi/agent` on launch without consent.
            daemonLauncher.start()
            // GeneratedReports/ accumulates a markdown file per opened
            // session message and is never written back to disk after
            // first render. Sweep entries older than 30 days off the main
            // thread so it doesn't grow unboundedly across long-running
            // installs. Errors are swallowed inside the pruner so a
            // filesystem hiccup never blocks app launch.
            Task.detached(priority: .background) {
                PickyGeneratedReportsPruner().prune()
            }
            secureSurfaceWindowCoordinator.start()
            companionManager.hudInkPassThroughHitTest = { [weak self] point in
                self?.hudOverlayManager.containsInkPassThroughPoint(point) ?? false
            }
            companionManager.onFocusPickleShortcut = { [weak self] mouseLocation in
                self?.hudOverlayManager.focusUnreadOrRecentSession(mouseLocation: mouseLocation)
            }
            // "Open Pickle" on an answered delegation question in Quick Input:
            // the same unarchive-then-present path as the Hub.
            companionManager.quickInputPanelManager.pickleOpener = PickyPickleOpener(
                canOpen: { [weak self] id in
                    guard let sessions = self?.hudSessionViewModel else { return false }
                    return sessions.sessions.contains { $0.id == id } || sessions.archivedSessions.contains { $0.id == id }
                },
                open: { [weak self] id in
                    guard let self else { return }
                    if self.hudSessionViewModel.archivedSessions.contains(where: { $0.id == id }) {
                        self.hudSessionViewModel.unarchive(sessionID: id)
                    }
                    self.hudOverlayManager.focusSession(id: id)
                }
            )
            // Composer-initiated delayed-action install reuses the plugin
            // manager's reload bookkeeping instead of its own ad-hoc path.
            hudSessionViewModel.onScheduledSendPluginInstalled = { [weak self] in
                self?.pluginReloadController.notePluginsChanged()
            }
            // Subscribed before the view model consumes its first event, because
            // projection frames are never replayed to a late subscriber.
            companionManager.bindSessionProjectionTransitions(to: hudSessionViewModel.sessionProjectionTransitions)
            hudOverlayManager.usageLimitsStore = usageLimitsStore
            hudOverlayManager.start()
            // Feedback the user submitted before the last quit is still on
            // disk. Pick up anything safe to resume; submissions whose Slack
            // outcome was never confirmed stay put and wait for the user.
            PickyFeedbackOutboxCenter.shared.resumePendingJobs()
            // Best-effort install of /usr/local/bin/picky when we can do it
            // without prompting for credentials. Anything that would require
            // admin auth (typical fresh /usr/local/bin) is left for the user
            // to confirm explicitly via Settings → Install Shell Command.
            autoInstallShellCommandIfPermitted()
            composeRemoteAccess()
        }
        wireExternalEntryProvider(on: hudAgentClientRouter)
        wirePushToTalkControlHandler(on: hudAgentClientRouter)
        wirePickySettingsControlHandler(on: hudAgentClientRouter)
        wireDebugControl(on: hudAgentClientRouter)
        // Wire the appearance store and shared settings store into singletons that live
        // outside the SwiftUI tree (markdown report viewer / tool history viewer) so every
        // secondary NSPanel flips with the rest of the app and the user's per-panel zoom
        // level (⌘+ / ⌘- / ⌘0) round-trips through the same settings file.
        PickyReportViewerPresenter.shared.configure(appearanceStore: appearanceStore, fontScaleStore: fontScaleStore, settingsStore: settingsStore)
        PickyToolHistoryPresenter.shared.configure(appearanceStore: appearanceStore, fontScaleStore: fontScaleStore, settingsStore: settingsStore)
        let hubDependencies = PickyHubDependencies(
            companionManager: companionManager,
            sessionListViewModel: hudSessionViewModel,
            settingsViewModel: hubSettingsViewModel,
            settingsStore: settingsStore,
            appearanceStore: appearanceStore,
            fontScaleStore: fontScaleStore,
            hudVisibilityStore: hudVisibilityStore,
            updaterController: updaterController,
            pluginReloadController: pluginReloadController,
            agentClient: hudAgentClientRouter,
            navigator: hubNavigator,
            modalHost: hubModalHost,
            statisticsStore: PickyHubStatisticsStore(client: hudAgentClientRouter),
            quickStartLauncher: PickyHubQuickStartLauncher(
                sessions: hudSessionViewModel,
                defaultCwd: { [settingsStore] in settingsStore.load().normalizedPaths().defaultCwd },
                presentSessionInHUD: { [weak self] sessionID in
                    guard let self else { return }
                    if let displayID = self.hubWindowController?.displayID {
                        self.hudOverlayManager.focusSession(id: sessionID, targetDisplayID: displayID)
                    } else {
                        self.hudOverlayManager.focusSession(id: sessionID)
                    }
                }
            ),
            pluginCatalog: PickyHubPluginCatalogViewModel(
                curated: PickyCuratedPluginsViewModel(),
                pluginReloadController: pluginReloadController,
                bundled: PickyExtensionsSectionViewModel()
            ),
            remoteAccess: remoteAccessController,
            usageLimitsStore: Self.isRunningUnitTests ? nil : usageLimitsStore
        )
        let hubWindowController = PickyHubWindowController(
            dependencies: hubDependencies,
            foregroundContextPreserver: hubForegroundContextPreserver
        )
        self.hubWindowController = hubWindowController
        statusItemController = PickyStatusItemController(
            hubWindowController: hubWindowController,
            hudVisibilityStore: hudVisibilityStore,
            appearanceStore: appearanceStore,
            settingsViewModel: hubSettingsViewModel,
            navigator: hubNavigator,
            modalHost: hubModalHost
        )
        // Wire the conversation-card `picky://` link handler to the hub. The
        // dispatcher is a singleton so any markdown surface (HUD agent
        // bubbles, hub conversation bubbles) can route through the same path.
        PickyDeepLinkDispatcher.shared.configure { [weak self] link in
            self?.statusItemController?.present(deepLink: link)
        }
        if !Self.isRunningUnitTests {
            startUsageLimits(hubWindowController: hubWindowController)
        }
        companionManager.start()
        // Auto-open the hub only when the user still needs to finish macOS
        // permissions setup; the dashboard hosts the prerequisites surface.
        if !companionManager.permissions.allGranted {
            statusItemController?.showHubOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // HUD panels can be visible while Hub is minimized or the app is hidden,
        // so AppKit's aggregate hasVisibleWindows flag is not a Hub visibility test.
        // Defer presentation briefly because a notification response can arrive
        // immediately before or after this reopen callback; notification intent wins.
        appActivationRouter.handleReopen { [weak self] in
            self?.hubWindowController?.show()
        }
        return false
    }

    /// Polls plan limits and keeps the pinned menu bar items in sync. Clicking
    /// a usage item or "View all limits" in the HUD opens Statistics > AI usage.
    private func startUsageLimits(hubWindowController: PickyHubWindowController) {
        let openUsage: () -> Void = { [weak self, weak hubWindowController] in
            self?.hubNavigator.showStatistics(tab: .usage, anchor: .planLimits)
            hubWindowController?.show()
        }
        usageLimitsStore.openUsageInHub = openUsage
        usageStatusItemsController = PickyUsageStatusItemsController(
            store: usageLimitsStore,
            openUsage: openUsage,
            didChangeItemSet: { [weak self] in self?.statusItemController?.moveToLeadingEdge() }
        )
        usageLimitsStore.start()
    }

    /// Every "install the downloaded update" entry point lands here so the
    /// relaunch always asks first when Pickles are mid-response. The Hub hosts
    /// the dialog, so bring it forward (an open Hub keeps its position).
    private func confirmReadyUpdateInstall() {
        hubWindowController?.show()
        PickyHubUpdateInstallConfirmation.present(
            updaterController: updaterController,
            modalHost: hubModalHost,
            interruptedPickleCount: PickyUpdateRestartPolicy.interruptedPickleCount(
                statuses: hudSessionViewModel.sessions.map(\.status)
            )
        )
    }

    /// Builds the remote hub. The gateway process starts here only when the
    /// user left remote access on; otherwise the controller sits idle and the
    /// settings toggle starts it later through `apply(settings:)`.
    private func composeRemoteAccess() {
        let transcriber = remoteDictationTranscriber
        remoteAccessController = PickyRemoteAccessController(
            settings: settingsStore.load().remoteAccess,
            gateway: PickyRemoteGatewayLauncher(appSupportRoot: daemonConfiguration.appSupportRoot),
            transport: PickyRemoteHubClient(),
            overlaySource: hudSessionViewModel,
            topologySource: PickyRemoteDaemonTopologyProvider(
                pool: agentDaemonPool,
                token: daemonConfiguration.token,
                primaryPort: daemonConfiguration.port
            ),
            requestHandler: PickyRemoteHubRequestHandler(
                sessions: hudSessionViewModel,
                mainAgent: remoteMainAgentAdapter,
                dictation: transcriber
            ),
            dictationReadiness: { transcriber.readiness() }
        )
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
            self.companionManager.noteExternalSubmission(kind: request.kind, text: transcript, context: result.contextPacket)
            return result.contextPacket
        }
    }

    private func wirePushToTalkControlHandler(on router: PickyAgentClientRouter) {
        router.pushToTalkControlHandler = { [weak self] request in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            self.companionManager.controlPushToTalkFromExternal(action: request.action)
        }
    }

    private func wirePickySettingsControlHandler(on router: PickyAgentClientRouter) {
        let handler = PickySettingsControlHandler(
            settingsStore: settingsStore,
            mutationCoordinator: settingsMutationCoordinator,
            applyDockVisibility: { [weak self] visible, displayID in
                guard let self else { return }
                if let displayID {
                    self.hudVisibilityStore.setVisible(visible, for: displayID, persist: false)
                } else {
                    self.hudVisibilityStore.setAllVisible(visible, persist: false)
                }
                // Preserve the store's canonical override representation even
                // when the effective visibility did not change.
                self.hudVisibilityStore.reloadFromSettings()
            },
            applyMainAgentCommand: { [weak self] command in
                guard let self else { return "Picky settings control is no longer available." }
                do {
                    return try await self.hudAgentClientRouter.sendAwaitingError(
                        command,
                        timeout: 5.0,
                        requireAcknowledgement: true
                    )?.message
                } catch {
                    return error.localizedDescription
                }
            }
        )
        router.pickySettingsControlHandler = { request in
            try await handler.handle(request)
        }
    }

    /// Wires the `picky-debug` channel: the always-on interaction trace and the
    /// app-action handler the daemon forwards CLI requests to.
    ///
    /// Attaching the trace observer here is what makes ordinary input visible to
    /// `picky-debug`: main-agent keyboard, Quick Input, and push-to-talk turns
    /// run through the same interaction coordinator, so injected input needs no
    /// separate instrumentation. The one production input that skips the
    /// coordinator is Quick Input sent to an armed Pickle, which goes straight
    /// out as a steer/follow-up command; only the daemon side of that turn is
    /// traced.
    private func wireDebugControl(on router: PickyAgentClientRouter) {
        // Publishing is awaited inside the recorder's single drain task, so a
        // stalled socket holds one in-flight batch instead of one task per
        // recorded transition.
        let recorder = PickyDebugTraceRecorder { [weak router] records in
            guard let router else { return false }
            return await router.debugChannel.publish(records)
        }
        debugTraceRecorder = recorder
        companionManager.interactionCoordinator.onEventTraced = { [weak recorder] sample in
            recorder?.recordInteraction(sample)
        }

        let handler = PickyDebugControlHandler(
            dependencies: PickyDebugControlHandler.Dependencies(
                snapshot: { [weak self] in
                    self?.makeDebugAppSnapshot() ?? PickyDebugAppSnapshot.unavailable
                },
                busyReason: { [weak self] action in self?.debugBusyReason(for: action) },
                submitText: { [weak self] text, inputID in
                    guard let self else { return false }
                    return await self.companionManager.sendDirectMessage(text, inputID: inputID)
                },
                controlPushToTalk: { [weak self] action in
                    self?.companionManager.controlPushToTalkFromExternal(action: action)
                },
                isPushToTalkHeld: { [weak self] in self?.companionManager.isPushToTalkShortcutHeld ?? false },
                activeVoiceInputID: { [weak self] in self?.companionManager.interactionVoiceInputID }
            ),
            recorder: recorder
        )
        router.debugChannel.appRequestHandler = { request in
            try await handler.handle(request)
        }
    }

    /// Refuses a debug action that would collide with live human input. Voice
    /// capture and a debug text injection share one submission lane, so letting
    /// both run would change what the user is actually testing.
    private func debugBusyReason(for action: PickyDebugAppAction) -> String? {
        let companion = companionManager
        switch action {
        case .snapshot:
            return nil
        case .text:
            if companion.isPushToTalkShortcutHeld { return "push-to-talk is held" }
            if companion.buddyDictationManager.isDictationInProgress { return "dictation is running" }
            if companion.isSendingDirectMessage { return "another message is being sent" }
            return nil
        case .pttPress:
            if companion.buddyDictationManager.isDictationInProgress { return "dictation is running" }
            if companion.isSendingDirectMessage { return "a message is being sent" }
            return nil
        case .pttRelease:
            return nil
        }
    }

    private func makeDebugAppSnapshot() -> PickyDebugAppSnapshot {
        let companion = companionManager
        let state = companion.interactionCoordinator.projection.state
        let dictation = companion.buddyDictationManager
        let permissions = companion.permissions
        let recorder = debugTraceRecorder
        return PickyDebugAppSnapshot(
            instanceId: debugInstanceID,
            capturedAt: Date(),
            monotonicMs: PickyDebugTraceClock.monotonicMs(),
            inputPhase: state.input.debugLabel,
            outputPhase: state.output.debugLabel,
            overlayPhase: state.overlay.debugLabel,
            interactionSequence: companion.interactionProjectionSequence,
            pendingTextInputCount: state.pendingTextInputs.count,
            pendingVoiceInputCount: state.pendingVoiceInputs.count,
            trackedContextCount: state.contextOwnership.count,
            queuedSpeechCount: state.queuedSpeechReplies.count,
            activeInputId: state.debugActiveInputID?.uuidString,
            activeContextId: state.debugActiveContextID,
            activeSpeechId: state.debugActiveSpeechID?.uuidString,
            armedSessionId: companion.selectionStore.screenContextTargetSessionID,
            selectedSessionId: companion.selectionStore.selectedSessionID,
            voiceState: companion.voiceState.debugLabel,
            voicePhase: companion.voiceInteractionState.phase.debugLabel,
            pushToTalkHeld: companion.isPushToTalkShortcutHeld,
            dictationInProgress: dictation.isDictationInProgress,
            dictationFinalizing: dictation.isFinalizingTranscript,
            transcriptionProviderConfigured: dictation.isTranscriptionProviderConfigured,
            ttsPlaybackEnabled: companion.ttsPlaybackEnabled,
            daemonChannelAvailable: true,
            accessibilityGranted: permissions.hasAccessibility,
            screenRecordingGranted: permissions.hasScreenRecording,
            microphoneGranted: permissions.hasMicrophone,
            screenContentGranted: permissions.hasScreenContent,
            sendingDirectMessage: companion.isSendingDirectMessage,
            waitingForCursorResponse: companion.isWaitingForCursorResponse,
            quickInputPanelVisible: companion.isQuickInputPanelVisible,
            tracePendingCount: recorder?.pendingCount ?? 0,
            tracePendingCapacity: recorder?.pendingCapacity ?? 0,
            traceRecordedCount: recorder?.recordedCount ?? 0,
            traceDroppedCount: recorder?.droppedCount ?? 0,
            traceTransportFailureCount: recorder?.transportFailureCount ?? 0
        )
    }

    private func wireDockGroupsProvider(on router: PickyAgentClientRouter) {
        router.pickleSessionSummariesProvider = { [weak self] in
            self?.hudSessionViewModel.pickleSessionSummariesForCLI() ?? []
        }
        router.cliSessions.projectedSessionRevisionProvider = { [weak self] sessionID in
            self?.hudSessionViewModel.projectedSessionRevisionForCLI(sessionID: sessionID)
        }
        hudSessionViewModel.onSessionProjectionStorageChanged = { [weak router] in
            router?.sessionProjectionStorageDidChange()
        }
        router.onSessionProjectionSnapshotReceived = { [weak self] isPrimary in
            self?.hudSessionViewModel.handleSessionProjectionSnapshotReceived(isPrimary: isPrimary)
        }
        router.dockGroupsProvider = { [weak self] in
            guard let self else { return [] }
            return self.hudSessionViewModel.dockGroupsSnapshotForCLI()
        }
        router.dockGroupsManager = { [weak self] request in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            return try await self.hudSessionViewModel.manageDockGroups(request)
        }
        router.pickleDeletionCleanupHandler = { [weak self] sessionID in
            guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
            self.hudSessionViewModel.finalizeDeletedArchivedSession(sessionID: sessionID)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRunningUnitTests else { return .terminateNow }
        guard settingsPersistence.hasPendingWork else { return .terminateNow }
        _ = settingsTerminationDrain.beginRace(
            drain: { [settingsPersistence] completion in
                settingsPersistence.drain { result in
                    completion((try? result.get()) != nil)
                }
            },
            scheduleTimeout: { completion in
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: completion)
            },
            onSettled: { didDrain in
                if didDrain {
                    sender.reply(toApplicationShouldTerminate: true)
                } else {
                    PickyRelauncher.cancelPendingRelaunch()
                    print("⚠️ Picky settings drain failed or timed out; cancelling termination to preserve accepted writes.")
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
        )
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Self.isRunningUnitTests {
            PickyRuntimeEnvironment.resetUnitTestUserDefaults()
            return
        }
        if let observer = settingsSaveObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsSaveObserver = nil
        }
        if let observer = localeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            localeChangeObserver = nil
        }
        // Drafts are persisted on a debounce; keep the last keystrokes on quit.
        hudSessionViewModel.composerDraftController.flushPendingDrafts()
        stopMainThreadWatchdog()
        secureSurfaceWindowCoordinator.stop()
        companionManager.stop()
        remoteAccessController?.stopForAppTermination()
        hudOverlayManager.stop()
        agentDaemonPool.terminateAllChildren(waitForExit: true)
        daemonLauncher.stopAndWaitForExit()
        _ = lifecycleDiagnosticsStore.markCurrentRunClean(reason: .normal)
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
        // Capture on the soft-stall edge: the spin edge fires as the main
        // thread is already recovering, so a sample started there records the
        // aftermath instead of the hang.
        watchdog.onSoftStallDetected = { [weak responder] age, _ in
            responder?.handleSoftStallDetected(age: age)
        }
        watchdog.onSoftStallRecovered = { [weak responder] _ in
            responder?.handleStallRecovered()
        }
        responder.heartbeatAge = { [weak watchdog] in watchdog?.heartbeatAge(at: Date()) }
        store.heartbeatAgeProvider = { [weak watchdog] in watchdog?.heartbeatAge(at: Date()) }
        watchdog.start()
        mainThreadWatchdog = watchdog
        mainThreadWatchdogResponder = responder

        mainThreadWatchdogWorkspaceObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: mainThreadWatchdogNotificationQueue
            ) { [weak watchdog] _ in
                watchdog?.noteWoke(at: Date())
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: mainThreadWatchdogNotificationQueue
            ) { [weak watchdog] _ in
                watchdog?.suspendMonitoring(for: .displaySleep, at: Date())
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: mainThreadWatchdogNotificationQueue
            ) { [weak watchdog] _ in
                watchdog?.resumeMonitoring(for: .displaySleep, at: Date())
            },
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        mainThreadWatchdogDistributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: mainThreadWatchdogNotificationQueue
            ) { [weak watchdog] _ in
                watchdog?.suspendMonitoring(for: .screenLock, at: Date())
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: mainThreadWatchdogNotificationQueue
            ) { [weak watchdog] _ in
                watchdog?.resumeMonitoring(for: .screenLock, at: Date())
            },
        ]

        reconcileInitialWatchdogSuspensionState(watchdog)
    }

    private func reconcileInitialWatchdogSuspensionState(_ watchdog: PickyMainThreadWatchdog) {
        let now = Date()
        if Self.currentSessionIsScreenLocked() {
            watchdog.suspendMonitoring(for: .screenLock, at: now)
        }
        if Self.mainDisplayIsAsleep() {
            watchdog.suspendMonitoring(for: .displaySleep, at: now)
        }
    }

    private static func currentSessionIsScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber { return locked.boolValue }
        return false
    }

    private static func mainDisplayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private func stopMainThreadWatchdog() {
        for observer in mainThreadWatchdogWorkspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        mainThreadWatchdogWorkspaceObservers.removeAll()

        let distributedCenter = DistributedNotificationCenter.default()
        for observer in mainThreadWatchdogDistributedObservers {
            distributedCenter.removeObserver(observer)
        }
        mainThreadWatchdogDistributedObservers.removeAll()

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

    // MARK: - Global app font scale (View > Font Size menu, ⌘+ / ⌘- / ⌘0)
    //
    // Wired via the responder chain by `PickyAppMenuInstaller`. Any key panel
    // without its own local zoom shortcut routes the keyEquivalent up to NSApp,
    // which walks the chain to the delegate. Report / terminal panels claim
    // the same shortcuts from inside their SwiftUI view tree, so detached
    // panels keep their per-panel zoom and only the global menu falls through.

    @objc func pickyIncreaseAppFontScale(_ sender: Any?) {
        fontScaleStore.increase()
    }

    @objc func pickyDecreaseAppFontScale(_ sender: Any?) {
        fontScaleStore.decrease()
    }

    @objc func pickyResetAppFontScale(_ sender: Any?) {
        fontScaleStore.reset()
    }
}

extension CompanionAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(PickyNotificationPresentationPolicy.foregroundOptions)
    }

    /// Completion, failure, and input-request notification identifiers start
    /// with the source session ID, followed by a colon and a deduplication key.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let notificationResponse = appActivationRouter.recordNotificationResponse(
                identifier: response.notification.request.identifier
              ) else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            self?.appActivationRouter.handleNotificationResponse(notificationResponse) { [weak self] sessionID in
                self?.hudOverlayManager.focusSession(id: sessionID)
            }
            completionHandler()
        }
    }
}
