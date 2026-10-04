import AppKit
import Combine
import Foundation

@MainActor
final class PickySessionListViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionCard] = [] {
        didSet { scheduleDockStateSync() }
    }
    @Published private(set) var archivedSessions: [SessionCard] = []
    @Published private(set) var selectedSessionID: String?
    let voiceFollowUpHoverState = PickyVoiceFollowUpHoverState()
    var hoveredVoiceFollowUpSessionID: String? { voiceFollowUpHoverState.sessionID }
    @Published private(set) var activeVoiceFollowUpSessionID: String?
    @Published private(set) var screenContextTargetSessionID: String? {
        didSet { scheduleDockStateSync() }
    }
    /// `true` when the armed Pickle should keep receiving Picky inputs until
    /// the user clicks it again or arms another. `false` is the legacy one-shot
    /// behavior. Always `false` when `screenContextTargetSessionID` is nil.
    @Published private(set) var screenContextTargetSticky: Bool = false {
        didSet { scheduleDockStateSync() }
    }
    @Published private(set) var screenContextArmCollapseToken: UUID = UUID() {
        didSet { publishDockStateImmediately() }
    }
    @Published var lastError: String?
    @Published private(set) var lastOpenedArtifactPath: String?
    /// Published mirror of `PickySessionSlashCommandController` cache state.
    /// Every controller mutation path must call `syncSlashCommands()`.
    @Published private(set) var slashCommandsBySessionID: [String: [PickySlashCommand]] = [:]
    /// Per-session git-diff projections. Populated only while the Changes utility tab is visible.
    /// Stores preserve mounted utility-panel identity without publishing through
    /// the global façade for another session's diff response.
    var sessionDiffStoresBySessionID: [String: PickySessionDiffStore] = [:]
    var visibleSessionDiffSessionIDs = Set<String>()
    /// High-frequency autocomplete responses bypass `objectWillChange` so typing does not
    /// invalidate every conversation bubble observing this view model. The active composer
    /// filters this stream by session, generation, request id, draft revision, and cursor.
    let autocompleteEvents = PassthroughSubject<PickyAutocompleteClientEvent, Never>()
    /// Session-projection transitions for surfaces outside the session stack.
    let sessionProjectionTransitions = PickySessionProjectionTransitionPublisher()
    /// Per-session TODO expansion choice survives Conversation Card teardown while the HUD is closed.
    @Published private(set) var todoProgressExpandedBySessionID: [String: Bool] = [:]
    /// Per-invocation expansion survives conversation-card teardown while the HUD is closed.
    @Published private(set) var subagentInvocationExpandedBySessionID: [String: [String: Bool]] = [:]
    @Published private(set) var pendingDoneFlashSessionIDs: Set<String> = [] {
        didSet { publishDockStateImmediately() }
    }
    /// The one local shell terminal add-on attachment that may render its AppKit
    /// terminal view. Multiple HUD panels can exist, but a single NSView cannot be
    /// attached to multiple parents at the same time.
    let shellTerminalAttachmentStore = PickyTerminalAttachmentStore()
    var activeShellTerminalAttachmentSessionID: String? { shellTerminalAttachmentStore.activeSessionID }
    /// Long-lived local shell terminals keyed by Pickle session ID. Hiding the
    /// add-on intentionally keeps the shell process alive so reopening resumes the
    /// same terminal session.
    private var shellTerminalSessionsBySessionID: [String: PickyShellTerminalSession] = [:]
    private let shellTerminalSessionFactory: (SessionCard) -> PickyShellTerminalSession
    /// Sessions that finished or are waiting for input but have not been opened
    /// by the user yet. Lives on the view model (single source of truth) so all
    /// dock instances render the indicator in sync.
    @Published var unreadSessionIDs: Set<String> = [] {
        didSet { scheduleDockStateSync() }
    }
    @Published private(set) var recentPickleCwds: [String] {
        didSet { scheduleDockStateSync() }
    }
    @Published private(set) var pinnedPickleCwds: [String] {
        didSet { scheduleDockStateSync() }
    }
    @Published var isLoadingInitialSessionSnapshot = true {
        didSet { scheduleDockStateSync() }
    }
    @Published private(set) var openSessionRequest: PickyHUDOpenSessionRequest? {
        didSet { publishDockStateImmediately() }
    }
    private(set) var lastActualConversationCardOpenedID: String?

    var selectedSession: SessionCard? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    /// Archive-membership boundary, stable across the future storage cutover.
    var archivedSessionIDsPublisher: AnyPublisher<Set<String>, Never> { $archivedSessions.map { Set($0.map(\.id)) }.removeDuplicates().eraseToAnyPublisher() }
    func isSessionArchived(_ sessionID: String) -> Bool { archivedSessions.contains { $0.id == sessionID } }

    let client: any PickyAgentClient
    /// Invoked after the composer installs the delayed-action plugin so the app
    /// can trigger the same daemon reload the plugin manager does.
    var onScheduledSendPluginInstalled: (() -> Void)?
    /// App-owned defaults only apply when a new Pickle runtime is created.
    /// They intentionally do not mutate a resumed session's Pi configuration.
    let pickleRuntimeDefaultsStore: PickySettingsStore
    let pickleRuntimeDefaultsPersistence: PickySettingsPersistenceCoordinator
    private let notificationCenter: PickyNotificationDelivering
    private let notificationPreferencesProvider: PickyNotificationPreferencesProviding
    private let selectionStore: PickySessionSelectionStoring
    let archiveStore: PickySessionArchiveStoring
    // Dock layout facade owns reset-to-default order through this store.
    let manualOrderStore: PickySessionManualOrderStoring
    /// User-controlled dock order. Stored in the same direction as `sessions`
    /// (newest at index 0 = visually-end slot after `sessions.reversed()`). IDs
    /// not yet present here are auto-prepended when first observed, so brand
    /// new Pickles always land on the visually-end slot, regardless of any
    /// past drag the user did to existing sessions.
    var manualOrder: [String] = []
    /// Persisted dock layout (groups + ordered top-level entries). Source of
    /// truth for the dock rail's visual ordering once any group has been
    /// created. Empty layout falls back to the legacy `manualOrder` flow.
    internal(set) var dockLayout: PickyDockLayout = .empty {
        didSet { publishDockStateImmediately() }
    }
    /// Stable, dock-only observation boundary. Its identity never changes.
    let dockState = PickyHUDDockState()
    /// Last router-validated membership removal published to HUD-local owners.
    /// The event revision is monotonic so each surface can consume it once.
    private var authoritativeDockRemovalEvent: PickyHUDDockRemovalEvent?
    private var nextAuthoritativeDockRemovalRevision: UInt64 = 0
    private var isDockStateSyncScheduled = false
    private var dockStateMutationDepth = 0
    private var needsImmediateDockStateSyncAfterMutation = false
    internal let dockLayoutController: PickySessionDockLayoutController
    /// True while a pre-groups `manualOrder` still owes its one-time replay.
    /// V2 bootstrap admits sessions one snapshot at a time, so the layout stops
    /// being empty long before membership is authoritative; this flag carries
    /// the launch-time observation to the one moment the replay can run
    /// correctly. It mirrors `manualOrderStore.isLegacyManualOrderReplayPending`
    /// so a launch that never reaches primary completion does not drop it.
    internal var needsLegacyManualOrderMigration = false
    enum PendingDockGroupAssignment {
        case groupName(String)
        case groupID(String)
    }
    var pendingDockGroupAssignments: [String: PendingDockGroupAssignment] = [:]
    internal var dockLayoutReconciliationSuspensionDepth = 0
    let composerDraftController: PickySessionComposerDraftController
    private var slashCommandController: PickySessionSlashCommandController!
    private let recentPickleFolderStore: PickyRecentPickleFolderStoring
    private let artifactPathValidator: PickyArtifactPathValidator
    private let clipboardWriter: PickyClipboardWriting
    private let reportPresenter: PickyReportPresenting
    private let toolHistoryPresenter: PickyToolHistoryPresenting
    private let generatedReportDirectory: URL
    private let manualPickleChildSpawner: (any PickyManualPickleChildSpawning)?
    private let childSessionReleaser: (any PickyChildSessionReleasing)?
    let projectionOwnerReconnector: (any PickyProjectionOwnerReconnecting)?
    private let archiveCommitDelayNanoseconds: UInt64
    let archiveCoordinator = PickySessionArchiveCoordinator()
    var pendingArchiveIntentBySessionID: [String: Bool] { archiveCoordinator.intents }
    var releasedArchivedChildSessionIDs = Set<String>()
    private let manualPickleSessionIdFactory: () -> String
    private var terminalSessionCommandChains: [String: Task<Void, Never>] = [:]
    private var terminalSessionCommandChainIDs: [String: UUID] = [:]
    private var eventTask: Task<Void, Never>?
    /// Safety watchdog that flips `isLoadingInitialSessionSnapshot` to `false`
    /// even when the daemon never delivers a `sessionProjectionSnapshot` (e.g. WebSocket
    /// upgrade silently fails, agentd crashes mid-handshake, or a protocol
    /// mismatch swallows the response). Without this fallback the dock UI used
    /// to stay stuck on the initial loading state, which manifested as an
    /// invisible HUD on environments where the handshake stalled (notably new
    /// macOS releases). The grace period matches the daemon's typical first
    /// snapshot turnaround with comfortable slack.
    private var initialSnapshotWatchdogTask: Task<Void, Never>?
    private let initialSnapshotWatchdogNanoseconds: UInt64 = 4_000_000_000
    /// Wallclock instant of the most recent `.connected` event. Used purely
    /// for diagnostics so we can report how long the daemon kept us waiting
    /// for the first `sessionProjectionSnapshot` after the WebSocket handshake
    /// completed — or, if the watchdog fires, exactly how long we waited
    /// before giving up.
    private var lastConnectedAt: Date?
    private var voiceFollowUpTargetCancellable: AnyCancellable?
    private var screenContextTargetCancellable: AnyCancellable?
    private var composerDraftAppendCancellable: AnyCancellable?
    private var deliveredNotificationKeys = Set<String>()
    private let slashCommandSuggestionSlowLogThreshold: TimeInterval = 0.02
    private var hasExplicitSelection = false
    let sessionProjectionStorage: any PickySessionProjectionStorage
    /// App composition uses this narrow notification to wake bridge requests
    /// waiting for a registry-backed v2 session. It carries no projection data,
    /// so storage remains the sole state owner.
    var onSessionProjectionStorageChanged: (() -> Void)?
    private var sessionProjectionStorageCancellable: AnyCancellable?
    /// Readable from `PickySessionViewModel+SessionProjectionV2.swift`, which
    /// owns the projection v2 wiring. Writes stay in this file.
    private(set) var sessionProjectionRecoveryCoordinator: PickySessionRecoveryCoordinator?
    init(
        client: any PickyAgentClient,
        notificationCenter: PickyNotificationDelivering = PickySystemNotificationCenter(),
        notificationPreferencesProvider: PickyNotificationPreferencesProviding = PickyNotificationPreferencesStore(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        archiveStore: PickySessionArchiveStoring = PickyUserDefaultsSessionArchiveStore.shared,
        manualOrderStore: PickySessionManualOrderStoring = PickyUserDefaultsSessionManualOrderStore.shared,
        composerDraftStore: PickyComposerDraftStoring = PickyUserDefaultsComposerDraftStore.shared,
        composerAttachmentDraftStore: PickyComposerAttachmentDraftStoring = PickyUserDefaultsComposerAttachmentDraftStore.shared,
        recentPickleFolderStore: PickyRecentPickleFolderStoring = PickyNoopRecentPickleFolderStore(),
        dockLayoutStore: PickyDockLayoutStoring = PickyNoopDockLayoutStore(),
        artifactPathValidator: PickyArtifactPathValidator = PickyArtifactPathValidator(appSupportRoot: PickyAppSupport.defaultRoot()),
        clipboardWriter: PickyClipboardWriting = PickyPasteboardClipboardWriter(),
        reportPresenter: PickyReportPresenting? = nil,
        toolHistoryPresenter: PickyToolHistoryPresenting? = nil,
        generatedReportDirectory: URL = PickyAppSupport.defaultRoot().appendingPathComponent("GeneratedReports", isDirectory: true),
        manualPickleChildSpawner: (any PickyManualPickleChildSpawning)? = nil,
        childSessionReleaser: (any PickyChildSessionReleasing)? = nil,
        projectionOwnerReconnector: (any PickyProjectionOwnerReconnecting)? = nil,
        archiveCommitDelayNanoseconds: UInt64 = PickyHUDArchiveUndoToastPolicy.durationNanoseconds,
        manualPickleSessionIdFactory: @escaping () -> String = { "session-\(UUID().uuidString)" },
        shellTerminalSessionFactory: ((SessionCard) -> PickyShellTerminalSession)? = nil,
        sessionProjectionStorage: (any PickySessionProjectionStorage)? = nil,
        pickleRuntimeDefaultsStore: PickySettingsStore = PickySettingsStore(),
        pickleRuntimeDefaultsPersistence: PickySettingsPersistenceCoordinator? = nil
    ) {
        self.client = client
        self.pickleRuntimeDefaultsStore = pickleRuntimeDefaultsStore
        self.pickleRuntimeDefaultsPersistence = pickleRuntimeDefaultsPersistence ?? .shared(for: pickleRuntimeDefaultsStore)
        // A ViewModel owns exactly one registry backend for its lifetime.
        self.sessionProjectionStorage = sessionProjectionStorage ?? PickyRegistrySessionProjectionStorage()
        self.notificationCenter = notificationCenter
        self.notificationPreferencesProvider = notificationPreferencesProvider
        self.selectionStore = selectionStore
        self.archiveStore = archiveStore
        self.manualOrderStore = manualOrderStore
        self.manualOrder = manualOrderStore.manualOrder
        self.composerDraftController = PickySessionComposerDraftController(
            draftStore: composerDraftStore,
            attachmentStore: composerAttachmentDraftStore
        )
        self.recentPickleFolderStore = recentPickleFolderStore
        self.recentPickleCwds = recentPickleFolderStore.recentPickleCwds
        self.pinnedPickleCwds = recentPickleFolderStore.pinnedPickleCwds
        let dockLayoutController = PickySessionDockLayoutController(store: dockLayoutStore) { error in
            pickySessionLog("dockLayout save failed: \(error)")
        }
        self.dockLayoutController = dockLayoutController
        self.dockLayout = dockLayoutController.layout
        self.needsLegacyManualOrderMigration = manualOrderStore.armLegacyManualOrderReplayIfNeeded(
            dockLayoutIsEmpty: dockLayoutController.layout.entries.isEmpty
        )
        self.artifactPathValidator = artifactPathValidator
        self.clipboardWriter = clipboardWriter
        self.reportPresenter = reportPresenter ?? PickyReportViewerPresenter.shared
        self.toolHistoryPresenter = toolHistoryPresenter ?? PickyToolHistoryPresenter.shared
        self.generatedReportDirectory = generatedReportDirectory
        self.manualPickleChildSpawner = manualPickleChildSpawner
        self.childSessionReleaser = childSessionReleaser
        self.projectionOwnerReconnector = projectionOwnerReconnector
        self.archiveCommitDelayNanoseconds = archiveCommitDelayNanoseconds
        self.manualPickleSessionIdFactory = manualPickleSessionIdFactory
        self.shellTerminalSessionFactory = shellTerminalSessionFactory ?? { session in
            PickyShellTerminalSession(
                sessionID: session.id,
                title: session.title,
                cwd: session.cwd,
                fontScalePersister: PickyTerminalFontScalePersister.defaultSettings()
            )
        }
        self.selectedSessionID = selectionStore.selectedSessionID
        self.voiceFollowUpHoverState.sessionID = selectionStore.hoveredVoiceFollowUpSessionID
        self.screenContextTargetSessionID = selectionStore.screenContextTargetSessionID
        self.screenContextTargetSticky = selectionStore.screenContextTargetSticky
        self.hasExplicitSelection = self.selectedSessionID != nil
        self.slashCommandController = PickySessionSlashCommandController(
            sendCommand: { [client] in try await client.send($0) },
            onSendFailure: { [weak self] in self?.lastError = $0 }
        )
        self.voiceFollowUpTargetCancellable = NotificationCenter.default.publisher(for: .pickyVoiceFollowUpTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.setActiveVoiceFollowUpSessionID(notification.userInfo?[PickyVoiceFollowUpTargetNotification.sessionIDKey] as? String)
            }
        self.screenContextTargetCancellable = NotificationCenter.default.publisher(for: .pickyScreenContextTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let sessionID = notification.userInfo?[PickyScreenContextTargetNotification.sessionIDKey] as? String
                let sticky = (notification.userInfo?[PickyScreenContextTargetNotification.stickyKey] as? Bool) ?? false
                self?.screenContextTargetSessionID = sessionID
                self?.screenContextTargetSticky = sessionID == nil ? false : sticky
            }
        self.composerDraftAppendCancellable = NotificationCenter.default.publisher(for: .pickyComposerDraftAppendRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let sessionID = notification.userInfo?[PickyComposerDraftAppendNotification.sessionIDKey] as? String,
                      let text = notification.userInfo?[PickyComposerDraftAppendNotification.textKey] as? String else { return }
                self?.appendComposerDraftText(text, sessionID: sessionID)
            }
        self.sessionProjectionStorageCancellable = self.sessionProjectionStorage.changes.sink { [weak self] snapshot in
            self?.relaySessionProjectionStorageChange(snapshot)
            self?.onSessionProjectionStorageChanged?()
        }
        self.sessionProjectionRecoveryCoordinator = Self.makeSessionProjectionRecoveryCoordinator(for: self)
        dockLayoutController.onExplicitLayoutMutation = { [weak self] in self?.settleLegacyManualOrderReplay() }
        syncDockStateNow()
    }

    /// Resolves the current active card at the point an imperative HUD action
    /// runs. Dock rendering intentionally uses `PickyHUDDockSession` instead.
    func activeSessionCard(sessionID: String) -> SessionCard? {
        sessions.first { $0.id == sessionID }
    }


    /// Test seam for the coalesced dock snapshot. Production mutations always
    /// settle on the next main-queue turn, so an upsert never exposes its
    /// remove/append intermediate state to dock observers.
    func flushDockStateForTesting() {
        guard isDockStateSyncScheduled else { return }
        isDockStateSyncScheduled = false
        syncDockStateNow()
    }

    private func scheduleDockStateSync() {
        guard !isDockStateSyncScheduled else { return }
        isDockStateSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isDockStateSyncScheduled else { return }
            self.isDockStateSyncScheduled = false
            self.syncDockStateNow()
        }
    }

    /// Ordered UI signals and direct manipulation must reach every HUD before
    /// the caller clears its transient interaction state. Publishing here also
    /// settles any coalesced session mutation that happened earlier in the same
    /// logical event, while the queued block becomes a no-op.
    private func publishDockStateImmediately() {
        if dockStateMutationDepth > 0 {
            needsImmediateDockStateSyncAfterMutation = true
            return
        }
        isDockStateSyncScheduled = false
        syncDockStateNow()
    }

    internal func beginDockStateMutation() {
        dockStateMutationDepth += 1
    }

    internal func endDockStateMutation() {
        precondition(dockStateMutationDepth > 0)
        dockStateMutationDepth -= 1
        guard dockStateMutationDepth == 0, needsImmediateDockStateSyncAfterMutation else { return }
        needsImmediateDockStateSyncAfterMutation = false
        publishDockStateImmediately()
    }

    private func syncDockStateNow() {
        dockState.publish(PickyHUDDockSnapshot(
            activeSessions: sessions.map { sessionStore(sessionID: $0.id).map(PickyHUDDockSession.init(store:)) ?? PickyHUDDockSession(session: $0) },
            dockLayout: dockLayout,
            screenContextTargetSessionID: screenContextTargetSessionID,
            screenContextTargetSticky: screenContextTargetSticky,
            screenContextArmCollapseToken: screenContextArmCollapseToken,
            pendingDoneFlashSessionIDs: pendingDoneFlashSessionIDs,
            unreadSessionIDs: unreadSessionIDs,
            pinnedPickleCwds: pinnedPickleCwds,
            recentPickleCwds: recentPickleCwds,
            isLoadingInitialSessionSnapshot: isLoadingInitialSessionSnapshot,
            openSessionRequest: openSessionRequest,
            authoritativeRemovalEvent: authoritativeDockRemovalEvent,
            groupMemberIDsByRecency: PickyDockGroupRecencyPolicy.groups(in: dockLayout, sessions: sessions)
        ))
    }

    func start() {
        pickySessionLog("viewModel start")
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                self.apply(event)
            }
        }
        Task { await client.connect() }
    }

    func stop() {
        pickySessionLog("viewModel stop")
        eventTask?.cancel()
        eventTask = nil
        initialSnapshotWatchdogTask?.cancel()
        initialSnapshotWatchdogTask = nil
        terminalSessionCommandChains.values.forEach { $0.cancel() }
        terminalSessionCommandChains.removeAll()
        terminalSessionCommandChainIDs.removeAll()
        client.disconnect()
    }

    private func armInitialSnapshotWatchdog() {
        initialSnapshotWatchdogTask?.cancel()
        let timeoutNanoseconds = initialSnapshotWatchdogNanoseconds
        initialSnapshotWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            guard self.isLoadingInitialSessionSnapshot else { return }
            let waitedMs = self.lastConnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            pickySessionLog("initial snapshot watchdog fired — unblocking dock UI without sessionProjectionSnapshot waitedSinceConnectedMs=\(waitedMs)")
            self.isLoadingInitialSessionSnapshot = false
            self.initialSnapshotWatchdogTask = nil
        }
    }

    func disarmInitialSnapshotWatchdog() {
        initialSnapshotWatchdogTask?.cancel()
        initialSnapshotWatchdogTask = nil
    }

    func select(sessionID: String?) {
        pickySessionLog("select requested session=\(sessionID ?? "default")")
        hasExplicitSelection = sessionID != nil
        if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
            selectedSessionID = sessionID
            selectionStore.selectedSessionID = sessionID
        } else {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
    }

    func requestOpenSession(sessionID: String, targetDisplayID: CGDirectDisplayID? = nil) {
        pickySessionLog("open session requested session=\(sessionID) display=\(targetDisplayID.map(String.init) ?? "all")")
        if sessions.contains(where: { $0.id == sessionID }) {
            select(sessionID: sessionID)
        }
        openSessionRequest = PickyHUDOpenSessionRequest(
            sessionID: sessionID,
            targetDisplayID: targetDisplayID
        )
    }

    func requestCloseSession(sessionID: String, targetDisplayID: CGDirectDisplayID? = nil) {
        pickySessionLog("close session requested session=\(sessionID) display=\(targetDisplayID.map(String.init) ?? "all")")
        openSessionRequest = PickyHUDOpenSessionRequest(
            sessionID: sessionID,
            targetDisplayID: targetDisplayID,
            action: .close
        )
    }

    func submit(transcript: String, context: PickyContextPacket) async throws {
        pickySessionLog("submit context=\(context.id) source=\(context.source) transcriptChars=\(transcript.count)")
        _ = try await client.submit(PickyAgentSubmission(transcript: transcript, context: context))
    }

    @discardableResult
    func createEmptyPickleSession(cwd: String) async throws -> String {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = PickyContextPacket(
            id: "context-\(UUID().uuidString)",
            source: "system",
            capturedAt: Date(),
            transcript: nil,
            selectedText: nil,
            cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: ["manualPickle=true"]
        )
        pickySessionLog("create empty Pickle session context=\(context.id) cwd=\(context.cwd ?? "none")")
        do {
            let command = PickyCommandEnvelope(
                type: .createEmptyPickleSession,
                context: context,
                notifyMainOnCompletion: notificationPreferencesProvider.notificationPreferences.notifyMainOnCompletionForNewPickles,
                notifyMacOSOnCompletion: notificationPreferencesProvider.notificationPreferences.notifyMacOSOnCompletionForNewPickles
            )
            guard let manualPickleChildSpawner else {
                lastError = PickySessionListViewModelError.pickleRuntimeUnavailable.localizedDescription
                throw PickySessionListViewModelError.pickleRuntimeUnavailable
            }
            let childCwd = context.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let sessionID = manualPickleSessionIdFactory()
            let childClient = try await manualPickleChildSpawner.spawnManualPickleChildClient(
                sessionId: sessionID,
                cwd: childCwd
            )
            try await childClient.send(command)
            lastError = nil
            if let cwd = context.cwd {
                recordRecentPickleFolder(cwd)
            }
            return sessionID
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func removeRecentPickleFolder(_ cwd: String) {
        recentPickleFolderStore.remove(cwd: cwd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let recent):
                self.recentPickleCwds = recent
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func pinPickleFolder(_ cwd: String) {
        recentPickleFolderStore.pin(cwd: cwd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updated):
                self.pinnedPickleCwds = updated.pinned
                self.recentPickleCwds = updated.recent
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func unpinPickleFolder(_ cwd: String) {
        recentPickleFolderStore.unpin(cwd: cwd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updated):
                self.pinnedPickleCwds = updated.pinned
                self.recentPickleCwds = updated.recent
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func reorderPinnedPickleFolders(_ cwds: [String]) {
        recentPickleFolderStore.reorderPinned(cwds: cwds) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pinned):
                self.pinnedPickleCwds = pinned
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    private func recordRecentPickleFolder(_ cwd: String) {
        recentPickleFolderStore.record(cwd: cwd) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let recent):
                self.recentPickleCwds = recent
            case .failure(let error):
                // A Pickle already started successfully; keep the session creation result and
                // surface only the persistence failure for diagnostics.
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Forks the Pickle session at `sessionID` into a brand-new sibling that resumes from a
    /// snapshot of its Pi transcript. Daemon-side rejects when the source has no Pi session file
    /// or is not yet attached to a runtime; we surface that error via `lastError` like the rest
    /// of the lifecycle commands here.
    func duplicate(sessionID: String) async throws {
        pickySessionLog("duplicate session=\(sessionID)")
        do {
            try await client.send(PickyCommandEnvelope(type: .duplicatePickleSession, sessionId: sessionID))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Request Pi context compaction (`/compact`) for a session. Routes via
    /// `steer` for terminal-but-recoverable states and `followUp` otherwise,
    /// mirroring the dock icon's compact action. No-op while the session is
    /// busy or already compacting.
    func requestCompaction(sessionID: String) async {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.canRequestDockCompaction else { return }
        switch session.status {
        case .failed, .cancelled:
            try? await steer(text: "/compact", sessionID: sessionID)
        case .completed, .blocked:
            try? await followUp(text: "/compact", sessionID: sessionID)
        case .queued, .running, .waiting_for_input:
            break
        }
    }

    func beginHoveredVoiceFollowUp(sessionID: String) {
        // Dedup before mutating @Published — SwiftUI onHover can fire repeated
        // hovering=true callbacks (e.g. on scroll or layout updates), and any
        // assignment to a @Published republishes regardless of equality. The
        // resulting objectWillChange cascade re-evaluates every HUD view that
        // observes the viewModel (conversation card/list/header/composer/etc.),
        // which in turn re-parses markdown for each bubble's isTruncated check
        // and re-measures TextKit. Guarding with a same-value early return
        // keeps the hover-driven cascade to one event per real state change.
        guard hoveredVoiceFollowUpSessionID != sessionID else { return }
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        voiceFollowUpHoverState.sessionID = sessionID
        selectionStore.hoveredVoiceFollowUpSessionID = sessionID
        pickySessionLog("voice follow-up hovered session=\(sessionID)")
    }

    func endHoveredVoiceFollowUp(sessionID: String) {
        guard hoveredVoiceFollowUpSessionID == sessionID else { return }
        voiceFollowUpHoverState.sessionID = nil
        selectionStore.hoveredVoiceFollowUpSessionID = nil
        pickySessionLog("voice follow-up hover cleared session=\(sessionID)")
    }

    func toggleScreenContextTarget(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTarget(sessionID: sessionID)
            return
        }
        armScreenContextTarget(sessionID: sessionID, sticky: false)
    }

    /// Toggles the explicit, persistent conversation target exposed by the
    /// Dock context menu. A non-sticky target is promoted; tapping an already
    /// sticky target clears it.
    func toggleStickyScreenContextTarget(sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if screenContextTargetSessionID == sessionID, screenContextTargetSticky {
            clearScreenContextTarget(sessionID: sessionID)
            return
        }
        armScreenContextTarget(sessionID: sessionID, sticky: true)
    }

    /// Promotes (or replaces) the armed Pickle. `sticky=true` keeps the Pickle
    /// armed across follow-up/steer dispatches; `sticky=false` matches the
    /// existing one-shot tap behavior. Used by the header long-press gesture.
    func armScreenContextTarget(sessionID: String, sticky: Bool) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sticky
        let label = sessions.first(where: { $0.id == sessionID })?.title
        if let labelStore = selectionStore as? PickyScreenContextTargetLabelStoring {
            labelStore.setScreenContextTarget(sessionID: sessionID, sticky: sticky, label: label)
        } else {
            selectionStore.setScreenContextTarget(sessionID: sessionID, sticky: sticky)
        }
        select(sessionID: sessionID)
        screenContextArmCollapseToken = UUID()
        pickySessionLog("screen context target armed session=\(sessionID) sticky=\(sticky)")
    }

    func clearScreenContextTarget(sessionID: String? = nil) {
        guard sessionID == nil || screenContextTargetSessionID == sessionID else { return }
        clearScreenContextTargetState()
    }

    private func clearScreenContextTargetState() {
        guard screenContextTargetSessionID != nil || selectionStore.screenContextTargetSessionID != nil else { return }
        let cleared = screenContextTargetSessionID ?? selectionStore.screenContextTargetSessionID ?? "<nil>"
        screenContextTargetSessionID = nil
        screenContextTargetSticky = false
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        pickySessionLog("screen context cleared session=\(cleared)")
    }

    func ensureSlashCommandsLoaded(sessionID: String) {
        slashCommandController.ensureLoaded(sessionID: sessionID)
    }

    func slashCommandSuggestions(for text: String, cursorLocation: Int? = nil, sessionID: String, limit: Int = PickySlashCommandAutocompletePolicy.maxSuggestions) -> [PickySlashCommand] {
        let commands = slashCommandsIncludingRewindTreeCommand(slashCommandController.commands(for: sessionID), sessionID: sessionID)
        let queryLength = PickySlashCommandAutocompletePolicy.query(in: text, cursorLocation: cursorLocation)?.count ?? 0
        let startedAt = Date()
        let suggestions = PickySlashCommandAutocompletePolicy.suggestions(for: text, cursorLocation: cursorLocation, commands: commands, limit: limit)
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= slashCommandSuggestionSlowLogThreshold {
            pickySessionLog("slash command suggestions slow session=\(sessionID) queryChars=\(queryLength) commands=\(commands.count) suggestions=\(suggestions.count) durationMs=\(Self.milliseconds(elapsed))")
        }
        return suggestions
    }

    func hasLoadedSlashCommands(sessionID: String) -> Bool {
        slashCommandController.hasLoaded(sessionID: sessionID)
    }

    @discardableResult
    func requestAutocompleteCapabilities(sessionID: String) -> String {
        sendAutocompleteCommand(PickyCommandEnvelope(type: .getAutocompleteCapabilities, sessionId: sessionID))
    }

    @discardableResult
    func queryAutocomplete(
        sessionID: String,
        generation: Int,
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        draftRevision: Int,
        draftFingerprint: String,
        force: Bool = false
    ) -> String {
        sendAutocompleteCommand(PickyCommandEnvelope(
            type: .autocompleteQuery,
            sessionId: sessionID,
            generation: generation,
            lines: lines,
            cursorLine: cursorLine,
            cursorCol: cursorCol,
            force: force,
            draftRevision: draftRevision,
            draftFingerprint: draftFingerprint
        ))
    }

    @discardableResult
    func applyAutocomplete(
        sessionID: String,
        generation: Int,
        lines: [String],
        cursorLine: Int,
        cursorCol: Int,
        draftRevision: Int,
        draftFingerprint: String,
        item: PickyAutocompleteItem,
        prefix: String
    ) -> String {
        sendAutocompleteCommand(PickyCommandEnvelope(
            type: .autocompleteApply,
            sessionId: sessionID,
            generation: generation,
            lines: lines,
            cursorLine: cursorLine,
            cursorCol: cursorCol,
            draftRevision: draftRevision,
            draftFingerprint: draftFingerprint,
            item: item,
            prefix: prefix
        ))
    }

    private func sendAutocompleteCommand(_ command: PickyCommandEnvelope) -> String {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.send(command)
            } catch {
                lastError = error.localizedDescription
            }
        }
        return command.id
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }

    func composerDraftRequest(for sessionID: String) -> PickyComposerDraftRequest? {
        composerDraftController.request(for: sessionID)
    }

    /// The controller owns draft-request state and publishes changes directly,
    /// so the ViewModel no longer mirrors a dictionary for composer reads.
    var composerDraftRequestsBySessionID: [String: PickyComposerDraftRequest] {
        composerDraftController.requestsBySessionID
    }

    func composerDraftRequestPublisher(for sessionID: String) -> AnyPublisher<PickyComposerDraftRequest?, Never> {
        composerDraftController.requestPublisher(for: sessionID)
    }

    func consumeComposerDraftRequest(sessionID: String, requestID: String) {
        composerDraftController.consumeRequest(sessionID: sessionID, requestID: requestID)
    }

    func persistedComposerDraft(for sessionID: String) -> String {
        composerDraftController.persistedDraft(for: sessionID)
    }

    func updateComposerDraft(_ draft: String, sessionID: String) {
        composerDraftController.updateDraft(draft, sessionID: sessionID)
    }

    /// Returns previously-persisted composer attachment paths for the session,
    /// filtered to those that still exist on disk. Dropped images live in the
    /// temp directory and may be reaped by the system between launches; the
    /// caller should treat missing paths as silently dropped.
    func persistedComposerAttachmentPaths(for sessionID: String) -> [String] {
        composerDraftController.persistedAttachmentPaths(for: sessionID)
    }

    func updateComposerAttachmentPaths(_ paths: [String], sessionID: String) {
        composerDraftController.updateAttachmentPaths(paths, sessionID: sessionID)
    }

    func clearComposerDraft(sessionID: String) {
        composerDraftController.clearDraft(sessionID: sessionID)
    }

    func appendComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.appendText(text, sessionID: sessionID) else { return }
        select(sessionID: sessionID)
    }

    func replaceComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.replaceText(text, sessionID: sessionID) else { return }
        select(sessionID: sessionID)
    }

    @discardableResult
    func restoreQueuedInputsToComposerDraft(sessionID: String, kind: PickyQueueClearKind = .all) -> Bool {
        guard let session = card(sessionID: sessionID) else { return false }
        let visibleQueue = visibleQueue(for: session)
        guard PickyQueuedInputRestoreAvailability.resolve(visibleQueue: visibleQueue, kind: kind) == .available,
              let queuedText = PickyQueuedInputDraftPolicy.queuedInputText(
                  visibleQueue: visibleQueue,
                  kind: kind
              )
        else { return false }
        appendComposerDraftText(queuedText, sessionID: sessionID)
        return true
    }

    func clearQueueRestoringQueuedInputs(sessionID: String, kind: PickyQueueClearKind) async throws {
        // The daemon's clearQueue discards every kind, so the guard must cover the whole queue.
        if let session = card(sessionID: sessionID),
           case .blockedByScreenContext(let attachedImagesCount) = PickyQueuedInputRestoreAvailability.resolve(
               visibleQueue: visibleQueue(for: session),
               kind: .all
           ) {
            throw PickyQueuedInputRestoreError.blockedByScreenContext(attachedImagesCount: attachedImagesCount)
        }
        restoreQueuedInputsToComposerDraft(sessionID: sessionID, kind: kind)
        try await clearQueue(sessionID: sessionID, kind: kind)
    }

    func abortRestoringQueuedInputs(sessionID: String) async throws {
        if let session = card(sessionID: sessionID),
           let queuedText = PickyQueuedInputDraftPolicy.queuedInputText(
               visibleQueue: visibleQueue(for: session),
               kind: .all
           ) {
            // Abort is explicitly destructive: retain only text because queued screen context cannot be reconstructed.
            appendComposerDraftText(queuedText, sessionID: sessionID)
            try? await clearQueue(sessionID: sessionID, kind: .all)
        }
        try await abort(sessionID: sessionID)
    }

    private func visibleQueue(for session: SessionCard) -> PickyVisibleQueue {
        PickyVisibleQueue(
            queuedSteers: session.queuedSteers,
            queuedFollowUps: session.queuedFollowUps,
            committedUserMessages: PickyComposerMessageContext(messages: session.messages).submittedUserMessages
        )
    }

    private func syncSlashCommands() {
        let commandsBySessionID = slashCommandController.commandsBySessionID
        guard slashCommandsBySessionID != commandsBySessionID else { return }
        slashCommandsBySessionID = commandsBySessionID
    }

    func copyMessageText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardWriter.copy(text)
        lastError = nil
    }

    func isTodoProgressExpanded(sessionID: String, isComplete: Bool) -> Bool {
        PickyTodoProgressExpansionPolicy.isExpanded(
            savedValue: todoProgressExpandedBySessionID[sessionID],
            isComplete: isComplete
        )
    }

    func setTodoProgressExpanded(_ isExpanded: Bool, sessionID: String) {
        guard todoProgressExpandedBySessionID[sessionID] != isExpanded else { return }
        todoProgressExpandedBySessionID[sessionID] = isExpanded
    }

    func isSubagentInvocationExpanded(invocationID: String, sessionID: String, isComplete: Bool) -> Bool {
        PickySubagentInvocationExpansionPolicy.isExpanded(
            savedValue: subagentInvocationExpandedBySessionID[sessionID]?[invocationID],
            isComplete: isComplete
        )
    }

    func setSubagentInvocationExpanded(_ isExpanded: Bool, invocationID: String, sessionID: String) {
        guard subagentInvocationExpandedBySessionID[sessionID]?[invocationID] != isExpanded else { return }
        var values = subagentInvocationExpandedBySessionID[sessionID] ?? [:]
        values[invocationID] = isExpanded
        subagentInvocationExpandedBySessionID[sessionID] = values
    }

    func markDoneFlashConsumed(sessionID: String) {
        pendingDoneFlashSessionIDs.remove(sessionID)
    }

    /// Clears unread state without implying that the user opened the actual
    /// conversation card. Passive panel focus and utility surfaces use this.
    func markSessionRead(sessionID: String) {
        guard unreadSessionIDs.contains(sessionID) else { return }
        unreadSessionIDs.remove(sessionID)
    }

    /// Records only a confirmed held conversation card open. This drives the
    /// no-unread fallback for the global Focus Pickle shortcut.
    func markConversationCardOpened(sessionID: String) {
        lastActualConversationCardOpenedID = sessionID
        markSessionRead(sessionID: sessionID)
    }

    func followUp(text: String, sessionID: String? = nil) async throws {
        try await followUp(text: text, sessionID: sessionID, requireAcknowledgement: false)
    }

    func followUp(text: String, sessionID: String?, requireAcknowledgement: Bool) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = L10n.t("hud.session.error.emptyMessage")
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = L10n.t("hud.session.error.noSelection")
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = L10n.t("hud.session.error.archived")
                throw PickySessionListViewModelError.archivedSession
            }
            lastError = L10n.t("hud.session.error.noSelection")
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("follow-up session=\(target) textChars=\(trimmed.count)")
        do {
            let command = PickyCommandEnvelope(type: .followUp, sessionId: target, text: trimmed)
            if requireAcknowledgement {
                if let rejection = try await client.sendAwaitingError(command, timeout: 5, requireAcknowledgement: true) {
                    throw PickyCommandRejection(event: rejection)
                }
            } else {
                try await client.send(command)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        let now = Date()
        mutateSession(sessionID: target) { card in
            card.lastRequestText = trimmed
            card.lastRequestAt = now
            card.updatedAt = now
        }
        select(sessionID: target)
    }

    func steer(text: String, sessionID: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = L10n.t("hud.session.error.emptyMessage")
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = L10n.t("hud.session.error.noSelection")
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = L10n.t("hud.session.error.archived")
                throw PickySessionListViewModelError.archivedSession
            }
            lastError = L10n.t("hud.session.error.noSelection")
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("steer session=\(target) textChars=\(trimmed.count)")
        do {
            try await client.send(PickyCommandEnvelope(type: .steer, sessionId: target, text: trimmed))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        let now = Date()
        mutateSession(sessionID: target) { card in
            card.lastRequestText = trimmed
            card.lastRequestAt = now
            card.updatedAt = now
        }
        select(sessionID: target)
    }

    /// Continues a request that Pi accepted before a runtime/provider failure.
    /// Sending the original request again could repeat completed tools or other
    /// side effects, so Retry adds only a short localized continuation turn.
    func continueAfterRuntimeFailure(sessionID: String) async throws {
        let prompt = L10n.t("hud.error.retry.continuePrompt")
        pickySessionLog("continue-after-runtime-failure session=\(sessionID) textChars=\(prompt.count)")
        try await steer(text: prompt, sessionID: sessionID)
    }

    /// Re-sends the card's most recent user-request text via `steer` so the
    /// Pi SDK queues it behind the run that won the `activeRun` race. The
    /// failed card stays terminal until the supervisor revives it to
    /// `running` from inside `steer`, matching how the composer's `.steer`
    /// path handles a `cancelled`/`failed` session. Callers must already
    /// have confirmed the failure came from the recoverable race (see
    /// `PickyErrorBubbleView.isRecoverableRuntimeRace`); we still validate
    /// the target session is known and the text is non-empty here.
    func retryAfterRuntimeRace(sessionID: String) async throws {
        guard let card = sessions.first(where: { $0.id == sessionID }) ?? archivedSessions.first(where: { $0.id == sessionID }) else {
            lastError = L10n.t("hud.session.error.noRetrySession")
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard let text = card.lastRequestText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            lastError = L10n.t("hud.session.error.noRetryText")
            throw PickySessionListViewModelError.emptyFollowUp
        }
        pickySessionLog("retry-after-race session=\(sessionID) textChars=\(text.count)")
        try await steer(text: text, sessionID: sessionID)
    }

    func cancelAsyncTask(owner: PickyAsyncTaskOwner, taskID: String) async throws {
        try await PickySessionAsyncTaskActions.cancel(owner: owner, taskID: taskID,
            client: client, store: sessionStore(sessionID: owner.sessionId))
    }

    func loadAsyncTaskDetail(owner: PickyAsyncTaskOwner, taskID: String) async throws -> PickyAsyncTaskDetail {
        try await PickySessionAsyncTaskActions.detail(owner: owner, taskID: taskID,
            client: client, store: sessionStore(sessionID: owner.sessionId))
    }

    func abort(sessionID: String) async throws {
        pickySessionLog("abort session=\(sessionID)")
        if (sessions + archivedSessions).first(where: { $0.id == sessionID })?.hasAsyncTracking == true {
            guard let control = client.asyncTaskControl else { throw PickyAsyncControlError.unsupported }
            _ = try await control.stopAsyncWork(sessionID: sessionID)
            return
        }
        try await client.send(PickyCommandEnvelope(type: .abort, sessionId: sessionID))
        mutateSession(sessionID: sessionID) { card in
            if !card.status.isTerminal { card.status = .cancelled }
            card.updatedAt = Date()
        }
    }

    func clearQueue(sessionID: String, kind: PickyQueueClearKind) async throws {
        pickySessionLog("clear queue session=\(sessionID) kind=\(kind.rawValue)")
        try await client.send(PickyCommandEnvelope(type: .clearQueue, sessionId: sessionID, kind: kind))
    }

    // MARK: - Per-item queue and scheduled-message commands

    /// These wait for the daemon's positive acknowledgement, not just for the
    /// absence of a rejection: each one edits a message the user can still see,
    /// so "no answer yet" must not clear the composer or the row as if it had
    /// landed. The window covers attaching a detached runtime and waiting for the
    /// delayed-action store to settle, which is seconds rather than milliseconds.
    private func sendQueueCommand(_ command: PickyCommandEnvelope) async throws {
        if let rejection = try await client.sendAwaitingError(
            command,
            timeout: Self.queueCommandAcknowledgementTimeout,
            requireAcknowledgement: true
        ) {
            throw PickyCommandRejection(event: rejection)
        }
    }

    private static let queueCommandAcknowledgementTimeout: TimeInterval = 15

    func removeQueuedInput(sessionID: String, itemID: String) async throws {
        pickySessionLog("remove queued input session=\(sessionID) item=\(itemID)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .removeQueuedInput, sessionId: sessionID, itemId: itemID))
    }

    func editQueuedFollowUp(sessionID: String, itemID: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PickySessionListViewModelError.emptyFollowUp }
        pickySessionLog("edit queued follow-up session=\(sessionID) item=\(itemID) textChars=\(trimmed.count)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .editQueuedFollowUp, sessionId: sessionID, text: trimmed, itemId: itemID))
    }

    func sendQueuedFollowUpNow(sessionID: String, itemID: String) async throws {
        pickySessionLog("send queued follow-up now session=\(sessionID) item=\(itemID)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .sendQueuedFollowUpNow, sessionId: sessionID, itemId: itemID))
    }

    func scheduleMessage(sessionID: String, text: String, delayMs: Int) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PickySessionListViewModelError.emptyFollowUp }
        guard delayMs > 0 else { throw PickySessionListViewModelError.emptyFollowUp }
        pickySessionLog("schedule message session=\(sessionID) delayMs=\(delayMs) textChars=\(trimmed.count)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .scheduleMessage, sessionId: sessionID, text: trimmed, delayMs: delayMs))
    }

    func cancelScheduledMessage(sessionID: String, scheduledID: String) async throws {
        pickySessionLog("cancel scheduled message session=\(sessionID) scheduled=\(scheduledID)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .cancelScheduledMessage, sessionId: sessionID, scheduledId: scheduledID))
    }

    func editScheduledMessage(sessionID: String, scheduledID: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PickySessionListViewModelError.emptyFollowUp }
        pickySessionLog("edit scheduled message session=\(sessionID) scheduled=\(scheduledID) textChars=\(trimmed.count)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .editScheduledMessage, sessionId: sessionID, text: trimmed, scheduledId: scheduledID))
    }

    func sendScheduledMessageNow(sessionID: String, scheduledID: String) async throws {
        pickySessionLog("send scheduled message now session=\(sessionID) scheduled=\(scheduledID)")
        try await sendQueueCommand(PickyCommandEnvelope(type: .sendScheduledMessageNow, sessionId: sessionID, scheduledId: scheduledID))
    }

    func isScheduledSendPluginInstalled() -> Bool {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }
        return PickyCuratedPluginInstaller.status(source: PickyCuratedPlugin.delayedAction.source).isInstalled
    }

    func installScheduledSendPlugin() async throws {
        let source = PickyCuratedPlugin.delayedAction.source
        pickySessionLog("install scheduled-send plugin source=\(source)")
        switch await PickyCuratedPluginInstaller.install(source: source, client: client) {
        case .success:
            // Mirrors the Hub/Companion install path so the daemon reloads the
            // new extension without the user visiting the plugin manager.
            onScheduledSendPluginInstalled?()
        case .failure(let error):
            throw error
        }
    }

    func answerExtensionUi(sessionID: String, requestID: String, value: JSONValue) async throws {
        pickySessionLog("answer extension-ui session=\(sessionID) request=\(requestID)")
        let command = PickyCommandEnvelope(type: .answerExtensionUi, sessionId: sessionID, requestId: requestID, value: value)
        if let rejection = try await client.sendAwaitingError(command, timeout: 5, requireAcknowledgement: true) {
            throw PickyCommandRejection(event: rejection)
        }
        // Preserve the accepted answer in the HUD request row without closing the
        // question. The daemon may already have opened a different question.
        if let pending = (sessions + archivedSessions).first(where: { $0.id == sessionID })?.pendingExtensionUiRequest,
           pending.id == requestID, let summary = PickyAskUserQuestionFormState.summarizeAnswer(request: pending, value: value) {
            mutateSession(sessionID: sessionID) { card in
                guard card.pendingExtensionUiRequest?.id == requestID else { return }
                card.lastRequestText = summary
                card.lastRequestAt = Date()
            }
        }
        // Only the daemon's authoritative session projection may close it.
    }

    func cancelExtensionUi(sessionID: String, requestID: String) async throws {
        try await answerExtensionUi(sessionID: sessionID, requestID: requestID, value: .object(["cancelled": .bool(true)]))
    }

    func openToolHistory(sessionID: String, scope: PickyToolHistoryScope = .session) {
        pickySessionLog("open tool history session=\(sessionID) scope=\(scope)")
        let title = sessionTitle(for: sessionID)
        let source = PickyToolHistorySource(sessionID: sessionID, storage: sessionProjectionStorage, client: client)
        toolHistoryPresenter.openHistory(
            sessionID: sessionID, title: title, scope: scope,
            snapshotProvider: { source.snapshot }, updates: source.updates, detailLoader: source.load
        )
    }

    func openToolHistoryForCurrentTurn(sessionID: String) {
        let scope = currentTurnScope(for: sessionID)
        openToolHistory(sessionID: sessionID, scope: scope)
    }

    func openToolHistoryForAgentActivity(sessionID: String, messageID: String) {
        let scope = agentActivityScope(for: sessionID, messageID: messageID)
        openToolHistory(sessionID: sessionID, scope: scope)
    }

    func card(sessionID: String) -> SessionCard? {
        (sessions + archivedSessions).first { $0.id == sessionID }
    }

    private static func cwdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == (rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func sessionTitle(for sessionID: String) -> String {
        card(sessionID: sessionID)?.title ?? "Session"
    }

    private func currentTurnScope(for sessionID: String) -> PickyToolHistoryScope {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }) else { return .session }
        let lastUserText = session.messages.last(where: { $0.kind == .userText })
        return .dateRange(start: lastUserText?.createdAt, end: nil)
    }

    private func agentActivityScope(for sessionID: String, messageID: String) -> PickyToolHistoryScope {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let activityIndex = session.messages.firstIndex(where: { $0.id == messageID && $0.kind == .agentActivity })
        else { return .session }
        let activity = session.messages[activityIndex]
        let priorMessages = session.messages.prefix(activityIndex)
        let priorUserText = priorMessages.last(where: { $0.kind == .userText })
        return .dateRange(start: priorUserText?.createdAt, end: activity.createdAt)
    }

    /// Opens the newest LLM response in the markdown report viewer. This backs
    /// the HUD's ⌘R shortcut so users can expand the latest reply without aiming
    /// for the hover-only bubble corner button.
    func openLatestAgentResponseReport(sessionID: String) async throws {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let messageID = session.latestAgentResponseReportMessageID else {
            lastError = L10n.t("hud.session.error.latestReportUnavailable")
            throw PickySessionListViewModelError.missingReport
        }
        try await openReport(sessionID: sessionID, messageID: messageID)
    }

    /// Opens a specific message's text content in the markdown report viewer.
    /// Used by the per-bubble hover-icon affordance so the user can expand any
    /// user request or agent reply (not just the latest one) into the full viewer.
    func openReport(sessionID: String, messageID: String) async throws {
        pickySessionLog("open report session=\(sessionID) message=\(messageID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let message = session.messages.first(where: { $0.id == messageID }),
              let markdown = message.openAsReportMarkdown else {
            lastError = L10n.t("hud.session.error.messageReportUnavailable")
            throw PickySessionListViewModelError.missingReport
        }
        let titleSuffix: String
        let fileNamePrefix: String
        switch message.kind {
        case .userText:
            titleSuffix = "Request"
            fileNamePrefix = "request"
        case .agentText:
            titleSuffix = "Response"
            fileNamePrefix = "response"
        case .system:
            if message.notifyType != nil {
                titleSuffix = "Pi Extension Notice"
                fileNamePrefix = "notify"
            } else {
                titleSuffix = "System message"
                fileNamePrefix = "system"
            }
        default:
            titleSuffix = "Message"
            fileNamePrefix = "message"
        }
        do {
            try openGeneratedReport(
                windowKey: "\(sessionID):message:\(messageID)",
                title: "\(session.title) \u{2014} \(titleSuffix)",
                fileName: "\(fileNamePrefix)-\(sanitizedReportFileComponent(messageID)).md",
                markdown: markdown
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Opens a completed subagent's full response in the shared markdown report viewer.
    func openSubagentRunResponse(sessionID: String, invocationID: String, runId: Int) async throws {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let run = session.subagentRuns.first(where: { $0.runId == runId && $0.invocationId == invocationID }),
              let markdown = run.resultText ?? run.resultPreview,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = L10n.t("hud.session.error.subagentReportUnavailable")
            throw PickySessionListViewModelError.missingReport
        }
        do {
            let runIdentity = sanitizedReportFileComponent(invocationID)
            try openGeneratedReport(
                windowKey: "\(sessionID):subagent-run:\(invocationID):\(runId)",
                title: "\(run.agent) #\(runId) \u{2014} Response",
                fileName: "subagent-run-\(runIdentity)-\(runId).md",
                markdown: markdown
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func openGeneratedReport(windowKey: String, title: String, fileName: String, markdown: String) throws {
        try FileManager.default.createDirectory(at: generatedReportDirectory, withIntermediateDirectories: true)
        let fileURL = generatedReportDirectory.appendingPathComponent(fileName, isDirectory: false)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        lastOpenedArtifactPath = fileURL.path
        try reportPresenter.openReport(sessionID: windowKey, title: title, fileURL: fileURL, markdown: markdown)
    }

    private func sanitizedReportFileComponent(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sanitized.isEmpty ? "report" : String(sanitized.prefix(96))
    }

    func copyTerminalResumeCommand(sessionID: String) {
        pickySessionLog("copy terminal resume command session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        let command = PickyPiTerminalCommand.makeCliResumeCommand(sessionFilePath: piSessionFilePath, cwd: session.cwd)
        clipboardWriter.copy(command)
        lastError = nil
    }

    private func enqueueTerminalSessionCommand(sessionID: String, operation: @escaping @MainActor () async -> Void) {
        let previous = terminalSessionCommandChains[sessionID]
        let chainID = UUID()
        terminalSessionCommandChainIDs[sessionID] = chainID
        let task = Task { [weak self, previous] in
            await previous?.value
            if !Task.isCancelled {
                await operation()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.terminalSessionCommandChainIDs[sessionID] == chainID else { return }
                self.terminalSessionCommandChains[sessionID] = nil
                self.terminalSessionCommandChainIDs[sessionID] = nil
            }
        }
        terminalSessionCommandChains[sessionID] = task
    }

    func shellTerminalSession(for session: SessionCard) -> PickyShellTerminalSession {
        if let existing = shellTerminalSessionsBySessionID[session.id] {
            return existing
        }
        let shellSession = shellTerminalSessionFactory(session)
        shellTerminalSessionsBySessionID[session.id] = shellSession
        return shellSession
    }

    func isShellTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool {
        shellTerminalAttachmentStore.isActive(sessionID: sessionID, attachmentID: attachmentID)
    }

    func activateShellTerminalAttachment(sessionID: String, attachmentID: String) {
        shellTerminalAttachmentStore.activate(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
    }

    func releaseShellTerminalAttachment(sessionID: String, attachmentID: String) {
        shellTerminalAttachmentStore.release(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
    }

    private func removeVisibleShellTerminalAttachments(sessionID: String) {
        shellTerminalAttachmentStore.removeSession(
            sessionID: sessionID,
            eligibleSessionIDs: shellTerminalEligibleSessionIDs
        )
    }

    private var shellTerminalEligibleSessionIDs: Set<String> {
        Set((sessions + archivedSessions).map(\.id))
    }

    private func closeShellTerminalSession(sessionID: String) {
        removeVisibleShellTerminalAttachments(sessionID: sessionID)
        shellTerminalSessionsBySessionID.removeValue(forKey: sessionID)?.close()
    }

    /// Manual escape hatch for a session the user has been driving from an external
    /// `pi --session` shell: the daemon has no JSONL watcher, so this reconciles the
    /// HUD card against the on-disk transcript on demand.
    func syncTerminalSessionOnce(sessionID: String) {
        enqueueTerminalSessionCommand(sessionID: sessionID) { [weak self] in
            await self?.sendTerminalSessionSync(sessionID: sessionID)
        }
    }

    private func sendTerminalSessionSync(sessionID: String) async {
        guard (sessions + archivedSessions).contains(where: { $0.id == sessionID }) else { return }
        let command = PickyCommandEnvelope(
            type: .syncTerminalSession,
            sessionId: sessionID
        )
        do {
            try await client.send(command)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archive(sessionID: String) {
        guard (sessions + archivedSessions).first(where: { $0.id == sessionID })?.hasAsyncTracking == true else {
            commitArchive(sessionID: sessionID, sendIntent: true)
            return
        }
        Task { @MainActor in
            do { try await self.archiveSessionConfirmed(sessionID: sessionID, mode: nil) }
            catch { self.archiveCoordinator.record(error, sessionID: sessionID) }
        }
    }

    func archiveSessionConfirmed(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?) async throws {
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }) else { throw PickyDockGroupManagementError.sessionNotFound(sessionID) }
        try await archiveCoordinator.confirmArchive(sessionID: sessionID, tracked: session.hasAsyncTracking,
            mode: mode, client: client)
        commitArchive(sessionID: sessionID, sendIntent: false)
    }

    private func commitArchive(sessionID: String, sendIntent: Bool) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("archive session=\(sessionID)")
        closeShellTerminalSession(sessionID: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        archiveCoordinator.setMembership(sessionID, archived: true, store: archiveStore)

        if sendIntent { sendArchiveIntent(sessionID: sessionID, archived: true) }

        scheduleArchiveCommit(sessionID: sessionID)

        guard moveSessionProjectionMembership(id: sessionID, archived: true) != nil else { return }
        // Keep manualOrder synced so the persisted array does not retain ids
        // outside both pools. Unarchive re-prepends the id to manualOrder, so
        // we intentionally drop the slot rather than try to remember it.
        applyManualOrder()
        if selectedSessionID == sessionID {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
        }
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTarget(sessionID: sessionID)
        }
    }

    private func sendArchiveIntent(sessionID: String, archived: Bool) {
        archiveCoordinator.sendLegacyIntent(sessionID: sessionID, archived: archived, client: client) { [weak self] in
            self?.handleArchiveIntentFailure(commandID: $0)
        }
    }

    /// Removes all correlation state once the daemon confirms or rejects the
    /// current archive intent. A stale command ID can then never undo a newer
    /// user action for the same session.
    func clearPendingArchiveIntent(sessionID: String) {
        archiveCoordinator.clearIntent(sessionID: sessionID)
    }

    /// Reverses only the current optimistic action when its command was
    /// rejected. This makes the generic command-correlated `error` frame a
    /// liveness signal rather than leaving local archive intent permanent.
    func handleArchiveIntentFailure(commandID: String?) {
        guard let pending = archiveCoordinator.failedIntent(commandID: commandID) else { return }

        beginDockStateMutation()
        defer { endDockStateMutation() }
        clearPendingArchiveIntent(sessionID: pending.sessionID)
        if pending.archived {
            archiveCoordinator.setMembership(pending.sessionID, archived: false, store: archiveStore)
            archiveCoordinator.cancelCommit(sessionID: pending.sessionID)
            releasedArchivedChildSessionIDs.remove(pending.sessionID)
            _ = moveSessionProjectionMembership(id: pending.sessionID, archived: false)
        } else {
            archiveCoordinator.setMembership(pending.sessionID, archived: true, store: archiveStore)
            _ = moveSessionProjectionMembership(id: pending.sessionID, archived: true)
            scheduleArchiveCommit(sessionID: pending.sessionID)
        }
        applyManualOrder()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    /// Tear down the child daemon once the archive undo window expires. Called from
    /// `archive(sessionID:)` and cancelled by `unarchive(sessionID:)` so users who tap Undo
    /// keep their child agentd alive.
    private func scheduleArchiveCommit(sessionID: String) {
        archiveCoordinator.scheduleCommit(sessionID: sessionID, delay: archiveCommitDelayNanoseconds) { [weak self] in
            guard let self, let session = self.archivedSessions.first(where: { $0.id == sessionID }) else { return }
            self.releaseArchivedTerminalChildIfCommitted(session)
        }
    }

    func releaseArchivedTerminalChildIfCommitted(_ session: SessionCard) {
        archiveCoordinator.releaseIfCommitted(session: session, client: client,
            childSessionReleaser: childSessionReleaser,
            alreadyReleased: releasedArchivedChildSessionIDs.contains(session.id)) { [weak self] in
                self?.releasedArchivedChildSessionIDs.insert(session.id)
            }
    }

    func unarchive(sessionID: String) {
        let tracked = (sessions + archivedSessions).first(where: { $0.id == sessionID })?.hasAsyncTracking == true
        archiveCoordinator.invalidateIntent(sessionID: sessionID, client: client, tracked: tracked)
        guard tracked else {
            commitUnarchive(sessionID: sessionID, sendIntent: true)
            return
        }
        Task { @MainActor in
            do {
                try await self.archiveCoordinator.restore(sessionID: sessionID, client: self.client)
                self.commitUnarchive(sessionID: sessionID, sendIntent: false)
            } catch { self.archiveCoordinator.record(error, sessionID: sessionID) }
        }
    }

    private func commitUnarchive(sessionID: String, sendIntent: Bool) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("unarchive session=\(sessionID)")
        archiveCoordinator.cancelCommit(sessionID: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        archiveCoordinator.setMembership(sessionID, archived: false, store: archiveStore)

        if sendIntent { sendArchiveIntent(sessionID: sessionID, archived: false) }

        guard moveSessionProjectionMembership(id: sessionID, archived: false) != nil else { return }
        // Only touch manualOrder if the user has already opted into manual
        // ordering by dragging at least once; otherwise let the historical
        // createdAt sort drive placement.
        if !manualOrder.isEmpty {
            manualOrder = PickyDockManualOrderPolicy.promotedToNewest(manualOrder: manualOrder, sessionID: sessionID)
            manualOrderStore.manualOrder = manualOrder
        }
        applyManualOrder()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    func stopArchivedAsyncWork(sessionID: String) async throws {
        try await PickySessionAsyncTaskActions.stopArchived(sessionID: sessionID,
            archived: archivedSessions.first { $0.id == sessionID }, client: client)
    }

    /// Explicit deletion requests every archived session; the daemon settles connected work.
    func deleteAllArchivedSessions() { deleteAllArchivedSessions(onFailure: { _ in }) }

    func deleteAllArchivedSessions(onFailure: @escaping @MainActor (Error) -> Void) {
        let ids = (sessionProjectionStorage as? PickyRegistrySessionProjectionStorage)?.registry.archivedSessionIDs
            ?? archivedSessions.map(\.id)
        archiveCoordinator.requestDeleteAll(sessionIDs: ids) { [weak self] sessionID in self?.deleteArchivedSession(sessionID: sessionID, onFailure: onFailure) }
    }

    /// Keep local state until the authoritative daemon acknowledgement arrives.
    func deleteArchivedSession(sessionID: String) { deleteArchivedSession(sessionID: sessionID, onFailure: { _ in }) }

    func deleteArchivedSession(sessionID: String, onFailure: @escaping @MainActor (Error) -> Void) {
        archiveCoordinator.requestDelete(sessionID: sessionID, client: client,
            canDelete: { [weak self] in
                guard let self else { return false }
                if let storage = self.sessionProjectionStorage as? PickyRegistrySessionProjectionStorage { return storage.registry.archivedSessionIDs.contains(sessionID) }
                return self.archivedSessions.contains(where: { $0.id == sessionID })
            },
            onConfirmed: { [weak self] in self?.finalizeDeletedArchivedSession(sessionID: sessionID) },
            onFailure: { [weak self] error in
                self?.lastError = L10n.t("hud.archivedList.deleteFailed", error.localizedDescription)
                pickySessionLog("delete archived session failed session=\(sessionID) error=\(error)")
                onFailure(error)
            })
    }

    /// Local half of permanent deletion, called after the Settings command is sent
    /// or after the CLI bridge receives an authoritative child-daemon ack.
    func finalizeDeletedArchivedSession(sessionID: String) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("finalize deleted archived session=\(sessionID)")
        archiveCoordinator.cancelCommit(sessionID: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)

        archiveCoordinator.setMembership(sessionID, archived: false, store: archiveStore)
        childSessionReleaser?.releaseChild(sessionId: sessionID)

        // Purge every per-session tracking map without rebuilding v2 membership
        // from cards while other archived records are still loading.
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            storage.removeSessions(ids: [sessionID])
        } else {
            removeSession(id: sessionID)
        }
        sessionProjectionTransitions.forgetSessions([sessionID])
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
        todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
        slashCommandController.clear(sessionID: sessionID)
        syncSlashCommands()
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTargetState()
        }
        if hoveredVoiceFollowUpSessionID == sessionID {
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
        if activeVoiceFollowUpSessionID == sessionID {
            activeVoiceFollowUpSessionID = nil
        }
        if selectedSessionID == sessionID {
            hasExplicitSelection = false
            selectedSessionID = defaultSelectionID()
            selectionStore.selectedSessionID = nil
        }
        applyManualOrder()
    }

    /// Applies a router-validated v2 membership cutover. This is intentionally
    /// not fed through the source-free client event reducer: the router owns
    /// source, generation, epoch, and bootstrap-ID validation.
    func applySessionProjectionBootstrapCompletion(removedSessionIDs: Set<String>, isPrimary: Bool) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        for sessionID in removedSessionIDs {
            clearAuthoritativelyRemovedSessionState(sessionID: sessionID)
        }
        if !removedSessionIDs.isEmpty {
            nextAuthoritativeDockRemovalRevision &+= 1
            authoritativeDockRemovalEvent = PickyHUDDockRemovalEvent(
                revision: nextAuthoritativeDockRemovalRevision,
                sessionIDs: removedSessionIDs
            )
        }
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            storage.removeSessions(ids: removedSessionIDs)
        } else {
            for sessionID in removedSessionIDs { sessionProjectionStorage.removeSession(id: sessionID) }
        }

        let knownSessionIDs = Set(sessions.map(\.id)).union(archivedSessions.map(\.id))
        pruneSlashCommandCache(knownSessionIDs: knownSessionIDs)
        applyManualOrder()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
        if isPrimary {
            // Membership is authoritative only here, so this is the first and
            // only point where the pre-group drag order can be replayed onto
            // a layout that holds every session the daemon knows.
            migrateLegacyManualOrderIfNeeded()
            disarmInitialSnapshotWatchdog()
            isLoadingInitialSessionSnapshot = false
        }
    }

    private func clearAuthoritativelyRemovedSessionState(sessionID: String) {
        sessionProjectionTransitions.forgetSessions([sessionID])
        archiveCoordinator.cancelCommit(sessionID: sessionID)
        clearPendingArchiveIntent(sessionID: sessionID)
        sessionProjectionRecoveryCoordinator?.remove(sessionID: sessionID)
        archiveStore.archivedSessionIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs.remove(sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys = deliveredNotificationKeys.filter { !$0.hasPrefix("\(sessionID):") }
        todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
        slashCommandController.clear(sessionID: sessionID)
        composerDraftController.clearDraft(sessionID: sessionID)
        pendingDockGroupAssignments.removeValue(forKey: sessionID)
        sessionDiffStoresBySessionID.removeValue(forKey: sessionID)
        visibleSessionDiffSessionIDs.remove(sessionID)
        terminalSessionCommandChains.removeValue(forKey: sessionID)?.cancel()
        terminalSessionCommandChainIDs.removeValue(forKey: sessionID)
        closeShellTerminalSession(sessionID: sessionID)
        if openSessionRequest?.sessionID == sessionID { openSessionRequest = nil }
    }

    func searchSessions(query: String) -> [SessionCard] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = sessions + archivedSessions
        guard !normalized.isEmpty else { return all }
        return all.filter { session in
            let haystack = [
                session.title,
                session.cwd,
                session.status.rawValue,
                session.lastSummary,
                session.linkBadgeArtifacts.compactMap { $0.url?.absoluteString }.joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(normalized)
        }
    }

    /// Synchronous event handler. Production has exactly one caller — the
    /// `for await event in client.events` loop in `start()`. Do NOT call this
    /// from other production code; new transport entries should go through
    /// `client.events`, not bypass it.
    ///
    /// Tests use this entry point directly so reducer assertions stay
    /// deterministic and free of `Task.sleep`-based settling. The `.connected`
    /// and `.disconnected` cases mutate loader state, so this is not a pure
    /// reducer; treat it as the canonical event-application seam, called once
    /// per delivered event.
    func apply(_ event: PickyClientEvent) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        switch event {
        case .connected:
            lastConnectedAt = Date()
            pickySessionLog("client connected sessions=\(sessions.count) archived=\(archivedSessions.count)")
            if sessions.isEmpty && archivedSessions.isEmpty {
                isLoadingInitialSessionSnapshot = true
                armInitialSnapshotWatchdog()
            }
            lastError = nil
            autocompleteEvents.send(.reconnected)
        case .disconnected:
            pickySessionLog("client disconnected")
            lastError = L10n.t("hud.session.error.disconnected")
        case .recoverableError(let message):
            pickySessionLog("client recoverable error=\(message)")
            lastError = message
        case .protocolEvent(let envelope):
            apply(envelope.event)
        case .sessionProjectionBootstrapCompletion(let removedSessionIDs, let isPrimary):
            applySessionProjectionBootstrapCompletion(
                removedSessionIDs: removedSessionIDs,
                isPrimary: isPrimary
            )
        }
    }

    /// Inner reducer for fully-decoded protocol events. Stays private — reducer
    /// tests always go through the `PickyClientEvent.protocolEvent(...)` envelope
    /// (matching the production path), so this entry point has no external
    /// callers and exposing it would only widen the API surface.
    private func apply(_ event: PickyEvent) {
        switch event {
        case .sessionProjectionSnapshot(let snapshot):
            sessionProjectionRecoveryCoordinator?.receive(snapshot: snapshot)
        case .sessionProjectionTransaction(let transaction):
            sessionProjectionRecoveryCoordinator?.receive(transaction: transaction)
        // Completion is consumed at the router boundary with source metadata.
        case .sessionProjectionBootstrapComplete:
            break
        case .extensionUiRequest(let request):
            applyExtensionUiRequest(request)
        case .sessionResourcesReloaded(let sessionId):
            PickyPerf.event("vm_event_session_resources_reloaded")
            pickySessionLog("session resources reloaded session=\(sessionId)")
            invalidateSlashCommandCache(sessionID: sessionId, refreshIfPreviouslyRequested: true)
            autocompleteEvents.send(.resourcesReloaded(sessionID: sessionId))
        case .pluginsReloaded:
            slashCommandController.invalidateAll(refreshIfPreviouslyRequested: true)
            syncSlashCommands()
        case .slashCommandsSnapshot(let sessionId, let requestId, let commands):
            applySlashCommandsSnapshot(sessionID: sessionId, requestID: requestId, commands: commands)
        case .autocompleteCapabilitiesSnapshot(let snapshot):
            autocompleteEvents.send(.capabilities(snapshot))
        case .autocompleteSuggestionsSnapshot(let snapshot):
            autocompleteEvents.send(.suggestions(snapshot))
        case .autocompleteCompletionApplied(let completion):
            autocompleteEvents.send(.completion(completion))
        case .rewindTargetsSnapshot, .sessionRuntimeOptionsSnapshot, .toolHistoryDetailResult: break
        case .sessionDiffResult(let result):
            applySessionDiffResult(result)
        case .sessionRewound(let sessionId, let editorText, _): applySessionRewound(sessionID: sessionId, editorText: editorText)
        case .error(let error):
            pickySessionLog("protocol error code=\(error.code) command=\(error.commandId ?? "none")")
            lastError = error.message
            handleSessionProjectionRecoveryFailure(commandID: error.commandId)
            handleArchiveIntentFailure(commandID: error.commandId)
        case .sessionReplyWritingUpdated(let sessionId, let writing):
            applySessionReplyWriting(sessionID: sessionId, writing: writing)
        case .sessionToolCallPreparingUpdated(let sessionId, let preparing):
            applySessionToolCallPreparing(sessionID: sessionId, preparing: preparing)
        case .terminalSessionSyncOutcome(let outcome):
            applyTerminalSessionSyncOutcome(outcome)
        case .externalEntryAccepted(let accepted):
            if let sessionID = accepted.sessionId, let groupName = accepted.group {
                assignSessionToDockGroup(sessionID: sessionID, groupName: groupName)
            }
        case .asyncControlContext, .asyncTaskCommandResult,
             .quickReply, .mainTurnSettled, .mainNarrationChunk,
             .mainVisualNarrationSegmentPrepared, .mainVisualNarrationSegmentSentence, .mainVisualNarrationSegmentCommitted,
             .mainMessagesSnapshot, .mainMessageAppended, .mainActivityUpdated, .mainExtensionUiRequested, .mainExtensionUiCancelled,
             .mainAgentSessionInfoUpdated, .mainAgentModelsSnapshot,
             .piOAuthStatus, .piOAuthUrlRequested, .piOAuthPromptRequested, .piAuthenticationReloaded,
             .pointerOverlayRequested, .annotationOverlayRequested, .pickleHandoffRequested, .pickleBridgeRequested, .externalEntryRequested,
             .dockGroupsRequested, .pushToTalkControlRequested, .pickySettingsRequested, .hello,
             .hubStatisticsResult, .packageUpdatesAvailable, .packageConflicts, .packageOperationProgress, .packageOperationCompleted, .mcpServerList, .mcpServerOperationCompleted, .ack, .unknown:
            break
        }
    }

    // MARK: - Protocol event handlers
    private func applySessionDiffResult(_ result: PickySessionDiffResult) {
        guard let store = sessionDiffStoresBySessionID[result.sessionId] else { return }
        let next = PickySessionDiffState.reducing(current: store.state, result: result)
        store.replace(next)
    }

    private func applyExtensionUiRequest(_ request: PickyExtensionUiRequest) {
        PickyPerf.event("vm_event_extension_ui_request")
        pickySessionLog("extension-ui request session=\(request.sessionId) request=\(request.id) method=\(request.method)")
        if handleFireAndForgetExtensionUiRequest(request) { return }
        mutateSession(sessionID: request.sessionId) { card in
            card.status = .waiting_for_input
            card.pendingExtensionUiRequest = request
            card.lastSummary = request.prompt ?? request.title ?? "Waiting for input"
            card.updatedAt = request.createdAt
        }
    }

    private func applySlashCommandsSnapshot(sessionID sessionId: String, requestID requestId: String?, commands: [PickySlashCommand]) {
        PickyPerf.event("vm_event_slash_commands_snapshot")
        slashCommandController.applySnapshot(sessionID: sessionId, requestID: requestId, commands: commands)
        syncSlashCommands()
    }

    private func applyTerminalSessionSyncOutcome(_ outcome: PickyTerminalSessionSyncOutcome) {
        // Suppress the banner for the "nothing new" outcome — the user already
        // saw the terminal close cleanly, so a banner that just says "nothing
        // imported" is noise. The baseline-missing and imported-N-messages
        // outcomes still surface so the user notices a silent skip or a
        // successful import.
        guard PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) else { return }
        updateTerminalSessionSyncOutcome(sessionID: outcome.sessionId, outcome: outcome)
    }

    /// The daemon reports reply streaming as a live signal with no projection
    /// owner, so it lands in the same locally-owned presentation slot as the
    /// terminal-sync banner rather than in the persisted projection.
    private func applySessionReplyWriting(sessionID: String, writing: Bool) {
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            _ = storage.updateProjectionPresentation(sessionID: sessionID) {
                $0.replaceReplyWriting(writing)
            }
        } else {
            mutateSession(sessionID: sessionID) { $0.isWritingReply = writing }
        }
    }

    /// Same live, locally-owned slot as `applySessionReplyWriting`.
    private func applySessionToolCallPreparing(sessionID: String, preparing: Bool) {
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            _ = storage.updateProjectionPresentation(sessionID: sessionID) {
                $0.replaceToolCallPreparing(preparing)
            }
        } else {
            mutateSession(sessionID: sessionID) { $0.isPreparingToolCall = preparing }
        }
    }

    func dismissTerminalSyncOutcome(sessionID: String) {
        updateTerminalSessionSyncOutcome(sessionID: sessionID, outcome: nil)
    }

    private func updateTerminalSessionSyncOutcome(
        sessionID: String,
        outcome: PickyTerminalSessionSyncOutcome?
    ) {
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            _ = storage.updateProjectionPresentation(sessionID: sessionID) {
                $0.replaceTerminalSyncOutcome(outcome)
            }
        } else {
            mutateSession(sessionID: sessionID) { $0.lastTerminalSyncOutcome = outcome }
        }
    }

    private func handleFireAndForgetExtensionUiRequest(_ request: PickyExtensionUiRequest) -> Bool {
        switch request.method {
        case "set_editor_text":
            let text = request.text ?? request.prompt ?? ""
            composerDraftController.primeRequest(sessionID: request.sessionId, requestID: request.id, text: text)
            return true
        case "notify", "setStatus", "setWidget", "setTitle":
            return true
        default:
            return false
        }
    }

    func shouldInvalidateSlashCommandCache(previous: SessionCard?, incoming: SessionCard) -> Bool {
        guard let previous else { return false }
        return previous.cwd != incoming.cwd
            || previous.piSessionFilePath != incoming.piSessionFilePath
            || (SessionCard.isRuntimeReattachLogLine(incoming.logPreview) && previous.logPreview != incoming.logPreview)
    }

    func invalidateSlashCommandCache(sessionID: String, refreshIfPreviouslyRequested: Bool = false) {
        slashCommandController.invalidate(
            sessionID: sessionID,
            refreshIfPreviouslyRequested: refreshIfPreviouslyRequested
        )
        syncSlashCommands()
    }

    /// Safety-net retry for the composer's "Loading commands…" state. If a previous request was
    /// dropped silently (e.g. transport loss), send another request in the same cache epoch so a
    /// slow-but-valid response from either request can still hydrate autocomplete instead of being
    /// starved by polling. No-op if commands are already loaded.
    func refreshSlashCommandsIfStillLoading(sessionID: String) {
        slashCommandController.refreshIfStillLoading(sessionID: sessionID)
    }

    func reconcileTodoProgressExpansion(
        sessionID: String,
        previousState: PickyTodoState?,
        currentState: PickyTodoState?
    ) {
        guard let currentPresentation = PickyTodoProgressPresentation(state: currentState) else {
            todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
            return
        }

        let previousIsComplete = PickyTodoProgressPresentation(state: previousState)?.isComplete
        let isTransitioningToIncomplete = previousIsComplete == true && !currentPresentation.isComplete

        if isTransitioningToIncomplete {
            todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        }

        guard PickyTodoProgressExpansionPolicy.shouldCollapse(
            previousIsComplete: previousIsComplete,
            currentIsComplete: currentPresentation.isComplete
        ) else { return }
        setTodoProgressExpanded(false, sessionID: sessionID)
    }

    func reconcileSubagentInvocationExpansion(
        sessionID: String,
        messages: [PickySessionMessage],
        previousRuns: [PickySubagentRun],
        currentRuns: [PickySubagentRun]
    ) {
        let invocations = messages.compactMap { message -> (PickySubagentInvocation, Date)? in
            guard message.kind == .subagentInvocation, let invocation = message.subagentInvocation else { return nil }
            return (invocation, message.createdAt)
        }
        guard !invocations.isEmpty else {
            subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
            return
        }
        for (invocation, createdAt) in invocations {
            let previousIsComplete = PickySubagentInvocationPresentation(
                invocation: invocation,
                runs: previousRuns,
                createdAt: createdAt
            )?.isComplete
            guard let current = PickySubagentInvocationPresentation(
                invocation: invocation,
                runs: currentRuns,
                createdAt: createdAt
            ) else { continue }
            if previousIsComplete == true && !current.isComplete {
                subagentInvocationExpandedBySessionID[sessionID]?[invocation.invocationId] = nil
            }
            if PickySubagentInvocationExpansionPolicy.shouldCollapse(
                previousIsComplete: previousIsComplete,
                currentIsComplete: current.isComplete
            ) {
                setSubagentInvocationExpanded(false, invocationID: invocation.invocationId, sessionID: sessionID)
            }
        }
    }

    private func pruneSlashCommandCache(knownSessionIDs: Set<String>) {
        slashCommandController.prune(knownSessionIDs: knownSessionIDs)
        syncSlashCommands()
        composerDraftController.prune(knownSessionIDs: knownSessionIDs)
        todoProgressExpandedBySessionID = todoProgressExpandedBySessionID.filter { knownSessionIDs.contains($0.key) }
        subagentInvocationExpandedBySessionID = subagentInvocationExpandedBySessionID.filter { knownSessionIDs.contains($0.key) }
        pendingDoneFlashSessionIDs = pendingDoneFlashSessionIDs.filter { knownSessionIDs.contains($0) }
        unreadSessionIDs = unreadSessionIDs.filter { knownSessionIDs.contains($0) }
        releasedArchivedChildSessionIDs = releasedArchivedChildSessionIDs.filter { knownSessionIDs.contains($0) }
        sessionDiffStoresBySessionID = sessionDiffStoresBySessionID.filter { knownSessionIDs.contains($0.key) }
        let removedShellTerminalIDs = Set(shellTerminalSessionsBySessionID.keys).subtracting(knownSessionIDs)
        for sessionID in removedShellTerminalIDs {
            closeShellTerminalSession(sessionID: sessionID)
        }
        if let screenContextTargetSessionID, !knownSessionIDs.contains(screenContextTargetSessionID) {
            clearScreenContextTarget(sessionID: screenContextTargetSessionID)
        }
    }

    func requestDoneFlashIfNeeded(previousStatus: PickySessionStatus?, incoming: SessionCard) {
        // Only celebrate live transitions into completed. nil previousStatus means a brand-new
        // session arriving already as .completed (e.g. snapshot replay routed through upsert);
        // the user did not watch it transition so we skip the flash. Snapshot hydration writes
        // directly to `sessions`/`archivedSessions` without going through upsert, so historical
        // completed sessions never reach this code path on initial connect.
        guard incoming.status == .completed else { return }
        guard let previousStatus, previousStatus != .completed else { return }
        pendingDoneFlashSessionIDs.insert(incoming.id)
    }

    /// Mark a session unread when it transitions live into a state the user is
    /// expected to acknowledge (completed, failed, or waiting for input). Clear
    /// the flag the moment the session leaves that bucket on its own — e.g. a
    /// follow-up turn drives it back into `.running` — so the dot does not
    /// linger past the user's attention.
    func updateUnreadStateIfNeeded(previousStatus: PickySessionStatus?, incoming: SessionCard) {
        let attentionStates: Set<PickySessionStatus> = [.completed, .failed, .waiting_for_input]
        let isAttentionNow = attentionStates.contains(incoming.status)
        let wasAttentionBefore = previousStatus.map(attentionStates.contains) ?? false
        if isAttentionNow {
            // Skip cold hydration: nil previousStatus means we are seeing this
            // session for the first time (snapshot replay routed through upsert).
            // The user never witnessed the transition, so we should not nag.
            guard let previousStatus else { return }
            guard previousStatus != incoming.status else { return }
            unreadSessionIDs.insert(incoming.id)
        } else if wasAttentionBefore {
            unreadSessionIDs.remove(incoming.id)
        }
    }

    // MARK: - Storage presentation boundary

    private func relaySessionProjectionStorageChange(_ publication: PickySessionProjectionStoragePublication) {
        // The façade keeps its established assignment boundaries while storage
        // itself remains independent of a transport/protocol dialect.
        for step in publication.steps {
            if step.changesActiveSessions { sessions = step.snapshot.activeSessions }
            if step.changesArchivedSessions { archivedSessions = step.snapshot.archivedSessions }
        }
    }

    private func removeSession(id: String) { sessionProjectionStorage.removeSession(id: id) }
    /// Local archive actions in v2 move registry membership only, preserving
    /// all addressed and unrelated child stores. The legacy fallback retains
    /// the façade storage behavior for non-registry implementations.
    @discardableResult private func moveSessionProjectionMembership(id: String, archived: Bool) -> SessionCard? {
        if let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage {
            return storage.moveProjectionMembership(sessionID: id, archived: archived)
        }
        return archived
            ? sessionProjectionStorage.archiveSession(id: id)
            : sessionProjectionStorage.unarchiveSession(id: id)
    }

    func updateCompletionNotificationProjection(sessionID: String, notifyMain: Bool? = nil, notifyMacOS: Bool? = nil) {
        mutateSession(sessionID: sessionID) { card in
            if let notifyMain { card.notifyMainOnCompletion = notifyMain }
            if let notifyMacOS { card.notifyMacOSOnCompletion = notifyMacOS }
            card.updatedAt = Date()
        }
    }

    private func mutateSession(sessionID: String, mutate: (inout SessionCard) -> Void) {
        PickyPerf.event("vm_update_called")
        var didMutateActive = false
        PickyPerf.interval("vm_update_active_session") {
            guard let updatedCard = sessionProjectionStorage.mutateSession(sessionID: sessionID, mutate: { card in
                PickyPerf.interval("vm_update_mutate_card") { mutate(&card) }
            }) else { return }
            // Manual order is the source of truth for active session ordering;
            // a per-card mutation does not change order, so no reapply needed.
            PickyPerf.interval("vm_update_sync_selection_state") {
                syncSelectionAfterSessionListChange()
                syncVoiceFollowUpAfterSessionListChange()
                syncScreenContextTargetAfterSessionListChange()
                syncActiveVoiceFollowUpAfterSessionListChange()
            }
            deliverNotificationIfNeeded(for: updatedCard)
            didMutateActive = true
        }
        if !didMutateActive { mutateArchivedSession(sessionID: sessionID, mutate: mutate) }
    }

    private func mutateArchivedSession(sessionID: String, mutate: (inout SessionCard) -> Void) {
        PickyPerf.interval("vm_update_archived_session") {
            _ = sessionProjectionStorage.mutateArchivedSession(sessionID: sessionID) { card in
                PickyPerf.interval("vm_update_mutate_card") {
                    mutate(&card)
                }
            }
        }
    }

    func applyManualOrder(_ order: [String]) {
        sessionProjectionStorage.applyManualOrder(order)
    }

    /// Reapply active ordering from manual order, or the historic creation-time
    /// order when no user reorder exists.
    func applyManualOrder() {
        PickyPerf.event("vm_apply_manual_order_called")
        // Reconcile first so new Pickles enter the dock layout before rendering.
        PickyPerf.interval("vm_apply_manual_order_reconcile_dock_layout") {
            reconcileDockLayout()
        }
        guard !manualOrder.isEmpty else {
            PickyPerf.interval("vm_apply_manual_order_publish_sorted_default") {
                sessionProjectionStorage.applyManualOrder(sessions.sortedForHUD().map(\.id))
            }
            return
        }
        let order = PickyDockManualOrderPolicy.reconciled(
            manualOrder: manualOrder,
            activeIDsNewestFirst: sessions.sortedForHUD().map(\.id),
            archivedIDs: Set(archivedSessions.map(\.id))
        )
        if order != manualOrder {
            manualOrder = order
            manualOrderStore.manualOrder = order
        }
        PickyPerf.interval("vm_apply_manual_order_publish_manual") {
            applyManualOrder(order)
        }
    }

    /// Seed manual order from the current active order on the first drag.
    private func seedManualOrderIfNeeded() {
        guard manualOrder.isEmpty else { return }
        let sorted = sessions.sortedForHUD()
        let order = sorted.map(\.id)
        guard !order.isEmpty else { return }
        manualOrder = order
        manualOrderStore.manualOrder = order
    }

    /// Move a dock icon in visible (`sessions.reversed()`) space.
    /// Returns whether the order changed.
    @discardableResult
    func moveSession(sessionID: String, toVisibleIndex visibleTargetRaw: Int) -> Bool {
        let visibleCount = sessions.count
        guard visibleCount > 0 else { return false }

        guard let underlyingCurrent = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let visibleCurrent = PickyDockManualOrderPolicy.underlyingIndex(visibleIndex: underlyingCurrent, count: visibleCount)
        let visibleTarget = PickyDockManualOrderPolicy.clampedVisibleIndex(visibleTargetRaw, count: visibleCount)
        guard visibleCurrent != visibleTarget else { return false }

        // Ensure every active session id is present in manualOrder before the
        // move. Otherwise inserting the dragged id by "active-count" index
        // would skip over the newcomer entries that have not been synced yet.
        seedManualOrderIfNeeded()
        applyManualOrder()
        guard let order = PickyDockManualOrderPolicy.moved(
            manualOrder: manualOrder,
            sessionID: sessionID,
            activeIDs: Set(sessions.map(\.id)),
            underlyingTarget: PickyDockManualOrderPolicy.underlyingIndex(visibleIndex: visibleTarget, count: visibleCount)
        ) else { return false }

        manualOrder = order
        manualOrderStore.manualOrder = order
        applyManualOrder(order)
        return true
    }

    /// `deferringUnknownSessionDemotion` is set by the projection snapshot
    /// seam. Applying a snapshot can move a *known* session between active and
    /// archived membership, but it can never turn a known session into an
    /// unknown one. So a selection naming a session this app has not received
    /// yet means "not delivered yet", not "does not exist", and dropping it
    /// there erased the persisted choice on every cold bootstrap whose
    /// selected Pickle was not the first snapshot in the wave.
    /// `applySessionProjectionBootstrapCompletion` is the one caller holding
    /// authoritative membership, so it stays the single place that demotes a
    /// selection for a session the daemon never sent.
    func syncSelectionAfterSessionListChange(
        skippingRedundantPublishedAssignments: Bool = false,
        deferringUnknownSessionDemotion: Bool = false
    ) {
        if hasExplicitSelection, let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            selectionStore.selectedSessionID = selectedSessionID
        } else if deferringUnknownSessionDemotion,
                  hasExplicitSelection,
                  let selectedSessionID,
                  !archivedSessions.contains(where: { $0.id == selectedSessionID }) {
            // Unknown to this app so far: wait for authoritative membership.
        } else {
            hasExplicitSelection = false
            let defaultSessionID = defaultSelectionID()
            if !skippingRedundantPublishedAssignments || selectedSessionID != defaultSessionID { selectedSessionID = defaultSessionID }
            selectionStore.selectedSessionID = nil
        }
    }

    func syncVoiceFollowUpAfterSessionListChange() {
        if let hoveredVoiceFollowUpSessionID, sessions.contains(where: { $0.id == hoveredVoiceFollowUpSessionID }) {
            selectionStore.hoveredVoiceFollowUpSessionID = hoveredVoiceFollowUpSessionID
        } else {
            voiceFollowUpHoverState.sessionID = nil
            selectionStore.hoveredVoiceFollowUpSessionID = nil
        }
    }

    func syncScreenContextTargetAfterSessionListChange() {
        if let screenContextTargetSessionID,
           let session = sessions.first(where: { $0.id == screenContextTargetSessionID }) {
            if let labelStore = selectionStore as? PickyScreenContextTargetLabelStoring {
                labelStore.setScreenContextTarget(
                    sessionID: screenContextTargetSessionID,
                    sticky: screenContextTargetSticky,
                    label: session.title
                )
            } else {
                selectionStore.setScreenContextTarget(sessionID: screenContextTargetSessionID, sticky: screenContextTargetSticky)
            }
        } else if screenContextTargetSessionID != nil {
            clearScreenContextTarget(sessionID: screenContextTargetSessionID)
        }
    }

    private func setActiveVoiceFollowUpSessionID(_ sessionID: String?) {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        activeVoiceFollowUpSessionID = trimmed.isEmpty ? nil : trimmed
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    func syncActiveVoiceFollowUpAfterSessionListChange(skippingRedundantPublishedAssignments: Bool = false) {
        if let activeVoiceFollowUpSessionID, sessions.contains(where: { $0.id == activeVoiceFollowUpSessionID }) { return }
        if !skippingRedundantPublishedAssignments || activeVoiceFollowUpSessionID != nil { activeVoiceFollowUpSessionID = nil }
    }

    private func defaultSelectionID() -> String? {
        sessions.sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }.first?.id
    }

    func markNotificationDeliveredIfNeeded(for session: SessionCard) {
        guard let notification = notification(for: session) else { return }
        deliveredNotificationKeys.insert(notification.key)
    }

    func deliverNotificationIfNeeded(for session: SessionCard) {
        guard let notification = notification(for: session) else {
            resetTerminalNotificationKeysIfNeeded(for: session)
            return
        }

        guard !deliveredNotificationKeys.contains(notification.key) else { return }
        deliveredNotificationKeys.insert(notification.key)
        notificationCenter.deliver(title: notification.title, body: notification.body, identifier: notification.key)
    }

    private func notification(for session: SessionCard) -> PickySessionNotificationPolicy.Notification? {
        PickySessionNotificationPolicy.notification(
            for: PickySessionNotificationPolicy.Input(card: session),
            preferences: notificationPreferencesProvider.notificationPreferences
        )
    }

    private func resetTerminalNotificationKeysIfNeeded(for session: SessionCard) {
        deliveredNotificationKeys.subtract(
            PickySessionNotificationPolicy.terminalDedupKeysToReset(
                sessionID: session.id,
                status: session.status
            )
        )
    }
}

func pickySessionLog(_ message: String) {
    PickyLog.notice(.sessionUI, prefix: "🧭 Picky session UI —", message: message)
}
