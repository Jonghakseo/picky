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
    /// Published mirror of `PickySessionComposerDraftController` request state.
    /// `PickyConversationComposerView` observes this dictionary with `.onChange`,
    /// so every controller mutation path must call `syncComposerDraftRequests()`.
    @Published private(set) var composerDraftRequestsBySessionID: [String: PickyComposerDraftRequest] = [:]
    @Published private(set) var thinkingBlocksHiddenBySessionID: [String: Bool] = [:]
    /// Per-session TODO expansion choice survives Conversation Card teardown while the HUD is closed.
    @Published private(set) var todoProgressExpandedBySessionID: [String: Bool] = [:]
    /// Per-invocation expansion survives conversation-card teardown while the HUD is closed.
    @Published private(set) var subagentInvocationExpandedBySessionID: [String: [String: Bool]] = [:]
    @Published private(set) var pendingDoneFlashSessionIDs: Set<String> = [] {
        didSet { publishDockStateImmediately() }
    }
    /// Sessions whose detail card is currently presented as an inline Pi TUI instead of
    /// the SwiftUI chat/composer. This is intentionally UI-only state: the daemon and
    /// existing terminal overlay keep their current behavior.
    @Published private(set) var inlineTerminalSessionIDs: Set<String> = []
    /// The one inline terminal attachment that is allowed to render its SwiftTerm NSView.
    /// Other visible inline terminal cards stay in TUI mode but show an explanatory
    /// placeholder so AppKit never has to attach one terminal view to multiple parents.
    let inlineTerminalAttachmentStore = PickyTerminalAttachmentStore()
    var activeInlineTerminalAttachmentSessionID: String? { inlineTerminalAttachmentStore.activeSessionID }
    /// Long-lived inline terminal sessions keyed by Pickle session ID. The terminal
    /// NSView/process is retained here so collapsing/reopening the HUD card reuses
    /// the same TUI instead of launching a fresh `pi --session` process.
    private var inlineTerminalSessionsBySessionID: [String: PickyInlineTerminalSession] = [:]
    private struct ClosingInlineTerminalSession {
        let session: PickyInlineTerminalSession
        let sessionID: String
        var syncAllowed: Bool
    }
    private var closingInlineTerminalSessionsByCloseID: [UUID: ClosingInlineTerminalSession] = [:]
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
    /// Fires every time a dock card is opened (the user clicked it to expand).
    /// Distinct from `selectedSessionID` so subscribers can react to repeated
    /// open gestures on the same session. Used by the onboarding flow to
    /// detect when the user inspects the demo Pickle's contents.
    @Published private(set) var lastOpenedSessionToken: UUID = UUID()
    private(set) var lastOpenedSessionID: String?
    /// Symmetric counterpart of `lastOpenedSessionToken`: fires every time the
    /// user toggles an open card back closed. Lets the onboarding flow split
    /// 'click to close' and 'long-press to archive' into separate beats.
    @Published private(set) var lastClosedSessionToken: UUID = UUID()
    private(set) var lastClosedSessionID: String?

    var selectedSession: SessionCard? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    /// Archive-membership boundary, stable across the future storage cutover.
    var archivedSessionIDsPublisher: AnyPublisher<Set<String>, Never> { $archivedSessions.map { Set($0.map(\.id)) }.removeDuplicates().eraseToAnyPublisher() }
    func isSessionArchived(_ sessionID: String) -> Bool { archivedSessions.contains { $0.id == sessionID } }

    let client: any PickyAgentClient
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
    // Dock layout facade owns reset-to-default order through this state.
    var manualOrder: [String] = []
    /// Persisted dock layout (groups + ordered top-level entries). Source of
    /// truth for the dock rail's visual ordering once any group has been
    /// created. Empty layout falls back to the legacy `manualOrder` flow.
    @Published internal(set) var dockLayout: PickyDockLayout = .empty {
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
    enum PendingDockGroupAssignment {
        case groupName(String)
        case groupID(String)
    }
    var pendingDockGroupAssignments: [String: PendingDockGroupAssignment] = [:]
    internal var dockLayoutReconciliationSuspensionDepth = 0
    private let composerDraftController: PickySessionComposerDraftController
    private var slashCommandController: PickySessionSlashCommandController!
    private let recentPickleFolderStore: PickyRecentPickleFolderStoring
    private let artifactPathValidator: PickyArtifactPathValidator
    private let clipboardWriter: PickyClipboardWriting
    private let terminalPresenter: PickyTerminalOverlayPresenting
    private let terminalSessionSyncer: PickyTerminalSessionSyncing
    private let reportPresenter: PickyReportPresenting
    private let toolHistoryPresenter: PickyToolHistoryPresenting
    private let generatedReportDirectory: URL
    private let manualPickleChildSpawner: (any PickyManualPickleChildSpawning)?
    private let childSessionReleaser: (any PickyChildSessionReleasing)?
    private let archiveCommitDelayNanoseconds: UInt64
    private var archiveCommitTasks: [String: Task<Void, Never>] = [:]
    /// User archive actions are optimistic. Preserve their intent until a
    /// matching v2 projection mutation or recovery snapshot confirms it.
    var pendingArchiveIntentBySessionID: [String: Bool] = [:]
    private var pendingArchiveIntentByCommandID: [String: (sessionID: String, archived: Bool)] = [:]
    var releasedArchivedChildSessionIDs = Set<String>()
    private let manualPickleSessionIdFactory: () -> String
    private var terminalSessionCommandChains: [String: Task<Void, Never>] = [:]
    private var terminalOverlayHandlesBySessionID: [String: PickyTerminalOverlayHandle] = [:]
    private var terminalSessionCommandChainIDs: [String: UUID] = [:]
    private var eventTask: Task<Void, Never>?
    /// Safety watchdog that flips `isLoadingInitialSessionSnapshot` to `false`
    /// even when the daemon never delivers a `sessionSnapshot` (e.g. WebSocket
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
    /// for the first `sessionSnapshot` after the WebSocket handshake
    /// completed — or, if the watchdog fires, exactly how long we waited
    /// before giving up.
    private var lastConnectedAt: Date?
    private var voiceFollowUpTargetCancellable: AnyCancellable?
    private var screenContextTargetCancellable: AnyCancellable?
    private var composerDraftAppendCancellable: AnyCancellable?
    private var deliveredNotificationKeys = Set<String>()
    /// Terminal thin updates that precede initial journal hydration. They must
    /// not create an empty card, but their live transition still needs to run
    /// through `upsert` once a full session payload arrives so notifications
    /// are not silently cold-seeded.
    var pendingTerminalMetaBySessionID: [String: PickyAgentSession] = [:]
    private let slashCommandSuggestionSlowLogThreshold: TimeInterval = 0.02
    private var lastIncrementalSeqBySessionID: [String: Int] = [:]
    private var hasExplicitSelection = false
    let sessionProjectionStorage: any PickySessionProjectionStorage
    /// App composition uses this narrow notification to wake bridge requests
    /// waiting for a registry-backed v2 session. It carries no projection data,
    /// so storage remains the sole state owner.
    var onSessionProjectionStorageChanged: (() -> Void)?
    private var sessionProjectionStorageCancellable: AnyCancellable?
    private var sessionProjectionRecoveryCoordinator: PickySessionRecoveryCoordinator?
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
        terminalPresenter: PickyTerminalOverlayPresenting? = nil,
        terminalSessionSyncer: PickyTerminalSessionSyncing = PickyPiSessionFileSyncer(),
        reportPresenter: PickyReportPresenting? = nil,
        toolHistoryPresenter: PickyToolHistoryPresenting? = nil,
        generatedReportDirectory: URL = PickyAppSupport.defaultRoot().appendingPathComponent("GeneratedReports", isDirectory: true),
        manualPickleChildSpawner: (any PickyManualPickleChildSpawning)? = nil,
        childSessionReleaser: (any PickyChildSessionReleasing)? = nil,
        archiveCommitDelayNanoseconds: UInt64 = PickyHUDArchiveUndoToastPolicy.durationNanoseconds,
        manualPickleSessionIdFactory: @escaping () -> String = { "session-\(UUID().uuidString)" },
        shellTerminalSessionFactory: ((SessionCard) -> PickyShellTerminalSession)? = nil, sessionProjectionStorage: (any PickySessionProjectionStorage)? = nil
    ) {
        self.client = client
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
        self.artifactPathValidator = artifactPathValidator
        self.clipboardWriter = clipboardWriter
        self.terminalPresenter = terminalPresenter ?? PickyTerminalOverlayPresenter.shared
        self.terminalSessionSyncer = terminalSessionSyncer
        self.reportPresenter = reportPresenter ?? PickyReportViewerPresenter.shared
        self.toolHistoryPresenter = toolHistoryPresenter ?? PickyToolHistoryPresenter.shared
        self.generatedReportDirectory = generatedReportDirectory
        self.manualPickleChildSpawner = manualPickleChildSpawner
        self.childSessionReleaser = childSessionReleaser
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
            authoritativeRemovalEvent: authoritativeDockRemovalEvent
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
            pickySessionLog("initial snapshot watchdog fired — unblocking dock UI without sessionSnapshot waitedSinceConnectedMs=\(waitedMs)")
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
        openSessionRequest = PickyHUDOpenSessionRequest(sessionID: sessionID, targetDisplayID: targetDisplayID)
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
            let command = PickyCommandEnvelope(type: .createEmptyPickleSession, context: context)
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

    /// Purge a locally-created demo session entirely — active list, archive,
    /// and every per-session tracking map. Used by the onboarding flow when
    /// the user skips mid-tour; we don't want the fake Pickle lingering in
    /// archive search where clicking it would do nothing because the daemon
    /// has never heard of it. Distinct from `archive(sessionID:)` (which
    /// sends a daemon command) since the demo session is purely client-side.
    func removeOnboardingDemoSession(sessionID: String) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        removeSession(id: sessionID)
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
        thinkingBlocksHiddenBySessionID.removeValue(forKey: sessionID)
        todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
        slashCommandController.clear(sessionID: sessionID)
        syncSlashCommands()
        lastIncrementalSeqBySessionID.removeValue(forKey: sessionID)
        pendingTerminalMetaBySessionID.removeValue(forKey: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        if screenContextTargetSessionID == sessionID {
            clearScreenContextTargetState()
        }
        reconcileDockLayout()
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

    func consumeComposerDraftRequest(sessionID: String, requestID: String) {
        composerDraftController.consumeRequest(sessionID: sessionID, requestID: requestID)
        syncComposerDraftRequests()
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
        syncComposerDraftRequests()
    }

    func appendComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.appendText(text, sessionID: sessionID) else { return }
        syncComposerDraftRequests()
        select(sessionID: sessionID)
    }

    func replaceComposerDraftText(_ text: String, sessionID: String) {
        guard composerDraftController.replaceText(text, sessionID: sessionID) else { return }
        syncComposerDraftRequests()
        select(sessionID: sessionID)
    }

    @discardableResult
    func restoreQueuedInputsToComposerDraft(sessionID: String, kind: PickyQueueClearKind = .all) -> Bool {
        guard let session = card(sessionID: sessionID),
              let queuedText = PickyQueuedInputDraftPolicy.queuedInputText(
                queuedSteers: session.queuedSteers,
                queuedFollowUps: session.queuedFollowUps,
                kind: kind
              )
        else { return false }
        appendComposerDraftText(queuedText, sessionID: sessionID)
        return true
    }

    func clearQueueRestoringQueuedInputs(sessionID: String, kind: PickyQueueClearKind) async throws {
        restoreQueuedInputsToComposerDraft(sessionID: sessionID, kind: kind)
        try await clearQueue(sessionID: sessionID, kind: kind)
    }

    func abortRestoringQueuedInputs(sessionID: String) async throws {
        let restoredQueuedInputs = restoreQueuedInputsToComposerDraft(sessionID: sessionID, kind: .all)
        if restoredQueuedInputs {
            try? await clearQueue(sessionID: sessionID, kind: .all)
        }
        try await abort(sessionID: sessionID)
    }

    private func syncSlashCommands() {
        let commandsBySessionID = slashCommandController.commandsBySessionID
        guard slashCommandsBySessionID != commandsBySessionID else { return }
        slashCommandsBySessionID = commandsBySessionID
    }

    private func syncComposerDraftRequests() {
        composerDraftRequestsBySessionID = composerDraftController.requestsBySessionID
    }

    func copyMessageText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardWriter.copy(text)
        lastError = nil
    }

    func thinkingBlocksHidden(sessionID: String) -> Bool {
        if let value = thinkingBlocksHiddenBySessionID[sessionID] { return value }
        guard let session = card(sessionID: sessionID) else { return false }
        return PickyPiSettingsReader.hideThinkingBlock(cwd: session.cwd)
    }

    func toggleThinkingBlocks(sessionID: String) {
        guard let session = card(sessionID: sessionID) else { return }
        let nextValue = !thinkingBlocksHidden(sessionID: sessionID)
        do {
            try PickyPiSettingsReader.setHideThinkingBlock(nextValue, cwd: session.cwd)
            lastError = nil
            syncThinkingBlockVisibility()
            pickySessionLog("thinking blocks hidden=\(nextValue) session=\(sessionID)")
        } catch {
            lastError = error.localizedDescription
        }
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

    /// Called when the user opens a Pickle in any dock. Clears the unread badge
    /// across every HUD instance via the shared `@Published` set, and bumps
    /// `lastOpenedSessionToken` so non-HUD subscribers (e.g. onboarding) can
    /// react to the open gesture regardless of unread state.
    func markSessionRead(sessionID: String) {
        lastOpenedSessionID = sessionID
        lastOpenedSessionToken = UUID()
        guard unreadSessionIDs.contains(sessionID) else { return }
        unreadSessionIDs.remove(sessionID)
    }

    /// Mirror of `markSessionRead` for the close gesture: HUDView calls this
    /// when a previously-open dock card is toggled back closed. Onboarding
    /// uses it to split the open / close / archive CTAs into separate beats.
    func markSessionClosed(sessionID: String) {
        lastClosedSessionID = sessionID
        lastClosedSessionToken = UUID()
    }

    func followUp(text: String, sessionID: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Follow-up message cannot be empty"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = "No session selected for follow-up"
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = "Cannot follow up an archived Pickle session"
                throw PickySessionListViewModelError.archivedSession
            }
            lastError = "No session selected for follow-up"
            throw PickySessionListViewModelError.noSessionSelected
        }
        pickySessionLog("follow-up session=\(target) textChars=\(trimmed.count)")
        do {
            try await client.send(PickyCommandEnvelope(type: .followUp, sessionId: target, text: trimmed))
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
            lastError = "Steer message cannot be empty"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        guard let target = sessionID ?? selectedSession?.id else {
            lastError = "No session selected for steering"
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard sessions.contains(where: { $0.id == target }) else {
            if archivedSessions.contains(where: { $0.id == target }) {
                lastError = "Cannot steer an archived Pickle session"
                throw PickySessionListViewModelError.archivedSession
            }
            lastError = "No session selected for steering"
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
            lastError = "No session for retry"
            throw PickySessionListViewModelError.noSessionSelected
        }
        guard let text = card.lastRequestText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            lastError = "No previous request text to retry"
            throw PickySessionListViewModelError.emptyFollowUp
        }
        pickySessionLog("retry-after-race session=\(sessionID) textChars=\(text.count)")
        try await steer(text: text, sessionID: sessionID)
    }

    func abort(sessionID: String) async throws {
        pickySessionLog("abort session=\(sessionID)")
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

    func cycleThinkingLevel(sessionID: String) async throws {
        pickySessionLog("cycle thinking level session=\(sessionID)")
        do {
            try await client.send(PickyCommandEnvelope(type: .cycleSessionThinkingLevel, sessionId: sessionID))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func cycleModel(sessionID: String, direction: PickyModelCycleDirection = .forward) async throws {
        pickySessionLog("cycle model session=\(sessionID) direction=\(direction.rawValue)")
        do {
            try await client.send(PickyCommandEnvelope(type: .cycleSessionModel, sessionId: sessionID, direction: direction))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func setNotifyMainOnCompletion(sessionID: String, enabled: Bool) async throws {
        pickySessionLog("set notify main on completion session=\(sessionID) enabled=\(enabled)")
        try await client.send(PickyCommandEnvelope(type: .setNotifyMainOnCompletion, sessionId: sessionID, enabled: enabled))
        mutateSession(sessionID: sessionID) { card in
            card.notifyMainOnCompletion = enabled
            card.updatedAt = Date()
        }
    }

    func answerExtensionUi(sessionID: String, requestID: String, value: JSONValue) async throws {
        pickySessionLog("answer extension-ui session=\(sessionID) request=\(requestID)")
        try await client.send(PickyCommandEnvelope(type: .answerExtensionUi, sessionId: sessionID, requestId: requestID, value: value))
        mutateSession(sessionID: sessionID) { card in
            let now = Date()
            if let pending = card.pendingExtensionUiRequest, pending.id == requestID {
                if let summary = PickyAskUserQuestionFormState.summarizeAnswer(request: pending, value: value) {
                    card.lastRequestText = summary
                    card.lastRequestAt = now
                }
                card.pendingExtensionUiRequest = nil
                card.status = .running
                card.lastSummary = "Extension UI answered"
            }
            card.updatedAt = now
        }
    }

    func cancelExtensionUi(sessionID: String, requestID: String) async throws {
        try await answerExtensionUi(sessionID: sessionID, requestID: requestID, value: .object(["cancelled": .bool(true)]))
    }

    func openToolHistory(sessionID: String, scope: PickyToolHistoryScope = .session) {
        pickySessionLog("open tool history session=\(sessionID) scope=\(scope)")
        let title = sessionTitle(for: sessionID)
        toolHistoryPresenter.openHistory(sessionID: sessionID, title: title, scope: scope) { [weak self] in
            self?.toolsForSession(sessionID: sessionID) ?? []
        }
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

    private func toolsForSession(sessionID: String) -> [PickyToolActivity]? {
        (sessions + archivedSessions).first(where: { $0.id == sessionID })?.tools
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
            lastError = "Latest response is not available as a report"
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
            lastError = "Message is not available as a report"
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
            lastError = "Subagent response is not available as a report"
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

    func isInlineTerminalMode(sessionID: String) -> Bool {
        inlineTerminalSessionIDs.contains(sessionID)
    }

    func enableInlineTerminalMode(sessionID: String) {
        pickySessionLog("enable inline terminal session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              session.piSessionFilePath != nil else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        inlineTerminalSessionIDs.insert(sessionID)
        _ = inlineTerminalSession(for: session)
        endHoveredVoiceFollowUp(sessionID: sessionID)
        setTerminalSessionTailEnabled(sessionID: sessionID, enabled: true)
        lastError = nil
    }

    func disableInlineTerminalMode(sessionID: String) {
        pickySessionLog("disable inline terminal session=\(sessionID)")
        // Stop the daemon-side tail before draining the inline terminal so the final
        // `syncTerminalSession` reconcile (scheduled inside `closeInlineTerminalSession`)
        // doesn't race the tail watcher for the same JSONL entries.
        setTerminalSessionTailEnabled(sessionID: sessionID, enabled: false)
        inlineTerminalSessionIDs.remove(sessionID)
        removeVisibleInlineTerminalAttachments(sessionID: sessionID)
        endHoveredVoiceFollowUp(sessionID: sessionID)
        closeInlineTerminalSession(sessionID: sessionID)
    }

    /// Asks the daemon to start/stop tailing the Pi JSONL file for `sessionID`. Called whenever
    /// the user enters or leaves an inline TUI / Pi terminal overlay so the HUD dock icon keeps
    /// transitioning (`running` -> `completed`) even though agentd's own runtime is idle. Fire and
    /// forget: failures are logged at the daemon side and the HUD just degrades to the previous
    /// "frozen status until overlay close" behaviour.
    private func setTerminalSessionTailEnabled(sessionID: String, enabled: Bool) {
        enqueueTerminalSessionCommand(sessionID: sessionID) { [weak self] in
            await self?.sendTerminalSessionTailEnabled(sessionID: sessionID, enabled: enabled)
        }
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

    private func sendTerminalSessionTailEnabled(sessionID: String, enabled: Bool) async {
        let command = PickyCommandEnvelope(
            type: .setTerminalSessionTailEnabled,
            sessionId: sessionID,
            enabled: enabled
        )
        do {
            try await client.send(command)
        } catch {
            pickySessionLog("terminal tail toggle failed session=\(sessionID) enabled=\(enabled) error=\(error.localizedDescription)")
        }
    }

    func toggleInlineTerminalMode(sessionID: String) {
        if isInlineTerminalMode(sessionID: sessionID) {
            disableInlineTerminalMode(sessionID: sessionID)
        } else {
            enableInlineTerminalMode(sessionID: sessionID)
        }
    }

    func inlineTerminalSession(for session: SessionCard) -> PickyInlineTerminalSession? {
        guard inlineTerminalSessionIDs.contains(session.id) else { return nil }
        if let existing = inlineTerminalSessionsBySessionID[session.id] {
            return existing
        }
        guard let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return nil
        }
        let baselineSnapshot = terminalSessionSnapshotIfAvailable(sessionFilePath: piSessionFilePath)
        let inlineSession = PickyInlineTerminalSession(
            sessionID: session.id,
            title: session.title,
            sessionFilePath: piSessionFilePath,
            cwd: session.cwd,
            baselineSnapshot: baselineSnapshot,
            fontScalePersister: PickyTerminalFontScalePersister.defaultSettings()
        )
        inlineTerminalSessionsBySessionID[session.id] = inlineSession
        return inlineSession
    }

    func isInlineTerminalAttachmentActive(sessionID: String, attachmentID: String) -> Bool {
        inlineTerminalAttachmentStore.isActive(sessionID: sessionID, attachmentID: attachmentID)
    }

    func activateInlineTerminalAttachment(sessionID: String, attachmentID: String) {
        inlineTerminalAttachmentStore.activate(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
    }

    func releaseInlineTerminalAttachment(sessionID: String, attachmentID: String) {
        inlineTerminalAttachmentStore.release(
            sessionID: sessionID,
            attachmentID: attachmentID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
    }

    private func removeVisibleInlineTerminalAttachments(sessionID: String) {
        inlineTerminalAttachmentStore.removeSession(
            sessionID: sessionID,
            eligibleSessionIDs: inlineTerminalSessionIDs
        )
    }

    private func closeInlineTerminalSession(sessionID: String, schedulesSync: Bool = true) {
        guard let inlineSession = inlineTerminalSessionsBySessionID.removeValue(forKey: sessionID) else { return }
        let closeID = UUID()
        closingInlineTerminalSessionsByCloseID[closeID] = ClosingInlineTerminalSession(
            session: inlineSession,
            sessionID: sessionID,
            syncAllowed: schedulesSync
        )
        inlineSession.closeAndScheduleSync { [weak self] baselineSnapshot in
            guard let self,
                  let closing = self.closingInlineTerminalSessionsByCloseID.removeValue(forKey: closeID)
            else { return }
            if closing.syncAllowed {
                self.syncTerminalSessionOnce(sessionID: closing.sessionID, baselineSnapshot: baselineSnapshot)
            }
        }
    }

    /// A membership completion makes an old session incarnation permanently
    /// invalid. Revoke both a new close and a close already waiting on process
    /// exit, so its callback cannot sync into a recreated same-ID session.
    private func invalidatePendingInlineTerminalSync(sessionID: String) {
        for closeID in Array(closingInlineTerminalSessionsByCloseID.keys) {
            guard closingInlineTerminalSessionsByCloseID[closeID]?.sessionID == sessionID else { continue }
            closingInlineTerminalSessionsByCloseID[closeID]?.syncAllowed = false
        }
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

    func openTerminalOverlay(sessionID: String) {
        pickySessionLog("open terminal overlay session=\(sessionID)")
        guard let session = (sessions + archivedSessions).first(where: { $0.id == sessionID }),
              let piSessionFilePath = session.piSessionFilePath else {
            lastError = PickySessionListViewModelError.missingPiSessionFile.localizedDescription
            return
        }
        // The overlay launches its own `pi --session` process against the on-disk session
        // file, so the user gets a terminal view of the transcript even when the daemon is
        // still writing to it.

        let baselineSnapshot = terminalSessionSnapshotIfAvailable(sessionFilePath: piSessionFilePath)

        do {
            let handle = try terminalPresenter.openTerminal(
                sessionID: session.id,
                title: session.title,
                sessionFilePath: piSessionFilePath,
                cwd: session.cwd,
                onClose: { [weak self] closedHandle in
                    guard let self,
                          self.terminalOverlayHandlesBySessionID[session.id] == closedHandle else {
                        return
                    }
                    self.terminalOverlayHandlesBySessionID[session.id] = nil
                    // Stop the daemon-side tail BEFORE the reconcile so we don't race the
                    // post-close `syncTerminalSession` for the same final JSONL entries.
                    self.setTerminalSessionTailEnabled(sessionID: session.id, enabled: false)
                    self.syncTerminalSessionOnce(sessionID: session.id, baselineSnapshot: baselineSnapshot)
                }
            )
            terminalOverlayHandlesBySessionID[session.id] = handle
            setTerminalSessionTailEnabled(sessionID: session.id, enabled: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncTerminalSessionOnce(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot? = nil) {
        enqueueTerminalSessionCommand(sessionID: sessionID) { [weak self] in
            await self?.sendTerminalSessionSync(sessionID: sessionID, baselineSnapshot: baselineSnapshot)
        }
    }

    private func sendTerminalSessionSync(sessionID: String, baselineSnapshot: PickyTerminalSessionSnapshot? = nil) async {
        guard (sessions + archivedSessions).contains(where: { $0.id == sessionID }) else { return }
        let command = PickyCommandEnvelope(
            type: .syncTerminalSession,
            sessionId: sessionID,
            baselinePiMessageId: baselineSnapshot?.lastMessageId
        )
        do {
            try await client.send(command)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func terminalSessionSnapshotIfAvailable(sessionFilePath: String) -> PickyTerminalSessionSnapshot? {
        do {
            let snapshot = try terminalSessionSyncer.snapshot(sessionFilePath: sessionFilePath)
            return snapshot.isEmpty ? nil : snapshot
        } catch {
            return nil
        }
    }

    func archive(sessionID: String) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("archive session=\(sessionID)")
        if isInlineTerminalMode(sessionID: sessionID) {
            disableInlineTerminalMode(sessionID: sessionID)
        }
        closeShellTerminalSession(sessionID: sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.insert(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.insert(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        sendArchiveIntent(sessionID: sessionID, archived: true)

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
        let command = PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: archived)
        pendingArchiveIntentBySessionID[sessionID] = archived
        pendingArchiveIntentByCommandID[command.id] = (sessionID, archived)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await client.send(command)
            } catch {
                handleArchiveIntentFailure(commandID: command.id)
                pickySessionLog("set archive intent failed session=\(sessionID) archived=\(archived) error=\(error.localizedDescription)")
            }
        }
    }

    /// Removes all correlation state once the daemon confirms or rejects the
    /// current archive intent. A stale command ID can then never undo a newer
    /// user action for the same session.
    func clearPendingArchiveIntent(sessionID: String) {
        pendingArchiveIntentBySessionID.removeValue(forKey: sessionID)
        pendingArchiveIntentByCommandID = pendingArchiveIntentByCommandID.filter { $0.value.sessionID != sessionID }
    }

    /// Reverses only the current optimistic action when its command was
    /// rejected. This makes the generic command-correlated `error` frame a
    /// liveness signal rather than leaving local archive intent permanent.
    func handleArchiveIntentFailure(commandID: String?) {
        guard let commandID,
              let pending = pendingArchiveIntentByCommandID.removeValue(forKey: commandID),
              pendingArchiveIntentBySessionID[pending.sessionID] == pending.archived
        else { return }

        beginDockStateMutation()
        defer { endDockStateMutation() }
        clearPendingArchiveIntent(sessionID: pending.sessionID)
        if pending.archived {
            archiveStore.archivedSessionIDs.remove(pending.sessionID)
            archiveStore.manuallyArchivedSessionIDs.remove(pending.sessionID)
            archiveCommitTasks.removeValue(forKey: pending.sessionID)?.cancel()
            releasedArchivedChildSessionIDs.remove(pending.sessionID)
            _ = moveSessionProjectionMembership(id: pending.sessionID, archived: false)
        } else {
            archiveStore.archivedSessionIDs.insert(pending.sessionID)
            archiveStore.manuallyArchivedSessionIDs.insert(pending.sessionID)
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
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        let delay = archiveCommitDelayNanoseconds
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            guard self.archiveCommitTasks[sessionID] != nil else { return }
            self.archiveCommitTasks.removeValue(forKey: sessionID)
            guard let archivedSession = self.archivedSessions.first(where: { $0.id == sessionID }),
                  archivedSession.status.isTerminal
            else {
                pickySessionLog("archive-commit session=\(sessionID) keeping child for non-terminal Pickle")
                return
            }
            self.releaseArchivedTerminalChildIfCommitted(archivedSession)
        }
        archiveCommitTasks[sessionID] = task
    }

    func releaseArchivedTerminalChildIfCommitted(_ session: SessionCard) {
        guard session.status.isTerminal else { return }
        guard archiveCommitTasks[session.id] == nil else { return }
        guard !releasedArchivedChildSessionIDs.contains(session.id) else { return }
        releasedArchivedChildSessionIDs.insert(session.id)
        pickySessionLog("archive-commit session=\(session.id) releasing terminal child")
        childSessionReleaser?.releaseChild(sessionId: session.id)
    }

    func unarchive(sessionID: String) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("unarchive session=\(sessionID)")
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        releasedArchivedChildSessionIDs.remove(sessionID)
        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.remove(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        sendArchiveIntent(sessionID: sessionID, archived: false)

        guard moveSessionProjectionMembership(id: sessionID, archived: false) != nil else { return }
        // Only touch manualOrder if the user has already opted into manual
        // ordering by dragging at least once; otherwise let the historical
        // createdAt sort drive placement.
        if !manualOrder.isEmpty {
            manualOrder.removeAll { $0 == sessionID }
            manualOrder.insert(sessionID, at: 0)
            manualOrderStore.manualOrder = manualOrder
        }
        applyManualOrder()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
    }

    /// Permanently delete every archived Pickle in one shot from the
    /// Settings → Pickle list header. Snapshots the current archived IDs
    /// up-front so concurrent restores/incoming events do not slip a row out
    /// from under the iteration, then funnels each ID through the existing
    /// single-row delete path so daemon validation, archive-store cleanup,
    /// and per-session map pruning all stay consistent. No-op when the
    /// archive is empty so a misrouted call (deep link, test, programmatic)
    /// never sends spurious deleteSession envelopes.
    func deleteAllArchivedSessions() {
        let ids = archivedSessions.map(\.id)
        guard !ids.isEmpty else { return }
        pickySessionLog("delete all archived sessions count=\(ids.count)")
        for sessionID in ids {
            deleteArchivedSession(sessionID: sessionID)
        }
    }

    /// Permanently delete an archived Pickle from both the local view model and the
    /// daemon's persisted session store. Triggered from Settings → Pickle. The
    /// daemon validates that the session is archived AND terminal AND has no live
    /// runtime handle; the UI only exposes the affordance for archived rows so a
    /// successful path is the only path the user ever sees.
    func deleteArchivedSession(sessionID: String) {
        Task { try? await client.send(PickyCommandEnvelope(type: .deleteSession, sessionId: sessionID)) }
        finalizeDeletedArchivedSession(sessionID: sessionID)
    }

    /// Local half of permanent deletion, called directly by Settings or only after
    /// the CLI bridge receives an authoritative child-daemon ack.
    func finalizeDeletedArchivedSession(sessionID: String) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        pickySessionLog("finalize deleted archived session=\(sessionID)")
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        releasedArchivedChildSessionIDs.remove(sessionID)

        var archivedIDs = archiveStore.archivedSessionIDs
        archivedIDs.remove(sessionID)
        archiveStore.archivedSessionIDs = archivedIDs

        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        manuallyArchivedIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs

        // Mirror removeOnboardingDemoSession's cleanup: prune every per-session
        // map so a future incoming sessionUpdated for an unrelated session id
        // doesn't accidentally revive stale state for the deleted one.
        removeSession(id: sessionID)
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys.remove("\(sessionID):completed")
        deliveredNotificationKeys.remove("\(sessionID):failed")
        thinkingBlocksHiddenBySessionID.removeValue(forKey: sessionID)
        todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
        slashCommandController.clear(sessionID: sessionID)
        syncSlashCommands()
        lastIncrementalSeqBySessionID.removeValue(forKey: sessionID)
        pendingTerminalMetaBySessionID.removeValue(forKey: sessionID)
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
            disarmInitialSnapshotWatchdog()
            isLoadingInitialSessionSnapshot = false
        }
    }

    private func clearAuthoritativelyRemovedSessionState(sessionID: String) {
        archiveCommitTasks.removeValue(forKey: sessionID)?.cancel()
        clearPendingArchiveIntent(sessionID: sessionID)
        sessionProjectionRecoveryCoordinator?.remove(sessionID: sessionID)
        archiveStore.archivedSessionIDs.remove(sessionID)
        archiveStore.manuallyArchivedSessionIDs.remove(sessionID)
        releasedArchivedChildSessionIDs.remove(sessionID)
        unreadSessionIDs.remove(sessionID)
        pendingDoneFlashSessionIDs.remove(sessionID)
        deliveredNotificationKeys = deliveredNotificationKeys.filter { !$0.hasPrefix("\(sessionID):") }
        thinkingBlocksHiddenBySessionID.removeValue(forKey: sessionID)
        todoProgressExpandedBySessionID.removeValue(forKey: sessionID)
        subagentInvocationExpandedBySessionID.removeValue(forKey: sessionID)
        slashCommandController.clear(sessionID: sessionID)
        composerDraftController.clearDraft(sessionID: sessionID)
        lastIncrementalSeqBySessionID.removeValue(forKey: sessionID)
        pendingTerminalMetaBySessionID.removeValue(forKey: sessionID)
        pendingDockGroupAssignments.removeValue(forKey: sessionID)
        sessionDiffStoresBySessionID.removeValue(forKey: sessionID)
        visibleSessionDiffSessionIDs.remove(sessionID)
        terminalSessionCommandChains.removeValue(forKey: sessionID)?.cancel()
        terminalSessionCommandChainIDs.removeValue(forKey: sessionID)
        if let handle = terminalOverlayHandlesBySessionID.removeValue(forKey: sessionID) {
            terminalPresenter.closeTerminal(handle: handle)
        }
        removeVisibleInlineTerminalAttachments(sessionID: sessionID)
        invalidatePendingInlineTerminalSync(sessionID: sessionID)
        closeInlineTerminalSession(sessionID: sessionID, schedulesSync: false)
        inlineTerminalSessionIDs.remove(sessionID)
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
    /// and `.disconnected` cases mutate loader state and spawn a `Task` to
    /// send `listSessions`, so this is not a pure reducer; treat it as the
    /// canonical event-application seam, called once per delivered event.
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
            Task {
                pickySessionLog("send listSessions for initial snapshot")
                try? await client.send(PickyCommandEnvelope(type: .listSessions))
            }
        case .disconnected:
            pickySessionLog("client disconnected")
            lastError = "Disconnected from picky-agentd"
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

    /// Routes command-correlated recovery rejections to the per-session
    /// coordinator. Other command errors are ignored by the coordinator.
    func handleSessionProjectionRecoveryFailure(commandID: String?) {
        sessionProjectionRecoveryCoordinator?.receiveRecoveryFailure(commandID: commandID)
    }

    /// Inner reducer for fully-decoded protocol events. Stays private — reducer
    /// tests always go through the `PickyClientEvent.protocolEvent(...)` envelope
    /// (matching the production path), so this entry point has no external
    /// callers and exposing it would only widen the API surface.
    private func apply(_ event: PickyEvent) {
        switch event {
        case .sessionSnapshot(let snapshot):
            applySessionSnapshot(snapshot)
        case .sessionProjectionSnapshot(let snapshot):
            sessionProjectionRecoveryCoordinator?.receive(snapshot: snapshot)
        case .sessionProjectionTransaction(let transaction):
            sessionProjectionRecoveryCoordinator?.receive(transaction: transaction)
        // Completion is consumed at the router boundary with source metadata.
        case .sessionProjectionBootstrapComplete:
            break
        case .sessionUpdated(let session):
            applySessionUpdated(session)
        case .sessionMetaUpdated(let session):
            applySessionMetaUpdated(session)
        case .sessionArchivedAuthoritative(let sessionId, let archived):
            applySessionArchivedAuthoritative(sessionID: sessionId, archived: archived)
        case .sessionLogAppended(let sessionId, let line):
            applySessionLogAppended(sessionID: sessionId, line: line)
        case .toolActivityUpdated(let sessionId, let tool):
            applyToolActivityUpdated(sessionID: sessionId, tool: tool)
        case .sessionTodoStateUpdated(let sessionId, let todoState, let seq):
            applyTodoStateUpdated(sessionID: sessionId, todoState: todoState, seq: seq)
        case .sessionSubagentRunsUpdated(let sessionId, let runs, let seq):
            applySubagentRunsUpdated(sessionID: sessionId, runs: runs, seq: seq)
        case .extensionUiRequest(let request):
            applyExtensionUiRequest(request)
        case .artifactUpdated(let sessionId, let artifact):
            applyArtifactUpdated(sessionID: sessionId, artifact: artifact)
        case .sessionResourcesReloaded(let sessionId):
            PickyPerf.event("vm_event_session_resources_reloaded")
            pickySessionLog("session resources reloaded session=\(sessionId)")
            invalidateSlashCommandCache(sessionID: sessionId, refreshIfPreviouslyRequested: true)
            autocompleteEvents.send(.resourcesReloaded(sessionID: sessionId))
        case .slashCommandsSnapshot(let sessionId, let requestId, let commands):
            applySlashCommandsSnapshot(sessionID: sessionId, requestID: requestId, commands: commands)
        case .autocompleteCapabilitiesSnapshot(let snapshot):
            autocompleteEvents.send(.capabilities(snapshot))
        case .autocompleteSuggestionsSnapshot(let snapshot):
            autocompleteEvents.send(.suggestions(snapshot))
        case .autocompleteCompletionApplied(let completion):
            autocompleteEvents.send(.completion(completion))
        case .rewindTargetsSnapshot: break
        case .sessionDiffResult(let result):
            applySessionDiffResult(result)
        case .sessionRewound(let sessionId, let editorText, _): applySessionRewound(sessionID: sessionId, editorText: editorText)
        case .sessionMessageAppended(let sessionId, let message, let seq):
            applySessionMessageAppended(sessionID: sessionId, message: message, seq: seq)
        case .sessionMessagesImported(let sessionId, let messages, let seq):
            applySessionMessagesImported(sessionID: sessionId, messages: messages, seq: seq)
        case .sessionMessageReplaced(let sessionId, let messageId, let message, let seq):
            applySessionMessageReplaced(sessionID: sessionId, messageID: messageId, message: message, seq: seq)
        case .sessionMessageRemoved(let sessionId, let messageId, let seq):
            applySessionMessageRemoved(sessionID: sessionId, messageID: messageId, seq: seq)
        case .sessionQueueUpdated(let sessionId, let steering, let followUp, let steeringMode, let followUpMode, let seq):
            applySessionQueueUpdated(sessionID: sessionId, steering: steering, followUp: followUp, steeringMode: steeringMode, followUpMode: followUpMode, seq: seq)
        case .sessionActivityUpdated(let sessionId, let activitySummary, let seq):
            applySessionActivityUpdated(sessionID: sessionId, activitySummary: activitySummary, seq: seq)
        case .error(let error):
            pickySessionLog("protocol error code=\(error.code) command=\(error.commandId ?? "none")")
            lastError = error.message
            handleSessionProjectionRecoveryFailure(commandID: error.commandId)
            handleArchiveIntentFailure(commandID: error.commandId)
        case .terminalSessionSyncOutcome(let outcome):
            applyTerminalSessionSyncOutcome(outcome)
        case .externalEntryAccepted(let accepted):
            if let sessionID = accepted.sessionId, let groupName = accepted.group {
                assignSessionToDockGroup(sessionID: sessionID, groupName: groupName)
            }
        case .quickReply, .mainTurnSettled, .mainNarrationChunk,
             .mainVisualNarrationSegmentPrepared, .mainVisualNarrationSegmentSentence, .mainVisualNarrationSegmentCommitted,
             .mainMessagesSnapshot, .mainMessageAppended, .mainActivityUpdated, .mainExtensionUiRequested, .mainExtensionUiCancelled,
             .mainAgentSessionInfoUpdated, .mainAgentModelsSnapshot,
             .piOAuthStatus, .piOAuthUrlRequested, .piOAuthPromptRequested, .piAuthenticationReloaded,
             .pointerOverlayRequested, .annotationOverlayRequested, .pickleHandoffRequested, .pickleBridgeRequested, .externalEntryRequested,
             .dockGroupsRequested, .pushToTalkControlRequested, .pickySettingsRequested, .hello, .pluginsReloaded,
             .packageUpdatesAvailable, .packageOperationProgress, .packageOperationCompleted, .ack, .unknown:
            break
        }
    }

    // MARK: - Protocol event handlers
    private func applySessionSnapshot(_ snapshot: PickySessionSnapshot) {
        PickyPerf.event("vm_event_session_snapshot")
        let elapsedSinceConnectedMs = lastConnectedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        pickySessionLog("snapshot sessions=\(snapshot.sessions.count) complete=\(snapshot.isComplete) skipped=\(snapshot.skippedSessionCount) elapsedSinceConnectedMs=\(elapsedSinceConnectedMs)")
        disarmInitialSnapshotWatchdog()
        isLoadingInitialSessionSnapshot = false
        let previousCardsByID = Dictionary(uniqueKeysWithValues: (sessions + archivedSessions).map { ($0.id, $0) })

        // Retain the input order for valid daemon records while deduplicating
        // defensively. A partial snapshot then appends only cards that failed
        // to decode, preserving their last known local projection without
        // allowing a duplicate session ID into either HUD list.
        var incomingCardsByID: [String: SessionCard] = [:]
        var incomingCardIDs: [String] = []
        for session in snapshot.sessions {
            let card = SessionCard.fromAgentSession(session)
            if incomingCardsByID[card.id] == nil {
                incomingCardIDs.append(card.id)
            }
            incomingCardsByID[card.id] = card
        }
        let incomingCards = incomingCardIDs.compactMap { incomingCardsByID[$0] }
        let cards: [SessionCard]
        if snapshot.isComplete {
            cards = incomingCards
        } else {
            let retainedCards = previousCardsByID.values.filter { incomingCardsByID[$0.id] == nil }
            cards = incomingCards + retainedCards
        }

        // Only a complete snapshot is authoritative for archive reconciliation.
        // A partial snapshot may be missing an undecodable session, so it may
        // add a valid daemon archive flag but must not remove existing IDs.
        if snapshot.isComplete, !cards.isEmpty {
            let daemonArchivedIDs = Set(cards.filter(\.archived).map(\.id))
            let universe = Set(cards.map(\.id))
            let reconciled = archiveStore.manuallyArchivedSessionIDs
                .union(daemonArchivedIDs)
                .intersection(universe)
            if reconciled != archiveStore.manuallyArchivedSessionIDs {
                archiveStore.manuallyArchivedSessionIDs = reconciled
            }
        } else if !snapshot.isComplete, !incomingCards.isEmpty {
            let daemonArchivedIDs = Set(incomingCards.filter(\.archived).map(\.id))
            let reconciled = archiveStore.manuallyArchivedSessionIDs.union(daemonArchivedIDs)
            if reconciled != archiveStore.manuallyArchivedSessionIDs {
                archiveStore.manuallyArchivedSessionIDs = reconciled
            }
        }
        let archivedIDs = effectiveArchivedSessionIDs(for: cards)
        // Every snapshot begins a new daemon incremental-event epoch. Even a
        // partial snapshot may follow an agentd restart, whose counters start
        // at one; retained undecodable cards must accept those new events.
        lastIncrementalSeqBySessionID.removeAll()
        for card in cards {
            reconcileTodoProgressExpansion(
                sessionID: card.id,
                previousState: previousCardsByID[card.id]?.todoState,
                currentState: card.todoState
            )
            reconcileSubagentInvocationExpansion(
                sessionID: card.id,
                messages: card.messages,
                previousRuns: previousCardsByID[card.id]?.subagentRuns ?? [],
                currentRuns: card.subagentRuns
            )
        }
        PickyPerf.interval("vm_snapshot_publish_session_lists") {
            replaceAllSessions(
                active: cards.filter { !archivedIDs.contains($0.id) },
                archived: cards.filter { archivedIDs.contains($0.id) }.sortedForHUD()
            )
        }
        PickyPerf.interval("vm_snapshot_apply_manual_order") {
            applyManualOrder()
        }
        for card in cards {
            applyPendingTerminalMetaIfNeeded(for: card.id)
        }
        for card in cards {
            PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
            PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        }
        if snapshot.isComplete {
            pruneSlashCommandCache(knownSessionIDs: Set(cards.map(\.id)))
        } else {
            // Missing IDs in a partial snapshot are not evidence that their
            // drafts, terminal state, unread badges, or command caches are stale.
            // Keep all local state until a complete snapshot reconciles it.
            syncSlashCommands()
        }
        syncThinkingBlockVisibility()
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
        for card in sessions {
            if previousCardsByID[card.id] == nil {
                markNotificationDeliveredIfNeeded(for: card)
            } else {
                deliverNotificationIfNeeded(for: card)
            }
        }
    }

    private func applySessionUpdated(_ session: PickyAgentSession) {
        PickyPerf.event("vm_event_session_updated")
        pickySessionLog("session updated session=\(session.id) status=\(session.status.rawValue)")
        let incomingCard = PickyPerf.interval("vm_session_from_agent_session") {
            SessionCard.fromAgentSession(session)
        }
        let previousCard = (sessions + archivedSessions).first { $0.id == session.id }
        reconcileTodoProgressExpansion(
            sessionID: session.id,
            previousState: previousCard?.todoState,
            currentState: incomingCard.todoState
        )
        reconcileSubagentInvocationExpansion(
            sessionID: session.id,
            messages: incomingCard.messages,
            previousRuns: previousCard?.subagentRuns ?? [],
            currentRuns: incomingCard.subagentRuns
        )
        if shouldInvalidateSlashCommandCache(previous: previousCard, incoming: incomingCard) {
            invalidateSlashCommandCache(sessionID: session.id)
        }
        PickyPerf.interval("vm_event_session_updated_upsert") {
            upsert(
                incomingCard,
                preserveIncrementalConversationState: lastIncrementalSeqBySessionID[session.id] != nil
            )
        }
        applyPendingTerminalMetaIfNeeded(for: session.id)
        if visibleSessionDiffSessionIDs.contains(session.id),
           PickySessionDiffPresentation.isSettledTransition(from: previousCard?.status, to: incomingCard.status) {
            requestSessionDiff(sessionID: session.id)
        }
    }

    private func applySessionDiffResult(_ result: PickySessionDiffResult) {
        guard let store = sessionDiffStoresBySessionID[result.sessionId] else { return }
        let next = PickySessionDiffState.reducing(current: store.state, result: result)
        store.replace(next)
    }

    private func applySessionArchivedAuthoritative(sessionID sessionId: String, archived: Bool) {
        PickyPerf.event("vm_event_session_archived_authoritative")
        // agentd has issued an authoritative archive-state change (either
        // from a client setSessionArchived command, or from the
        // picky_unarchive_pickle tool). Mirror it into the local
        // manuallyArchivedSessionIDs set — the only thing upsert() looks
        // at when deciding dock placement — and then re-upsert the card
        // so the dock actually moves. We do this here rather than on
        // plain sessionUpdated to avoid the long-standing
        // mid-flight unarchive flicker race.
        pickySessionLog("session archived authoritative session=\(sessionId) archived=\(archived)")
        if pendingArchiveIntentBySessionID[sessionId] == archived {
            clearPendingArchiveIntent(sessionID: sessionId)
        }
        var archivedIDs = archiveStore.archivedSessionIDs
        var manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        if archived {
            if archivedIDs.insert(sessionId).inserted { archiveStore.archivedSessionIDs = archivedIDs }
            if manuallyArchivedIDs.insert(sessionId).inserted { archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs }
        } else {
            if archivedIDs.remove(sessionId) != nil { archiveStore.archivedSessionIDs = archivedIDs }
            if manuallyArchivedIDs.remove(sessionId) != nil { archiveStore.manuallyArchivedSessionIDs = manuallyArchivedIDs }
        }
        // Re-place the card by feeding the cached snapshot back through
        // upsert with its archived field updated to match. If we have no
        // record of the session yet, drop the signal — the next regular
        // sessionUpdated will hydrate it with the authoritative flag.
        if let existing = (sessions + archivedSessions).first(where: { $0.id == sessionId }) {
            var refreshed = existing
            refreshed.archived = archived
            upsert(refreshed, preserveIncrementalConversationState: true)
        }
    }

    private func applySessionLogAppended(sessionID sessionId: String, line: String) {
        PickyPerf.event("vm_event_session_log_appended")
        pickySessionLog("session log session=\(sessionId) lineChars=\(line.count)")
        if SessionCard.piSessionFilePath(fromLogLine: line) != nil || SessionCard.isRuntimeReattachLogLine(line) {
            invalidateSlashCommandCache(sessionID: sessionId)
        }
        mutateSession(sessionID: sessionId) { card in
            if SessionCard.isDisplayableLogPreview(line) {
                card.logPreview = line
            }
            if SessionCard.isMainAgentHandoffLogLine(line) {
                card.isMainAgentHandoff = true
            }
            if let piSessionFilePath = SessionCard.piSessionFilePath(fromLogLine: line) {
                card.piSessionFilePath = piSessionFilePath
            }
            if let requestText = SessionCard.requestText(fromLogLine: line) {
                card.lastRequestText = requestText
                // Log lines arrive when the daemon broadcasts them, which is essentially
                // when the request was issued — Date() here is close enough to the real
                // wall-clock time of the request to drive the REQUEST row's stamp.
                card.lastRequestAt = Date()
            }
            if SessionCard.isRuntimeDetachedFollowUpRejection(line) {
                card.hasRuntimeDetachedFollowUpRejection = true
            }
            card.updatedAt = Date()
        }
    }

    private func applyToolActivityUpdated(sessionID sessionId: String, tool: PickyToolActivity) {
        PickyPerf.event("vm_event_tool_activity_updated")
        mutateSession(sessionID: sessionId) { card in
            if let toolIndex = card.tools.firstIndex(where: { $0.toolCallId == tool.toolCallId }) {
                card.tools[toolIndex] = tool
            } else {
                card.tools.append(tool)
            }
            card.logPreview = [tool.name, tool.preview].compactMap { $0 }.joined(separator: ": ")
            card.updatedAt = tool.endedAt ?? Date()
        }
    }

    private func applyTodoStateUpdated(sessionID sessionId: String, todoState: PickyTodoState?, seq: Int) {
        PickyPerf.event("vm_event_todo_state_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        reconcileTodoProgressExpansion(
            sessionID: sessionId,
            previousState: card(sessionID: sessionId)?.todoState,
            currentState: todoState
        )
        mutateSession(sessionID: sessionId) { card in
            card.todoState = todoState
            card.updatedAt = todoState?.updatedAt ?? Date()
        }
    }

    private func applySubagentRunsUpdated(sessionID sessionId: String, runs: [PickySubagentRun], seq: Int) {
        PickyPerf.event("vm_event_subagent_runs_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        reconcileSubagentInvocationExpansion(
            sessionID: sessionId,
            messages: card(sessionID: sessionId)?.messages ?? [],
            previousRuns: card(sessionID: sessionId)?.subagentRuns ?? [],
            currentRuns: runs
        )
        mutateSession(sessionID: sessionId) { card in
            card.subagentRuns = runs
            card.updatedAt = Date()
        }
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

    private func applyArtifactUpdated(sessionID sessionId: String, artifact: PickyArtifact) {
        PickyPerf.event("vm_event_artifact_updated")
        pickySessionLog("artifact updated session=\(sessionId) artifact=\(artifact.id) kind=\(artifact.kind)")
        mutateSession(sessionID: sessionId) { card in
            if let index = card.artifacts.firstIndex(where: { $0.id == artifact.id }) {
                card.artifacts[index] = artifact
            } else {
                card.artifacts.append(artifact)
            }
            card.updatedAt = artifact.updatedAt
        }
    }

    private func applySlashCommandsSnapshot(sessionID sessionId: String, requestID requestId: String?, commands: [PickySlashCommand]) {
        PickyPerf.event("vm_event_slash_commands_snapshot")
        slashCommandController.applySnapshot(sessionID: sessionId, requestID: requestId, commands: commands)
        syncSlashCommands()
    }

    private func applySessionMessageAppended(sessionID sessionId: String, message: PickySessionMessage, seq: Int) {
        PickyPerf.event("vm_event_session_message_appended")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        mutateSession(sessionID: sessionId) { card in
            card.messages.append(message)
            card.updatedAt = max(card.updatedAt, message.createdAt)
        }
    }

    private func applySessionMessagesImported(sessionID sessionId: String, messages: [PickySessionMessage], seq: Int) {
        PickyPerf.event("vm_event_session_messages_imported")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        var appendedMessages: [PickySessionMessage] = []
        mutateSession(sessionID: sessionId) { card in
            let existingIDs = Set(card.messages.map(\.id))
            appendedMessages = messages.filter { !existingIDs.contains($0.id) }
            guard !appendedMessages.isEmpty else { return }
            card.messages.append(contentsOf: appendedMessages)
            if let latestCreatedAt = appendedMessages.map(\.createdAt).max() {
                card.updatedAt = max(card.updatedAt, latestCreatedAt)
            }
        }
    }

    private func applySessionMessageReplaced(sessionID sessionId: String, messageID messageId: String, message: PickySessionMessage, seq: Int) {
        PickyPerf.event("vm_event_session_message_replaced")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        mutateSession(sessionID: sessionId) { card in
            if let index = card.messages.firstIndex(where: { $0.id == messageId }) {
                card.messages[index] = message
            } else {
                card.messages.append(message)
            }
            card.updatedAt = max(card.updatedAt, message.createdAt)
        }
    }

    private func applySessionMessageRemoved(sessionID sessionId: String, messageID messageId: String, seq: Int) {
        PickyPerf.event("vm_event_session_message_removed")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        mutateSession(sessionID: sessionId) { card in
            card.messages.removeAll { $0.id == messageId }
            card.updatedAt = Date()
        }
    }

    private func applySessionQueueUpdated(sessionID sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int) {
        PickyPerf.event("vm_event_session_queue_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        mutateSession(sessionID: sessionId) { card in
            card.queuedSteers = steering
            card.queuedFollowUps = followUp
            if let steeringMode { card.steeringMode = steeringMode }
            if let followUpMode { card.followUpMode = followUpMode }
            card.updatedAt = Date()
        }
    }

    private func applySessionActivityUpdated(sessionID sessionId: String, activitySummary: PickyActivitySummary, seq: Int) {
        PickyPerf.event("vm_event_session_activity_updated")
        guard acceptIncrementalEvent(sessionID: sessionId, seq: seq) else { return }
        mutateSession(sessionID: sessionId) { card in
            card.activitySummary = activitySummary
            card.updatedAt = Date()
        }
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
            syncComposerDraftRequests()
            return true
        case "notify", "setStatus", "setWidget", "setTitle":
            return true
        default:
            return false
        }
    }

    private func acceptIncrementalEvent(sessionID: String, seq: Int) -> Bool {
        let lastSeq = lastIncrementalSeqBySessionID[sessionID] ?? 0
        guard seq > lastSeq else { return false }
        lastIncrementalSeqBySessionID[sessionID] = seq
        return true
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
        syncComposerDraftRequests()
        thinkingBlocksHiddenBySessionID = thinkingBlocksHiddenBySessionID.filter { knownSessionIDs.contains($0.key) }
        todoProgressExpandedBySessionID = todoProgressExpandedBySessionID.filter { knownSessionIDs.contains($0.key) }
        subagentInvocationExpandedBySessionID = subagentInvocationExpandedBySessionID.filter { knownSessionIDs.contains($0.key) }
        pendingDoneFlashSessionIDs = pendingDoneFlashSessionIDs.filter { knownSessionIDs.contains($0) }
        unreadSessionIDs = unreadSessionIDs.filter { knownSessionIDs.contains($0) }
        releasedArchivedChildSessionIDs = releasedArchivedChildSessionIDs.filter { knownSessionIDs.contains($0) }
        lastIncrementalSeqBySessionID = lastIncrementalSeqBySessionID.filter { knownSessionIDs.contains($0.key) }
        pendingTerminalMetaBySessionID = pendingTerminalMetaBySessionID.filter { knownSessionIDs.contains($0.key) }
        sessionDiffStoresBySessionID = sessionDiffStoresBySessionID.filter { knownSessionIDs.contains($0.key) }
        let removedInlineTerminalIDs = inlineTerminalSessionIDs.subtracting(knownSessionIDs)
        inlineTerminalSessionIDs = inlineTerminalSessionIDs.filter { knownSessionIDs.contains($0) }
        for sessionID in removedInlineTerminalIDs {
            removeVisibleInlineTerminalAttachments(sessionID: sessionID)
            closeInlineTerminalSession(sessionID: sessionID)
        }
        let removedShellTerminalIDs = Set(shellTerminalSessionsBySessionID.keys).subtracting(knownSessionIDs)
        for sessionID in removedShellTerminalIDs {
            closeShellTerminalSession(sessionID: sessionID)
        }
        if let screenContextTargetSessionID, !knownSessionIDs.contains(screenContextTargetSessionID) {
            clearScreenContextTarget(sessionID: screenContextTargetSessionID)
        }
    }

    private func syncThinkingBlockVisibility() {
        thinkingBlocksHiddenBySessionID = Dictionary(uniqueKeysWithValues: (sessions + archivedSessions).map { session in
            (session.id, PickyPiSettingsReader.hideThinkingBlock(cwd: session.cwd))
        })
    }

    private func effectiveArchivedSessionIDs(for _: [SessionCard]) -> Set<String> {
        let manuallyArchivedIDs = archiveStore.manuallyArchivedSessionIDs
        if archiveStore.archivedSessionIDs != manuallyArchivedIDs {
            archiveStore.archivedSessionIDs = manuallyArchivedIDs
        }
        return manuallyArchivedIDs
    }

    func upsert(_ card: SessionCard, preserveIncrementalConversationState: Bool = false) {
        PickyPerf.event("vm_upsert_called")
        let archivedIDs = effectiveArchivedSessionIDs(for: [card])
        let shouldArchive = archivedIDs.contains(card.id)
        let previousStatus = (sessions + archivedSessions).first(where: { $0.id == card.id })?.status
        PickyPerf.interval("vm_upsert_prefetch_enqueue") {
            PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
            PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        }
        var incoming = card
        PickyPerf.interval("vm_upsert_merge_existing") {
            if let existing = (sessions + archivedSessions).first(where: { $0.id == card.id }) {
                incoming = existing.merged(with: card, preserveConversationState: preserveIncrementalConversationState)
            }
        }

        upsertSession(incoming, archived: shouldArchive)
        PickyPerf.interval("vm_upsert_apply_manual_order") {
            applyManualOrder()
        }
        PickyPerf.interval("vm_upsert_publish_thinking_visibility") {
            thinkingBlocksHiddenBySessionID[incoming.id] = PickyPiSettingsReader.hideThinkingBlock(cwd: incoming.cwd)
        }
        PickyPerf.interval("vm_upsert_sync_selection_state") {
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            syncScreenContextTargetAfterSessionListChange()
            syncActiveVoiceFollowUpAfterSessionListChange()
        }
        if shouldArchive {
            // Archived sessions are out of the dock surface; suppress unread badge.
            PickyPerf.interval("vm_upsert_publish_archive_badges") {
                unreadSessionIDs.remove(incoming.id)
            }
            releaseArchivedTerminalChildIfCommitted(incoming)
        } else {
            releasedArchivedChildSessionIDs.remove(incoming.id)
            PickyPerf.interval("vm_upsert_publish_completion_badges") {
                requestDoneFlashIfNeeded(previousStatus: previousStatus, incoming: incoming)
                updateUnreadStateIfNeeded(previousStatus: previousStatus, incoming: incoming)
            }
            deliverNotificationIfNeeded(for: incoming)
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

    private func replaceAllSessions(active: [SessionCard], archived: [SessionCard]) { sessionProjectionStorage.replaceAllSessions(active: active, archived: archived) }
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

    private func upsertSession(_ card: SessionCard, archived: Bool) {
        sessionProjectionStorage.upsertSession(card, archived: archived)
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
        var order = manualOrder
        let activeIDs = Set(sessions.map(\.id))
        let archivedIDs = Set(archivedSessions.map(\.id))
        let universe = activeIDs.union(archivedIDs)
        order.removeAll { !universe.contains($0) }

        let knownIDs = Set(order)
        let missingActiveIDs = sessions
            .filter { !knownIDs.contains($0.id) }
            .sortedForHUD() // newest first
            .map(\.id)
        if !missingActiveIDs.isEmpty {
            // Preserve newest-first batch order at the visually-end slot.
            order.insert(contentsOf: missingActiveIDs, at: 0)
        }

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

        // Visible space is `sessions.reversed()`. Underlying sessions-index =
        // (N - 1) - visibleIndex.
        guard let underlyingCurrent = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let visibleCurrent = (visibleCount - 1) - underlyingCurrent
        let visibleTarget = max(0, min(visibleCount - 1, visibleTargetRaw))
        guard visibleCurrent != visibleTarget else { return false }
        let underlyingTarget = (visibleCount - 1) - visibleTarget

        // Ensure every active session id is present in manualOrder before the
        // move. Otherwise inserting the dragged id by "active-count" index
        // would skip over the newcomer entries that have not been synced yet.
        seedManualOrderIfNeeded()
        applyManualOrder()
        var order = manualOrder
        guard let fromOrderIdx = order.firstIndex(of: sessionID) else { return false }
        order.remove(at: fromOrderIdx)

        // Translate the active-sessions target index into a manualOrder index
        // by counting active ids encountered. manualOrder may interleave
        // archived ids (so unarchive restores the user's slot), so a direct
        // index match would land in the wrong place when those gaps exist.
        let activeIDs = Set(sessions.map(\.id)).subtracting([sessionID])
        var activeSeen = 0
        var insertIdx = order.count
        for (idx, id) in order.enumerated() {
            if activeSeen == underlyingTarget {
                insertIdx = idx
                break
            }
            if activeIDs.contains(id) {
                activeSeen += 1
            }
        }
        order.insert(sessionID, at: insertIdx)

        manualOrder = order
        manualOrderStore.manualOrder = order
        applyManualOrder(order)
        return true
    }

    func syncSelectionAfterSessionListChange(skippingRedundantPublishedAssignments: Bool = false) {
        if hasExplicitSelection, let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            selectionStore.selectedSessionID = selectedSessionID
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
            for: notificationInput(for: session),
            preferences: notificationPreferencesProvider.notificationPreferences
        )
    }

    private func notificationInput(for session: SessionCard) -> PickySessionNotificationPolicy.Input {
        let pendingRequest = session.pendingExtensionUiRequest.map {
            PickySessionNotificationPolicy.Input.PendingRequest(
                id: $0.id,
                title: $0.title,
                prompt: $0.prompt
            )
        }
        return PickySessionNotificationPolicy.Input(
            sessionID: session.id,
            title: session.title,
            status: session.status,
            lastSummary: session.lastSummary,
            pendingRequest: pendingRequest,
            pinned: session.pinned
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
