//
//  PickySessionViewModelTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

// Project root derived from this test file's location:
// <repo>/PickyTests/PickySessionViewModelTests.swift -> <repo>.
private let testProjectCwd: String = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path

private final class FakePickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    // `submitted` / `sentCommands` are mutated from `submit`/`send` (non-isolated
    // `async` protocol methods run on the cooperative pool) and read from the
    // tests' MainActor `wait { … }` / `#expect`. Without serializing, that's a
    // data race on Array<…> storage — reproducible as the
    // `slashCommandResourcesReloadedBumpsEpochAndReRequestsOnlyPreviouslyRequestedSession`
    // flake under heavy parallel xcodebuild load, where the reader sees stale
    // count/last and the next `#expect(count == 2)` fails. Hopping the append
    // onto MainActor.run gives both sides a single serialization point so the
    // observable buffer is always consistent with what the production code has
    // sent so far.
    @MainActor private(set) var submitted: [PickyAgentSubmission] = []
    @MainActor private(set) var sentCommands: [PickyCommandEnvelope] = []
    var beforeSend: ((PickyCommandEnvelope) async -> Void)?

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        await MainActor.run { submitted.append(submission) }
        return PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        if let beforeSend {
            await beforeSend(command)
        }
        await MainActor.run { sentCommands.append(command) }
    }
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

private final class FakeManualPickleChildSpawner: PickyManualPickleChildSpawning {
    struct Call: Equatable {
        let sessionId: String
        let cwd: String
    }

    private(set) var calls: [Call] = []
    let childClient = FakePickyAgentClient()

    func spawnManualPickleChildClient(sessionId: String, cwd: String) async throws -> any PickyAgentClient {
        calls.append(Call(sessionId: sessionId, cwd: cwd))
        return childClient
    }
}

private final class FakeRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    private(set) var recorded: [String] = []
    private(set) var removed: [String] = []
    var recentPickleCwds: [String]

    init(recentPickleCwds: [String] = []) {
        self.recentPickleCwds = recentPickleCwds
    }

    func record(cwd: String) throws -> [String] {
        recorded.append(cwd)
        recentPickleCwds.removeAll { $0 == cwd }
        recentPickleCwds.insert(cwd, at: 0)
        return recentPickleCwds
    }

    func remove(cwd: String) throws -> [String] {
        removed.append(cwd)
        recentPickleCwds.removeAll { $0 == cwd }
        return recentPickleCwds
    }
}

private final class FakeSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky: Bool = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
}

private final class FakeArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
}

private final class FakeManualOrderStore: PickySessionManualOrderStoring {
    var manualOrder: [String] = []
}

private final class FakeViewModelDockLayoutStore: PickyDockLayoutStoring {
    private var storedLayout: PickyDockLayout
    private(set) var savedLayouts: [PickyDockLayout] = []

    init(layout: PickyDockLayout = .empty) {
        self.storedLayout = layout
    }

    func load() -> PickyDockLayout {
        storedLayout
    }

    func save(_ layout: PickyDockLayout) throws {
        storedLayout = layout
        savedLayouts.append(layout)
    }
}

private extension PickyDockLayout {
    var testSessionIDs: [String] {
        entries.flatMap { entry -> [String] in
            switch entry {
            case .session(let id): [id]
            case .group(let group): group.memberSessionIDs
            }
        }
    }

    var testEntryDescriptions: [String] {
        entries.map { entry in
            switch entry {
            case .session(let id): "session:\(id)"
            case .group(let group):
                "group:\(group.id)[\(group.memberSessionIDs.joined(separator: ","))]"
            }
        }
    }
}

@MainActor
private final class FakeChildSessionReleaser: PickyChildSessionReleasing {
    var releasedSessionIDs: [String] = []
    func releaseChild(sessionId: String) {
        releasedSessionIDs.append(sessionId)
    }
}

private final class FakeComposerDraftStore: PickyComposerDraftStoring {
    var drafts: [String: String] = [:]
    var prunedKnownSessionIDs: Set<String>?

    func draft(for sessionID: String) -> String? {
        drafts[sessionID]
    }

    func setDraft(_ draft: String?, for sessionID: String) {
        if let draft, !draft.isEmpty {
            drafts[sessionID] = draft
        } else {
            drafts.removeValue(forKey: sessionID)
        }
    }

    func prune(knownSessionIDs: Set<String>) {
        prunedKnownSessionIDs = knownSessionIDs
        drafts = drafts.filter { knownSessionIDs.contains($0.key) }
    }
}

private final class FakeComposerAttachmentDraftStore: PickyComposerAttachmentDraftStoring {
    var attachments: [String: [String]] = [:]
    var prunedKnownSessionIDs: Set<String>?

    func attachmentPaths(for sessionID: String) -> [String] {
        attachments[sessionID] ?? []
    }

    func setAttachmentPaths(_ paths: [String], for sessionID: String) {
        if paths.isEmpty {
            attachments.removeValue(forKey: sessionID)
        } else {
            attachments[sessionID] = paths
        }
    }

    func prune(knownSessionIDs: Set<String>) {
        prunedKnownSessionIDs = knownSessionIDs
        attachments = attachments.filter { knownSessionIDs.contains($0.key) }
    }
}

private final class FakeClipboardWriter: PickyClipboardWriting {
    private(set) var copied: [String] = []

    func copy(_ text: String) {
        copied.append(text)
    }
}

private final class FakeTerminalOverlayPresenter: PickyTerminalOverlayPresenting {
    struct Call: Equatable {
        let sessionID: String
        let title: String
        let sessionFilePath: String
        let cwd: String?
    }

    private(set) var calls: [Call] = []
    private var closeHandlers: [String: @MainActor () -> Void] = [:]
    var error: Error?

    func openTerminal(
        sessionID: String,
        title: String,
        sessionFilePath: String,
        cwd: String?,
        onClose: @escaping @MainActor () -> Void
    ) throws {
        if let error { throw error }
        calls.append(Call(sessionID: sessionID, title: title, sessionFilePath: sessionFilePath, cwd: cwd))
        closeHandlers[sessionID] = onClose
    }

    func close(sessionID: String) {
        closeHandlers[sessionID]?()
    }
}

private final class FakeReportPresenter: PickyReportPresenting {
    struct Call: Equatable {
        let sessionID: String
        let title: String
        let fileURL: URL
        let markdown: String
    }

    private(set) var calls: [Call] = []
    var error: Error?

    func openReport(sessionID: String, title: String, fileURL: URL, markdown: String) throws {
        if let error { throw error }
        calls.append(Call(sessionID: sessionID, title: title, fileURL: fileURL, markdown: markdown))
    }
}

private final class FakeTerminalSessionSyncer: PickyTerminalSessionSyncing {
    var snapshots: [String: PickyTerminalSessionSnapshot] = [:]
    var snapshotSequences: [String: [PickyTerminalSessionSnapshot]] = [:]
    private(set) var paths: [String] = []

    func snapshot(sessionFilePath: String) throws -> PickyTerminalSessionSnapshot {
        paths.append(sessionFilePath)
        if var sequence = snapshotSequences[sessionFilePath], !sequence.isEmpty {
            let snapshot = sequence.removeFirst()
            snapshotSequences[sessionFilePath] = sequence
            return snapshot
        }
        return snapshots[sessionFilePath] ?? PickyTerminalSessionSnapshot()
    }
}

private final class FirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@Suite(.serialized)
@MainActor
struct PickySessionViewModelTests {
    @Test func startRequestsPersistedSessionsOnConnect() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        try await waitForCommand(.listSessions, in: client)
    }

    @MainActor @Test func hidesDockUntilInitialSessionSnapshotArrives() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        // Initially the dock loader is on because nothing has arrived yet.
        #expect(viewModel.isLoadingInitialSessionSnapshot)

        // Drive the production .connected path so the initial-snapshot watchdog
        // is armed exactly like a real WebSocket attach. Skipping this would
        // make the test pass even if .connected stopped arming the watchdog.
        viewModel.apply(.connected)
        #expect(viewModel.isLoadingInitialSessionSnapshot)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: #"""
        {"id":"snapshot-empty","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:10.000Z","type":"sessionSnapshot","sessions":[]}
        """#)))

        #expect(viewModel.isLoadingInitialSessionSnapshot == false)
    }

    @Test func createEmptyPickleSessionSendsSystemContextWithSelectedCwd() async throws {
        let client = FakePickyAgentClient()
        let childSpawner = FakeManualPickleChildSpawner()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            manualPickleChildSpawner: childSpawner
        )

        let sessionID = try await viewModel.createEmptyPickleSession(cwd: "  /tmp/manual-project  ")

        #expect(sessionID.hasPrefix("session-"))
        #expect(client.sentCommands.isEmpty)
        #expect(childSpawner.childClient.sentCommands.count == 1)
        let command = try #require(childSpawner.childClient.sentCommands.first)
        #expect(command.type == .createEmptyPickleSession)
        #expect(command.context?.source == "system")
        #expect(command.context?.cwd == "/tmp/manual-project")
        #expect(command.context?.transcript == nil)
        #expect(command.context?.screenshots.isEmpty == true)
        #expect(command.context?.warnings == ["manualPickle=true"])
    }

    @Test func createEmptyPickleSessionAlwaysSpawnsChild() async throws {
        let primaryClient = FakePickyAgentClient()
        let childSpawner = FakeManualPickleChildSpawner()
        let viewModel = PickySessionListViewModel(
            client: primaryClient,
            notificationCenter: PickyNoopNotificationCenter(),
            manualPickleChildSpawner: childSpawner,
            manualPickleSessionIdFactory: { "manual-pickle-1" }
        )

        let sessionID = try await viewModel.createEmptyPickleSession(cwd: "  /tmp/manual-project  ")

        #expect(sessionID == "manual-pickle-1")
        #expect(primaryClient.sentCommands.isEmpty)
        #expect(childSpawner.calls == [FakeManualPickleChildSpawner.Call(sessionId: "manual-pickle-1", cwd: "/tmp/manual-project")])
        #expect(childSpawner.childClient.sentCommands.count == 1)
        let command = try #require(childSpawner.childClient.sentCommands.first)
        #expect(command.type == .createEmptyPickleSession)
        #expect(command.context?.source == "system")
        #expect(command.context?.cwd == "/tmp/manual-project")
        #expect(command.context?.transcript == nil)
        #expect(command.context?.screenshots.isEmpty == true)
        #expect(command.context?.warnings == ["manualPickle=true"])
    }

    @Test func createEmptyPickleSessionRecordsSuccessfulManualCwd() async throws {
        let recentStore = FakeRecentPickleFolderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            recentPickleFolderStore: recentStore,
            manualPickleChildSpawner: FakeManualPickleChildSpawner()
        )

        _ = try await viewModel.createEmptyPickleSession(cwd: "  /tmp/manual-project  ")

        #expect(recentStore.recorded == ["/tmp/manual-project"])
        #expect(viewModel.recentPickleCwds == ["/tmp/manual-project"])
    }

    @Test func createEmptyPickleSessionDoesNotRecordCwdWhenSpawnFails() async throws {
        let recentStore = FakeRecentPickleFolderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            recentPickleFolderStore: recentStore
        )

        await #expect(throws: PickySessionListViewModelError.pickleRuntimeUnavailable) {
            _ = try await viewModel.createEmptyPickleSession(cwd: "/tmp/manual-project")
        }
        #expect(recentStore.recorded.isEmpty)
        #expect(viewModel.recentPickleCwds.isEmpty)
    }

    @Test func removeRecentPickleFolderUpdatesStoreBackedList() {
        let recentStore = FakeRecentPickleFolderStore(recentPickleCwds: ["/tmp/picky", "/tmp/old"])
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            recentPickleFolderStore: recentStore
        )

        viewModel.removeRecentPickleFolder("/tmp/picky")

        #expect(recentStore.removed == ["/tmp/picky"])
        #expect(viewModel.recentPickleCwds == ["/tmp/old"])
    }

    @Test func recentPickleCwdsNormalizeDedupeAndCapStoredPaths() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)

        settings.recentPickleCwds = [
            " /tmp/p1 ", "/tmp/p1", "/tmp/p2", "/tmp/p3", "/tmp/p4",
            "/tmp/p5", "/tmp/p6", "/tmp/p7", "/tmp/p8", "/tmp/p9"
        ]
        settings = settings.normalizedPaths()

        #expect(settings.recentPickleCwds == ["/tmp/p1", "/tmp/p2", "/tmp/p3", "/tmp/p4", "/tmp/p5", "/tmp/p6", "/tmp/p7", "/tmp/p8"])

        settings.recordRecentPickleCwd("/tmp/p5")
        #expect(settings.recentPickleCwds == ["/tmp/p5", "/tmp/p1", "/tmp/p2", "/tmp/p3", "/tmp/p4", "/tmp/p6", "/tmp/p7", "/tmp/p8"])

        settings.removeRecentPickleCwd("/tmp/p3")
        #expect(settings.recentPickleCwds == ["/tmp/p5", "/tmp/p1", "/tmp/p2", "/tmp/p4", "/tmp/p6", "/tmp/p7", "/tmp/p8"])
    }

    @Test func visibleRecentPickleCwdsHideMissingPathsAndCapAtFive() {
        let candidates = ["/tmp/p1", "/tmp/missing", "/tmp/p2", "/tmp/p3", "/tmp/p4", "/tmp/p5", "/tmp/p6"]
        let existing: Set<String> = ["/tmp/p1", "/tmp/p2", "/tmp/p3", "/tmp/p4", "/tmp/p5", "/tmp/p6"]

        let visible = PickyRecentPickleFolderPolicy.visibleCwds(candidates) { existing.contains($0) }

        #expect(visible == ["/tmp/p1", "/tmp/p2", "/tmp/p3", "/tmp/p4", "/tmp/p5"])
    }

    @Test func duplicateSendsDuplicateSessionCommandWithSourceID() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.duplicate(sessionID: "pickle-source")

        #expect(client.sentCommands.count == 1)
        let command = try #require(client.sentCommands.first)
        #expect(command.type == .duplicatePickleSession)
        #expect(command.sessionId == "pickle-source")
        #expect(viewModel.lastError == nil)
    }

    @MainActor @Test func eventSequenceDrivesExpectedStatusChanges() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "queued", summary: "Queued"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Started"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.extensionUiRequest())))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))

        #expect(viewModel.sessions.first?.status == .completed)
        #expect(viewModel.sessions.first?.lastSummary == "Done")
        #expect(notifications.delivered.map(\.title).contains(L10n.t("notif.session.waiting.title")))
        #expect(notifications.delivered.map(\.title).contains(L10n.t("notif.session.completed.title")))
    }

    /// Cancellation-then-resume regression test. Reducer-direct: the legacy
    /// emit-based pilot was removed after Phase 3 once every other test was
    /// migrated and the dedicated transport smoke (`transportForwards...`)
    /// took over responsibility for proving `client.events` reaches `apply`.
    @MainActor @Test func cancelledSessionAcceptsRunningUpdateAfterSteeringResume() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "cancelled", summary: "Cancelled"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Steering message sent", updatedAt: "2026-05-01T00:00:10.000Z"))))

        #expect(viewModel.sessions.first?.status == .running)
        #expect(viewModel.sessions.first?.lastSummary == "Steering message sent")
    }

    // MARK: - Transport adapter integration smoke
    //
    // The bulk of this suite drives `viewModel.apply(...)` directly so reducer
    // tests do not depend on the AsyncStream transport. These two tests are the
    // explicit safety net: they prove that the production glue
    // (`viewModel.start()` → `for await event in client.events` → `apply`,
    // plus the `Task { client.connect() }` lifecycle) still forwards stream
    // events into the same reducer the migrated tests exercise. If this layer
    // regresses (e.g. someone changes the event loop, drops `.connected`
    // handling, or stops sending `listSessions` on connect), the reducer-direct
    // tests would stay green; these smoke tests are what flags it.

    @Test func transportForwardsStreamEventsIntoReducer() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "transport-1", title: "Streamed", status: "running"))))

        try await wait { viewModel.sessions.first?.id == "transport-1" }
        #expect(viewModel.sessions.first?.id == "transport-1")
        #expect(viewModel.sessions.first?.status == .running)
    }

    @Test func transportConnectArmsInitialSnapshotAndAsksForSessions() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        // start() schedules `Task { await client.connect() }`, and our fake
        // connect emits `.connected`. The reducer then arms the initial
        // snapshot loader and asynchronously sends `.listSessions` so the dock
        // does not appear empty before the daemon has answered.
        try await wait { client.sentCommands.contains { $0.type == .listSessions } }
        #expect(client.sentCommands.contains { $0.type == .listSessions })

        // Once an (empty) snapshot lands the loader flips off via the same
        // reducer path that the unit tests verify directly.
        client.emit(.protocolEvent(.fixture(eventJSON: #"""
        {"id":"snapshot-empty","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:10.000Z","type":"sessionSnapshot","sessions":[]}
        """#)))
        try await wait { viewModel.isLoadingInitialSessionSnapshot == false }
        #expect(viewModel.isLoadingInitialSessionSnapshot == false)

        // Now actually prove the re-arm: a second .connected (simulating a
        // daemon reconnect after we already have an empty snapshot) must flip
        // the loader back on AND issue another listSessions so the dock
        // doesn't get stuck thinking it's already loaded. Without this step
        // the test would pass even if .connected stopped arming the loader,
        // because isLoadingInitialSessionSnapshot defaults to true on init.
        let listSessionsBefore = client.sentCommands.filter { $0.type == .listSessions }.count
        client.emit(.connected)
        try await wait { client.sentCommands.filter { $0.type == .listSessions }.count > listSessionsBefore }
        #expect(viewModel.isLoadingInitialSessionSnapshot)
        #expect(client.sentCommands.filter { $0.type == .listSessions }.count == listSessionsBefore + 1)
    }

    @MainActor @Test func sessionsRemainOrderedByCreationTimeAcrossStatusChanges() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "completed", title: "Completed", status: "completed", createdAt: "2026-05-01T00:00:00.000Z", updatedAt: "2026-05-01T00:00:30.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "running", title: "Running", status: "running", createdAt: "2026-05-01T00:00:20.000Z", updatedAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "waiting", title: "Waiting", status: "waiting_for_input", createdAt: "2026-05-01T00:00:10.000Z", updatedAt: "2026-05-01T00:00:40.000Z"))))

        #expect(viewModel.sessions.map(\.id) == ["running", "waiting", "completed"])
        #expect(viewModel.sessions.contains { $0.id == "completed" && $0.status == .completed })
    }

    @MainActor @Test func toolEventsCorrelateByToolCallId() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated())))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.tool(sessionId: "session-1", toolCallId: "tool-1", name: "bash", status: "running", preview: "pnpm test"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.tool(sessionId: "session-1", toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "passed"))))

        let tools = viewModel.sessions.first?.tools ?? []
        #expect(tools.count == 1)
        #expect(tools.first?.status == "succeeded")
        #expect(tools.first?.preview == "passed")
        #expect(tools.first?.riskLevel == .elevated)
    }

    @MainActor @Test func stopButtonDispatchesAbortCommandAndUpdatesState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running"))))
        try await viewModel.abort(sessionID: "session-1")

        let abortCommand = try #require(client.sentCommands.first { $0.type == .abort })
        #expect(abortCommand.sessionId == "session-1")
        #expect(viewModel.sessions.first?.status == .cancelled)
    }

    @MainActor @Test func extensionUiAnswersEmitConfirmValueAndCancellationCommands() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.extensionUiRequest())))

        try await viewModel.answerExtensionUi(sessionID: "session-1", requestID: "ui-1", value: .bool(true))
        try await viewModel.cancelExtensionUi(sessionID: "session-1", requestID: "ui-2")

        let answers = client.sentCommands.filter { $0.type == .answerExtensionUi }
        #expect(answers.first?.sessionId == "session-1")
        #expect(answers.first?.requestId == "ui-1")
        #expect(answers.first?.value == .bool(true))
        #expect(answers.last?.requestId == "ui-2")
        #expect(answers.last?.value == .object(["cancelled": .bool(true)]))
    }

    @MainActor @Test func setEditorTextRequestPrimesAndPersistsComposerDraftWithoutWaitingState() throws {
        let draftStore = FakeComposerDraftStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: draftStore
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Started"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.setEditorTextRequest(text: "review comments"))))

        let draftRequest = try #require(viewModel.composerDraftRequest(for: "session-1"))
        #expect(draftRequest.text == "review comments")
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] == draftRequest)
        #expect(viewModel.persistedComposerDraft(for: "session-1") == "review comments")
        #expect(draftStore.drafts["session-1"] == "review comments")
        #expect(viewModel.sessions.first?.status == .running)
        #expect(viewModel.sessions.first?.pendingExtensionUiRequest == nil)

        viewModel.consumeComposerDraftRequest(sessionID: "session-1", requestID: draftRequest.id)
        #expect(viewModel.composerDraftRequest(for: "session-1") == nil)
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] == nil)
    }

    @Test func appendComposerDraftTextPreservesExistingDraftAndCreatesRequest() async throws {
        let client = FakePickyAgentClient()
        let draftStore = FakeComposerDraftStore()
        draftStore.drafts["session-1"] = "기존 메모"
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: draftStore
        )

        viewModel.appendComposerDraftText("/tmp/picky/shot-1.jpg\n이거 보여?", sessionID: "session-1")

        let expected = "기존 메모\n\n/tmp/picky/shot-1.jpg\n이거 보여?"
        let draftRequest = try #require(viewModel.composerDraftRequest(for: "session-1"))
        #expect(draftRequest.text == expected)
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] == draftRequest)
        #expect(viewModel.persistedComposerDraft(for: "session-1") == expected)
        #expect(draftStore.drafts["session-1"] == expected)
    }

    @Test func replaceComposerDraftTextOverwritesDraftAndCreatesRequest() async throws {
        let client = FakePickyAgentClient()
        let draftStore = FakeComposerDraftStore()
        draftStore.drafts["session-1"] = "old draft"
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: draftStore
        )

        viewModel.replaceComposerDraftText("  revised message  ", sessionID: "session-1")

        let draftRequest = try #require(viewModel.composerDraftRequest(for: "session-1"))
        #expect(draftRequest.text == "revised message")
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] == draftRequest)
        #expect(viewModel.persistedComposerDraft(for: "session-1") == "revised message")
        #expect(draftStore.drafts["session-1"] == "revised message")
    }

    @Test func clearComposerDraftRemovesPersistedDraftAttachmentsAndRequestForSubmittedSession() async throws {
        let draftStore = FakeComposerDraftStore()
        let attachmentStore = FakeComposerAttachmentDraftStore()
        draftStore.drafts = ["session-1": "submitted draft", "session-2": "keep draft"]
        attachmentStore.attachments = ["session-1": ["/tmp/submitted.png"], "session-2": ["/tmp/keep.png"]]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: draftStore,
            composerAttachmentDraftStore: attachmentStore
        )
        viewModel.replaceComposerDraftText("submitted draft", sessionID: "session-1")
        #expect(viewModel.composerDraftRequest(for: "session-1") != nil)
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] != nil)

        viewModel.clearComposerDraft(sessionID: "session-1")

        #expect(viewModel.composerDraftRequest(for: "session-1") == nil)
        #expect(viewModel.composerDraftRequestsBySessionID["session-1"] == nil)
        #expect(draftStore.drafts["session-1"] == nil)
        #expect(draftStore.drafts["session-2"] == "keep draft")
        #expect(attachmentStore.attachments["session-1"] == nil)
        #expect(attachmentStore.attachments["session-2"] == ["/tmp/keep.png"])
    }

    @Test func copyMessageTextWritesOriginalTextToClipboard() {
        let clipboard = FakeClipboardWriter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            clipboardWriter: clipboard
        )

        viewModel.copyMessageText("  keep surrounding whitespace  ")
        viewModel.copyMessageText("   \n")

        #expect(clipboard.copied == ["  keep surrounding whitespace  "])
    }

    @MainActor @Test func sessionSnapshotPrunesPersistedComposerDraftsForRemovedSessions() {
        let draftStore = FakeComposerDraftStore()
        draftStore.drafts = ["session-1": "keep me", "missing-session": "remove me"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            composerDraftStore: draftStore
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "session-1", status: "running"))))

        #expect(draftStore.prunedKnownSessionIDs == ["session-1"])
        #expect(draftStore.drafts == ["session-1": "keep me"])
    }

    @MainActor @Test func askUserQuestionRequestStoresQuestionsAndSendsCompositeAnswer() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.askUserQuestionRequest())))

        let request = try #require(viewModel.sessions.first?.pendingExtensionUiRequest)
        #expect(request.method == "askUserQuestion")
        #expect(request.questions?.map(\.type) == [.radio, .checkbox, .text])

        let value: JSONValue = .object(["value": .object(["scope": .string("project"), "items": .array([.string("rule")]), "note": .string("ok")])])
        try await viewModel.answerExtensionUi(sessionID: "session-1", requestID: "ui-form", value: value)

        let answer = try #require(client.sentCommands.last)
        #expect(answer.type == .answerExtensionUi)
        #expect(answer.requestId == "ui-form")
        #expect(answer.value == value)

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.lastRequestText == "Scope?: Project \u{00B7} Items?: Rule \u{00B7} Note: ok")
    }

    @MainActor @Test func extensionUiAnswerLogLineUpdatesLastRequestText() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: 계속 진행해줘."))))
        #expect(viewModel.sessions.first?.lastRequestText == "계속 진행해줘.")

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "extension ui answer: Stop and review"))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.lastRequestText == "Stop and review")
    }

    @MainActor @Test func sessionUpdateClearsPendingExtensionUiRequestWhenIncomingHasNone() throws {
        // Reproduces the askUserQuestion form sticking around after Submit: a stale sessionUpdated
        // that was queued by the daemon before it processed the answer arrives after Picky's local
        // clear and re-attaches the pending request. The daemon's subsequent post-answer
        // sessionUpdated carries an explicit `nil`, so the merge must trust it instead of falling
        // back to the just-resurrected existing value.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(status: "waiting_for_input"))))
        #expect(viewModel.sessions.first?.pendingExtensionUiRequest != nil)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Extension UI answered", updatedAt: "2026-05-01T00:00:05.000Z"))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.status == .running)
    }

    @MainActor @Test func sessionUpdateClearsThinkingPreviewWhenIncomingHasNone() throws {
        // Daemon explicitly drops `thinkingPreview` on terminal status and on extension UI answer
        // (runtime-event-handler.applyStatusEvent + supervisor.answerExtensionUi). The merge used
        // to fall back to the existing value whenever the incoming snapshot carried `nil`, so the
        // previous "Thinking: ..." stayed pinned to the card and would briefly resurface the next
        // time the session re-entered `.running` (e.g. after a follow-up).
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithThinking(status: "running", thinkingPreview: "deciding next step"))))
        #expect(viewModel.sessions.first?.thinkingPreview == "deciding next step")

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:05.000Z"))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.thinkingPreview == nil)
        #expect(card.status == .completed)
    }

    @MainActor @Test func answerExtensionUiKeepsPriorRequestTextWhenUserCancels() async throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: 계속 진행해줘."))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.askUserQuestionRequest())))

        try await viewModel.cancelExtensionUi(sessionID: "session-1", requestID: "ui-form")

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.lastRequestText == "계속 진행해줘.")
    }

    @MainActor @Test func terminalNotificationsAreDeduplicated() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done again"))))

        #expect(notifications.delivered.filter { $0.identifier == "session-1:completed" }.count == 1)
    }

    @MainActor @Test func terminalNotificationResetsAfterSessionRunsAgain() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "First done"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Running again"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Second done", updatedAt: "2026-05-01T00:00:10.000Z"))))

        #expect(notifications.delivered.filter { $0.identifier == "session-1:completed" }.count == 2)
    }

    @MainActor @Test func snapshotHydrationDoesNotNotifyHistoricalCompletedSessions() {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(status: "completed", summary: "Already done"))))

        #expect(notifications.delivered.isEmpty)
    }

    @MainActor @Test func snapshotTransitionFromRunningToCompletedDeliversNotification() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:10.000Z"))))

        #expect(notifications.delivered.map(\.title).contains(L10n.t("notif.session.completed.title")))
    }

    @MainActor @Test func pinnedPickleSessionDoesNotDeliverCompletedNotification() {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Pinned completed Pi session", pinned: true))))

        #expect(viewModel.sessions.first?.status == .completed)
        #expect(viewModel.sessions.first?.pinned == true)
        #expect(!notifications.delivered.map(\.title).contains(L10n.t("notif.session.completed.title")))
    }

    @MainActor @Test func notifyOnCompletedToggleSuppressesCompletedBanner() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))

        #expect(!notifications.delivered.map(\.title).contains(L10n.t("notif.session.completed.title")))
    }

    @MainActor @Test func notifyOnFailedToggleSuppressesFailureBanner() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: false,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "failed", summary: "Boom"))))

        #expect(!notifications.delivered.map(\.title).contains(L10n.t("notif.session.failed.title")))
    }

    @MainActor @Test func notifyOnWaitingForInputToggleSuppressesPendingBanner() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        ))
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(status: "waiting_for_input", summary: "Waiting"))))

        #expect(!notifications.delivered.map(\.title).contains(L10n.t("notif.session.waiting.title")))
    }

    @MainActor @Test func waitingForInputWithoutPendingRequestDoesNotDeliverBanner() {
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            title: "New Pickle · manual-project",
            status: "waiting_for_input",
            summary: "Ready for instructions"
        ))))

        #expect(viewModel.sessions.first?.status == .waiting_for_input)
        #expect(!notifications.delivered.map(\.title).contains(L10n.t("notif.session.waiting.title")))
    }

    @MainActor @Test func defaultNotificationPreferencesSuppressCompletedAndDeliverFailureAndPending() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "failure", status: "failed", summary: "Boom", updatedAt: "2026-05-01T00:00:10.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(id: "pending", status: "waiting_for_input", summary: "Waiting", updatedAt: "2026-05-01T00:00:20.000Z"))))

        let titles = notifications.delivered.map(\.title)
        #expect(!titles.contains(L10n.t("notif.session.completed.title")))
        #expect(titles.contains(L10n.t("notif.session.failed.title")))
        #expect(titles.contains(L10n.t("notif.session.waiting.title")))
    }

    /// Two Pickles live side by side: A is still running, B has just blocked on
    /// an askUserQuestion. The waiting notification must be addressed to B only —
    /// dock-side routing keys off the notification identifier (`<sessionID>:waiting:<requestID>`),
    /// so a regression that fires it for A would auto-open the wrong card.
    @MainActor @Test func multiSessionPendingBannerTargetsOnlyTheWaitingSession() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "running-pickle", title: "Running task", status: "running", summary: "Working"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(id: "waiting-pickle", status: "waiting_for_input", summary: "Pick one", updatedAt: "2026-05-01T00:00:05.000Z"))))

        let waitingIdentifiers = notifications.delivered.map(\.identifier).filter { $0.contains(":waiting:") }
        #expect(waitingIdentifiers == ["waiting-pickle:waiting:ui-form"])

        // Card-side state stays partitioned: only the blocked Pickle exposes a pending request.
        let runningCard = try? #require(viewModel.sessions.first(where: { $0.id == "running-pickle" }))
        let waitingCard = try? #require(viewModel.sessions.first(where: { $0.id == "waiting-pickle" }))
        #expect(runningCard?.pendingExtensionUiRequest == nil)
        #expect(waitingCard?.pendingExtensionUiRequest?.id == "ui-form")
    }

    /// User answers an askUserQuestion (Pi continues), then Pi raises a *new*
    /// askUserQuestion with a fresh request id. The waiting banner must fire again
    /// because dedupe keys on `<sessionID>:waiting:<requestID>`. A regression that
    /// keyed only by session id would leave the second question silent.
    @MainActor @Test func pendingBannerRefiresWhenNewRequestIdArrivesAfterAnswer() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(requestId: "ui-form-1", status: "waiting_for_input", summary: "Q1", updatedAt: "2026-05-01T00:00:02.000Z"))))
        // Daemon clears pending and resumes the Pickle (mimics post-answer sessionUpdated).
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Answered", updatedAt: "2026-05-01T00:00:05.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(requestId: "ui-form-2", status: "waiting_for_input", summary: "Q2", updatedAt: "2026-05-01T00:00:10.000Z"))))

        let waitingIdentifiers = notifications.delivered.map(\.identifier).filter { $0.contains(":waiting:") }
        #expect(waitingIdentifiers == ["session-1:waiting:ui-form-1", "session-1:waiting:ui-form-2"])
    }

    /// Reattach / daemon hydration arrives via `sessionSnapshot`, not
    /// `sessionUpdated`. The same `nil pendingExtensionUiRequest` semantics must
    /// apply or a stale askUserQuestion form survives the snapshot replay.
    @MainActor @Test func sessionSnapshotClearsStalePendingExtensionUiRequest() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(status: "waiting_for_input"))))
        #expect(viewModel.sessions.first?.pendingExtensionUiRequest != nil)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(status: "running", summary: "Reattached", updatedAt: "2026-05-01T00:00:10.000Z"))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.status == .running)
    }

    @MainActor @Test func unpinnedAfterFollowUpDeliversCompletedNotification() {
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: notifications, notificationPreferencesProvider: preferences)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Pinned completed Pi session", pinned: true))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Steering message sent", updatedAt: "2026-05-01T00:00:10.000Z", pinned: false))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:20.000Z", pinned: false))))

        #expect(viewModel.sessions.first?.pinned == false)
        #expect(notifications.delivered.map(\.title).contains(L10n.t("notif.session.completed.title")))
    }

    @Test func hudStatusToneMatchesPickleColorRules() throws {
        #expect(PickySessionStatus.running.hudTone == .inProgress)
        #expect(PickySessionStatus.blocked.hudTone == .error)
        #expect(PickySessionStatus.failed.hudTone == .error)
        #expect(PickySessionStatus.completed.hudTone == .completed)
        #expect(PickySessionStatus.queued.hudTone == .other)
        #expect(PickySessionStatus.waiting_for_input.hudTone == .other)
        #expect(PickySessionStatus.cancelled.hudTone == .other)
    }

    @Test func hudExpansionKeepsCollapsedContentHeightMasked() throws {
        #expect(PickyHUDExpansion.cardSpacing(isExpanded: false) == 0)
        #expect(PickyHUDExpansion.cardSpacing(isExpanded: true) > 0)
        #expect(PickyHUDExpansion.cardVerticalPadding(isExpanded: false) == PickyHUDExpansion.cardVerticalPadding(isExpanded: true))
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: false, measuredHeight: 120) == 0)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 120) == 120)
        #expect(PickyHUDExpansion.contentFrameHeight(isExpanded: true, measuredHeight: 0) == nil)
    }

    @Test func conversationListOnlyAnimatesScrollAfterInitialAppear() throws {
        #expect(!PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: false))
        #expect(PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: true))
    }

    @Test func hudSizeReporterReportsActiveSessionSwitchAndPanelGrowthImmediately() async throws {
        let reporter = PickyHUDSizeReporter(coalescingDelayNanoseconds: 1_000_000)
        var reports: [CGSize] = []

        reporter.handleMeasuredSize(CGSize(width: 100, height: 100), activeSessionID: nil, shouldHoldHeight: false) { reports.append($0) }
        #expect(reports.isEmpty)

        reporter.handleMeasuredSize(CGSize(width: 100, height: 120), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        #expect(reports == [CGSize(width: 100, height: 120)])

        reporter.handleMeasuredSize(CGSize(width: 100, height: 160), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        #expect(reports == [CGSize(width: 100, height: 120), CGSize(width: 100, height: 160)])
    }

    @Test func hudSizeReporterStillCoalescesPanelShrinkBursts() async throws {
        let reporter = PickyHUDSizeReporter(coalescingDelayNanoseconds: 1_000_000)
        var reports: [CGSize] = []

        reporter.handleMeasuredSize(CGSize(width: 100, height: 200), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        #expect(reports == [CGSize(width: 100, height: 200)])
        reports.removeAll()

        reporter.handleMeasuredSize(CGSize(width: 100, height: 180), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        reporter.handleMeasuredSize(CGSize(width: 100, height: 160), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        #expect(reports.isEmpty)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(reports == [CGSize(width: 100, height: 160)])
    }

    @Test func hudSizeReporterKeepsRunningPanelHeightFromShrinking() async throws {
        let reporter = PickyHUDSizeReporter(coalescingDelayNanoseconds: 1_000_000)
        var reports: [CGSize] = []

        reporter.handleMeasuredSize(CGSize(width: 100, height: 200), activeSessionID: "agent-a", shouldHoldHeight: false) { reports.append($0) }
        try await Task.sleep(nanoseconds: 10_000_000)
        reports.removeAll()

        reporter.handleMeasuredSize(CGSize(width: 100, height: 120), activeSessionID: "agent-a", shouldHoldHeight: true) { reports.append($0) }
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(reports.isEmpty)
    }

    @Test func hudSizeReporterReleasesHeldHeightWhenAskUserQuestionAnswered() async throws {
        let reporter = PickyHUDSizeReporter(coalescingDelayNanoseconds: 1_000_000)
        var reports: [CGSize] = []

        // Initial measure while a question bubble is active grows the panel.
        reporter.handleMeasuredSize(
            CGSize(width: 100, height: 480),
            activeSessionID: "agent-a",
            extensionUiRequestID: "req-1",
            shouldHoldHeight: true
        ) { reports.append($0) }
        #expect(reports == [CGSize(width: 100, height: 480)])
        reports.removeAll()

        // The user submits the answer: the bubble auto-collapses, content shrinks, but
        // session status is still `.running` so `shouldHoldHeight` stays true. The
        // request id transitioning non-nil -> nil must release the held height for one
        // report so the panel can shrink instead of leaving a tall empty band.
        reporter.handleMeasuredSize(
            CGSize(width: 100, height: 240),
            activeSessionID: "agent-a",
            extensionUiRequestID: nil,
            shouldHoldHeight: true
        ) { reports.append($0) }

        #expect(reports == [CGSize(width: 100, height: 240)])
    }

    @Test func hudDockPreviewOpensImmediatelyAndClosesAfterDockLeaveTimeout() throws {
        #expect(PickyHUDDockLayout.closeDelay == 0.4)
        #expect(PickyHUDDockLayout.previewSessionIDAfterDockHover(current: nil, sessionID: "a") == "a")
        #expect(PickyHUDDockLayout.previewSessionIDAfterDockHover(current: "a", sessionID: "b") == "b")
        #expect(PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(current: "a", isDockHovered: false) == nil)
        #expect(PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(current: "a", isDockHovered: true) == "a")
        #expect(PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(current: "b", isDockHovered: false) == nil)
        #expect(PickyHUDDockLayout.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: true) == .open("opened"))
        #expect(PickyHUDDockLayout.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: false) == .open("opened"))
    }

    @Test func hudDockUsesHeldSessionBeforePreview() throws {
        let visibleIDs = ["first", "pinned", "opened", "hovered"]
        #expect(PickyHUDDockLayout.previewSessionID(hoveredID: "hovered", heldID: "opened") == nil)
        #expect(PickyHUDDockLayout.previewSessionID(hoveredID: "hovered", heldID: nil) == "hovered")
        #expect(PickyHUDDockLayout.activeSessionID(visibleIDs: visibleIDs, held: .open("opened"), previewID: "hovered") == "opened")
        #expect(PickyHUDDockLayout.activeSessionID(visibleIDs: visibleIDs, held: .open("missing"), previewID: nil) == nil)
    }

    @Test func hudDockFullscreenTargetUsesHeldThenHoverPreview() throws {
        let visibleIDs = ["first", "opened", "hovered"]
        #expect(PickyHUDDockLayout.fullscreenTargetSessionID(visibleIDs: visibleIDs, held: .open("opened"), hoverPreviewID: "hovered") == "opened")
        #expect(PickyHUDDockLayout.fullscreenTargetSessionID(visibleIDs: visibleIDs, held: nil, hoverPreviewID: "hovered") == "hovered")
        #expect(PickyHUDDockLayout.fullscreenTargetSessionID(visibleIDs: visibleIDs, held: .open("missing"), hoverPreviewID: "hovered") == "hovered")
        #expect(PickyHUDDockLayout.fullscreenTargetSessionID(visibleIDs: visibleIDs, held: nil, hoverPreviewID: "missing") == nil)
    }

    @Test func hudDockHeldStateIsExclusiveAcrossClicks() throws {
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: nil, clicked: "agent-a") == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-a") == nil)
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-b") == .open("agent-b"))
    }

    @Test func hudDockResolvesManualAutoOpenOnlyWhenPendingSessionIsVisible() throws {
        #expect(PickyHUDDockLayout.manualAutoOpenResolution(pendingSessionID: nil, visibleIDs: ["manual-pickle"]) == nil)
        #expect(PickyHUDDockLayout.manualAutoOpenResolution(pendingSessionID: "manual-pickle", visibleIDs: ["other"]) == nil)
        #expect(PickyHUDDockLayout.manualAutoOpenResolution(pendingSessionID: "manual-pickle", visibleIDs: ["other", "manual-pickle"]) == .open("manual-pickle"))
    }

    @Test func hudDockResolvesNotificationOpenOnlyWhenPendingSessionIsVisible() throws {
        #expect(PickyHUDDockLayout.requestedOpenResolution(pendingSessionID: nil, visibleIDs: ["notified-pickle"]) == nil)
        #expect(PickyHUDDockLayout.requestedOpenResolution(pendingSessionID: "notified-pickle", visibleIDs: ["other"]) == nil)
        #expect(PickyHUDDockLayout.requestedOpenResolution(pendingSessionID: "notified-pickle", visibleIDs: ["other", "notified-pickle"]) == .open("notified-pickle"))
    }

    @Test func hudDockKeyboardShortcutsOpenNumberedSessionsAndCycle() throws {
        let visibleIDs = ["agent-a", "agent-b", "agent-c"]
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 33, charactersIgnoringModifiers: "{") == -1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 30, charactersIgnoringModifiers: "}") == 1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 0, charactersIgnoringModifiers: "[") == -1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 0, charactersIgnoringModifiers: "]") == 1)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 76, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: .command) == false)
        // While the TUI terminal is focused only ⌘T and ⌘W are owned by the HUD;
        // every other key (including all other cmd combos) passes through to Pi.
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 13, charactersIgnoringModifiers: "w", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 0, charactersIgnoringModifiers: "W", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 13, charactersIgnoringModifiers: "w", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: []) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 0, charactersIgnoringModifiers: "a", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 0, charactersIgnoringModifiers: "R", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.command, .shift]) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: [.command, .shift]) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 45, charactersIgnoringModifiers: "n", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 45, charactersIgnoringModifiers: "n", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 0, charactersIgnoringModifiers: "N", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 0, charactersIgnoringModifiers: "E", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 40, charactersIgnoringModifiers: "k", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 40, charactersIgnoringModifiers: "k", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 0, charactersIgnoringModifiers: "K", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .control) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.control, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: .control) == true)
        #expect(PickyHUDDockLayout.numberShortcutForSessionIndex(0) == 1)
        #expect(PickyHUDDockLayout.numberShortcutForSessionIndex(8) == 9)
        #expect(PickyHUDDockLayout.numberShortcutForSessionIndex(9) == nil)
        #expect(PickyHUDDockLayout.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: 1) == "agent-a")
        #expect(PickyHUDDockLayout.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: 4) == nil)
        #expect(PickyHUDDockLayout.heldSessionAfterNumberShortcut(current: nil, visibleIDs: visibleIDs, number: 1) == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterNumberShortcut(current: nil, visibleIDs: visibleIDs, number: 3) == .open("agent-c"))
        #expect(PickyHUDDockLayout.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 1) == nil)
        #expect(PickyHUDDockLayout.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 2) == .open("agent-b"))
        #expect(PickyHUDDockLayout.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 4) == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: nil, visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, direction: 1) == .open("agent-b"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: .open("agent-c"), visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, direction: -1) == .open("agent-c"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: .open("missing"), visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: [], direction: 1) == .open("agent-a"))
    }

    @Test func hudDockCloseTimeoutKeepsOpenHolds() throws {
        #expect(PickyHUDDockLayout.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: true) == .open("opened"))
        #expect(PickyHUDDockLayout.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: false) == .open("opened"))
    }

    @Test func hudDockKeepsGitSectionExpansionBySessionAcrossHoverClose() throws {
        var storedValues: [String: Bool] = [:]
        #expect(PickyHUDDockLayout.gitSectionExpansion(sessionID: "agent-a", storedValues: storedValues))

        storedValues = PickyHUDDockLayout.gitSectionExpansionValues(storedValues, setting: false, for: "agent-a")
        #expect(!PickyHUDDockLayout.gitSectionExpansion(sessionID: "agent-a", storedValues: storedValues))
        #expect(PickyHUDDockLayout.gitSectionExpansion(sessionID: "agent-b", storedValues: storedValues))

        #expect(PickyHUDDockLayout.previewSessionIDAfterCloseTimeout(current: "agent-a", isDockHovered: false) == nil)
        #expect(PickyHUDDockLayout.previewSessionIDAfterDockHover(current: nil, sessionID: "agent-a") == "agent-a")
        #expect(!PickyHUDDockLayout.gitSectionExpansion(sessionID: "agent-a", storedValues: storedValues))
    }

    @Test func hudSummaryEventLabelReflectsStatusAndReportArtifact() throws {
        #expect(PickyHUDSummaryEventPolicy.label(for: .completed, hasReportArtifact: true) == "Report ready")
        #expect(PickyHUDSummaryEventPolicy.label(for: .completed, hasReportArtifact: false) == "Result")
        #expect(PickyHUDSummaryEventPolicy.label(for: .failed, hasReportArtifact: false) == "Failed")
        #expect(PickyHUDSummaryEventPolicy.label(for: .cancelled, hasReportArtifact: false) == "Cancelled")
        #expect(PickyHUDSummaryEventPolicy.label(for: .blocked, hasReportArtifact: false) == "Blocked")
        #expect(PickyHUDSummaryEventPolicy.label(for: .waiting_for_input, hasReportArtifact: false) == "Awaiting input")
        #expect(PickyHUDSummaryEventPolicy.label(for: .running, hasReportArtifact: false) == "Update")
        #expect(PickyHUDSummaryEventPolicy.label(for: .queued, hasReportArtifact: false) == "Update")
    }

    @Test func hudSummaryEventTimeReportsNowWhileActive() throws {
        #expect(PickyHUDSummaryEventPolicy.time(for: .running, summaryElapsed: "2h 25m") == "now")
        #expect(PickyHUDSummaryEventPolicy.time(for: .queued, summaryElapsed: "5m") == "now")
        #expect(PickyHUDSummaryEventPolicy.time(for: .completed, summaryElapsed: "2h 25m") == "2h 25m")
        #expect(PickyHUDSummaryEventPolicy.time(for: .failed, summaryElapsed: "3m") == "3m")
        #expect(PickyHUDSummaryEventPolicy.time(for: .waiting_for_input, summaryElapsed: "<1m") == "<1m")
    }

    @Test func sessionCardElapsedSinceUpdateUsesUpdatedAt() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let card = PickySessionListViewModel.SessionCard(
            id: "s",
            title: "T",
            status: .completed,
            cwd: nil,
            createdAt: now.addingTimeInterval(-3 * 60 * 60),
            updatedAt: now.addingTimeInterval(-30),
            lastSummary: "",
            thinkingPreview: nil,
            logPreview: "",
            lastRequestText: nil,
            lastRequestAt: nil,
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: [],
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            activitySummary: .zero,
            pendingExtensionUiRequest: nil,
            piSessionFilePath: nil,
            notifyMainOnCompletion: nil,
            pinned: false,
            archived: false,
            hasRuntimeDetachedFollowUpRejection: false,
            isMainAgentHandoff: false
        )
        #expect(card.elapsedDescription(now: now) == "3h 0m")
        #expect(card.elapsedSinceUpdate(now: now) == "<1m")
    }

    @Test func hudDockPanelCentersVerticallyWithinVisibleFrame() throws {
        let visibleFrame = CGRect(x: 0, y: 100, width: 1200, height: 800)
        #expect(PickyHUDDockLayout.centeredPanelY(visibleFrame: visibleFrame, targetHeight: 400) == 300)
        #expect(PickyHUDDockLayout.centeredPanelY(visibleFrame: visibleFrame, targetHeight: 900) == 108)
    }

    @Test func hudDockSideTogglesBetweenScreenEdges() throws {
        #expect(PickyHUDDockSide.right.toggled == .left)
        #expect(PickyHUDDockSide.left.toggled == .right)
        #expect(PickyHUDDockSide.top.toggled == .bottom)
        #expect(PickyHUDDockSide.bottom.toggled == .top)
    }

    @Test func hudDockSideTogglesOrientationForHandleDoubleClick() throws {
        #expect(PickyHUDDockSide.right.orientationToggled(anchorPercent: 20) == .top)
        #expect(PickyHUDDockSide.left.orientationToggled(anchorPercent: 60) == .bottom)
        #expect(PickyHUDDockSide.top.orientationToggled(anchorPercent: 20) == .right)
        #expect(PickyHUDDockSide.bottom.orientationToggled(anchorPercent: 60) == .right)
    }

    @Test func hudDockHorizontalPanelPlacementUsesTopBottomEdgesAndClampedCenterOffset() throws {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let panelWidth: CGFloat = 540
        let targetHeight: CGFloat = 220

        #expect(PickyHUDDockLayout.horizontalPanelX(visibleFrame: visibleFrame, panelWidth: panelWidth) == visibleFrame.midX - (panelWidth / 2))
        #expect(PickyHUDDockLayout.horizontalPanelY(visibleFrame: visibleFrame, targetHeight: targetHeight, dockSide: .top) == visibleFrame.maxY - targetHeight - PickyHUDDockLayout.dockEdgeMargin)
        #expect(PickyHUDDockLayout.horizontalPanelY(visibleFrame: visibleFrame, targetHeight: targetHeight, dockSide: .bottom) == visibleFrame.minY + PickyHUDDockLayout.dockEdgeMargin)

        // Clamp without a dock-rail length: the dock CENTER is allowed to
        // reach `visibleFrame.maxX - screenMargin`, so the (transparent)
        // panel overhangs the screen by ~half its width.
        let clampedRight = PickyHUDDockLayout.clampedHorizontalXOffset(10_000, visibleFrame: visibleFrame, panelWidth: panelWidth)
        #expect(
            PickyHUDDockLayout.horizontalPanelX(visibleFrame: visibleFrame, panelWidth: panelWidth, xOffset: clampedRight)
                == (visibleFrame.maxX - PickyHUDDockLayout.screenMargin - (panelWidth / 2)).rounded(.toNearestOrEven)
        )

        // With a dock-rail length passed in, the clamp keeps the dock fully
        // visible: the dock CENTER stays at least `dockRailLength / 2 +
        // screenMargin` from each visible-frame edge.
        let dockLength: CGFloat = 200
        let dockClampedRight = PickyHUDDockLayout.clampedHorizontalXOffset(
            10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockRailLength: dockLength
        )
        let dockCenterX = visibleFrame.midX + dockClampedRight
        #expect(dockCenterX == visibleFrame.maxX - PickyHUDDockLayout.screenMargin - (dockLength / 2))
    }

    @Test func hudDockHorizontalPanelWidthAndClampReserveFullscreenControl() throws {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let visibleFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let sessionCount = PickyHUDDockLayout.visibleSessionLimit
        let railLength = PickyHUDDockLayout.horizontalDockRailLength(
            sessionCount: sessionCount,
            isAddSlotExpanded: false,
            metrics: metrics
        )
        let panelWidth = PickyHUDDockLayout.panelWidth(
            cardWidth: 1,
            dockSide: .top,
            sessionCount: sessionCount,
            isAddSlotExpanded: false,
            metrics: metrics
        )
        let expectedVisibleRailWidth = railLength + (PickyHUDDockLayout.miniPreviewHorizontalReserve(metrics: metrics) * 2)

        #expect(railLength >= PickyHUDDockLayout.fullscreenDockControlLength(metrics: metrics))
        #expect(panelWidth == expectedVisibleRailWidth + (PickyHUDExpansion.dockShadowHorizontalPadding * 2))

        let clampedRight = PickyHUDDockLayout.clampedHorizontalXOffset(
            10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockRailLength: railLength
        )
        #expect(visibleFrame.midX + clampedRight == visibleFrame.maxX - PickyHUDDockLayout.screenMargin - (railLength / 2))
    }

    @Test func hudDockHorizontalSideUsesFortySixtySnapHysteresis() throws {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let snapBottomY = visibleFrame.minY + visibleFrame.height * PickyHUDDockLayout.dockSideSnapBottomThreshold
        let snapTopY = visibleFrame.minY + visibleFrame.height * PickyHUDDockLayout.dockSideSnapTopThreshold

        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: snapBottomY - 0.1, visibleFrame: visibleFrame, currentSide: .top) == .bottom)
        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: snapBottomY, visibleFrame: visibleFrame, currentSide: .top) == .top)
        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: visibleFrame.midY, visibleFrame: visibleFrame, currentSide: .bottom) == .bottom)
        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: visibleFrame.midY, visibleFrame: visibleFrame, currentSide: .top) == .top)
        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: snapTopY, visibleFrame: visibleFrame, currentSide: .bottom) == .bottom)
        #expect(PickyHUDDockLayout.horizontalDockSide(forDockRailCenterY: snapTopY + 0.1, visibleFrame: visibleFrame, currentSide: .bottom) == .top)
    }

    @Test func hudDockPanelXMirrorsBetweenLeftAndRightEdges() throws {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let panelWidth: CGFloat = 540

        #expect(PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .left) == visibleFrame.minX + PickyHUDDockLayout.dockLeftEdgeMargin)
        #expect(PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .right) == visibleFrame.maxX - panelWidth - PickyHUDDockLayout.dockRightEdgeMargin)
    }

    @Test func hudDockPanelXOffsetShiftsPanelHorizontally() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panelWidth: CGFloat = 540

        // Right-docked: negative offset shifts left (inward), positive shifts right (outward).
        let rightInward = PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .right, xOffset: -100)
        #expect(rightInward == visibleFrame.maxX - panelWidth - PickyHUDDockLayout.dockRightEdgeMargin - 100)
        let rightOutward = PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .right, xOffset: 100)
        #expect(rightOutward == visibleFrame.maxX - panelWidth - PickyHUDDockLayout.dockRightEdgeMargin + 100)

        // Left-docked: positive offset shifts right (inward), negative shifts left (outward).
        let leftInward = PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .left, xOffset: 100)
        #expect(leftInward == visibleFrame.minX + PickyHUDDockLayout.dockLeftEdgeMargin + 100)
        let leftOutward = PickyHUDDockLayout.panelX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .left, xOffset: -100)
        #expect(leftOutward == visibleFrame.minX + PickyHUDDockLayout.dockLeftEdgeMargin - 100)
    }

    @Test func hudDockPanelXOffsetClampedToScreenEdgesAndOverhang() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panelWidth: CGFloat = 540
        let margin = PickyHUDDockLayout.screenMargin
        let overhang = PickyHUDDockLayout.dockOverhangLimit

        // Right-docked, large positive xOffset (outward, off-screen): capped at +overhang
        let rightOutwardClamped = PickyHUDDockLayout.clampedXOffset(
            10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .right
        )
        #expect(rightOutwardClamped == overhang)

        // Right-docked, large negative xOffset (inward): capped at the visible-frame edge
        let rightInwardClamped = PickyHUDDockLayout.clampedXOffset(
            -10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .right
        )
        let naturalRightX = visibleFrame.maxX - panelWidth - PickyHUDDockLayout.dockRightEdgeMargin
        let minRightX = visibleFrame.minX + margin
        #expect(rightInwardClamped == -(naturalRightX - minRightX))

        // Left-docked, large negative xOffset (outward, off-screen): capped at -overhang
        let leftOutwardClamped = PickyHUDDockLayout.clampedXOffset(
            -10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .left
        )
        #expect(leftOutwardClamped == -overhang)

        // Left-docked, large positive xOffset (inward): capped at the visible-frame edge
        let leftInwardClamped = PickyHUDDockLayout.clampedXOffset(
            10_000,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .left
        )
        let naturalLeftX = visibleFrame.minX + PickyHUDDockLayout.dockLeftEdgeMargin
        let maxLeftX = visibleFrame.maxX - margin - panelWidth
        #expect(leftInwardClamped == maxLeftX - naturalLeftX)
    }

    @Test func hudDockPanelXClampsPersistedOffsetsBeforePlacement() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panelWidth: CGFloat = 540
        let overhang = PickyHUDDockLayout.dockOverhangLimit

        let naturalRightX = PickyHUDDockLayout.panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .right
        )
        #expect(
            PickyHUDDockLayout.clampedPanelX(
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockSide: .right,
                xOffset: 10_000
            ) == naturalRightX + overhang
        )

        let naturalLeftX = PickyHUDDockLayout.panelX(
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .left
        )
        #expect(
            PickyHUDDockLayout.clampedPanelX(
                visibleFrame: visibleFrame,
                panelWidth: panelWidth,
                dockSide: .left,
                xOffset: -10_000
            ) == naturalLeftX - overhang
        )
    }

    @Test func hudDockSideUsesFortySixtySnapHysteresis() throws {
        let visibleFrame = CGRect(x: 100, y: 0, width: 1200, height: 800)
        let snapLeftX = visibleFrame.minX + visibleFrame.width * PickyHUDDockLayout.dockSideSnapLeftThreshold
        let snapRightX = visibleFrame.minX + visibleFrame.width * PickyHUDDockLayout.dockSideSnapRightThreshold

        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: snapLeftX - 0.1, visibleFrame: visibleFrame, currentSide: .right) == .left)
        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: snapLeftX, visibleFrame: visibleFrame, currentSide: .right) == .right)
        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: visibleFrame.midX, visibleFrame: visibleFrame, currentSide: .left) == .left)
        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: visibleFrame.midX, visibleFrame: visibleFrame, currentSide: .right) == .right)
        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: snapRightX, visibleFrame: visibleFrame, currentSide: .left) == .left)
        #expect(PickyHUDDockLayout.dockSide(forDockRailCenterX: snapRightX + 0.1, visibleFrame: visibleFrame, currentSide: .left) == .right)
    }

    @Test func hudDockXOffsetKeepsRailCenterContinuousAcrossSides() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panelWidth: CGFloat = 540
        let leftCenter = visibleFrame.midX - 100
        let rightCenter = visibleFrame.midX + 100

        let leftOffset = PickyHUDDockLayout.xOffset(
            forDockRailCenterX: leftCenter,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .left
        )
        let rightOffset = PickyHUDDockLayout.xOffset(
            forDockRailCenterX: rightCenter,
            visibleFrame: visibleFrame,
            panelWidth: panelWidth,
            dockSide: .right
        )

        #expect(PickyHUDDockLayout.dockRailCenterX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .left, xOffset: leftOffset) == leftCenter)
        #expect(PickyHUDDockLayout.dockRailCenterX(visibleFrame: visibleFrame, panelWidth: panelWidth, dockSide: .right, xOffset: rightOffset) == rightCenter)
    }

    @Test func hudDockOverhangLimitIsHalfDockRailWidth() throws {
        // Sanity check on the overhang constant: half the dock rail width keeps
        // half of the capsule visible so users can always grab the handle.
        #expect(PickyHUDDockLayout.dockOverhangLimit == (PickyHUDDockLayout.railWidth / 2).rounded(.down))
    }

    @Test func hudDockPositionsDefaultToEmptyWhenMissingFromSettings() throws {
        let settings = try JSONDecoder().decode(PickySettings.self, from: Data("{}".utf8))
        // No legacy fields and no dictionary -> migration synthesizes a single fallback entry.
        #expect(settings.hudDockPositions[PickyHUDDockPosition.defaultKey] != nil)
        #expect(settings.hudDockPositions[PickyHUDDockPosition.defaultKey]?.side == .right)
    }

    @Test func hudDockPositionResolutionUsesDisplaySpecificThenDefaultFallback() throws {
        let fallback = PickyHUDDockPosition(side: .left, anchorPercent: 48, xOffset: 12)
        let displaySpecific = PickyHUDDockPosition(side: .right, anchorPercent: 18, xOffset: -20)
        let positions = [
            PickyHUDDockPosition.defaultKey: fallback,
            "2": displaySpecific
        ]

        #expect(PickyHUDDockPosition.resolved(in: positions, displayKey: "2") == displaySpecific)
        #expect(PickyHUDDockPosition.resolved(in: positions, displayKey: "3") == fallback)
        #expect(PickyHUDDockPosition.resolved(in: [:], displayKey: "3") == PickyHUDDockPosition.defaults())
    }

    @Test func hudDockPositionsRoundTripThroughJSON() throws {
        let original = PickyHUDDockPosition(side: .left, anchorPercent: 30, xOffset: -28)
        var settings = PickySettings.defaults()
        settings.hudDockPositions = ["display-1": original, "display-2": .defaults()]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(decoded.hudDockPositions["display-1"] == original)
        #expect(decoded.hudDockPositions["display-2"] == .defaults())
    }

    @Test func dockTopAnchorPercentClampsToSupportedRange() throws {
        #expect(PickySettings.clampedDockTopAnchorPercent(22.0) == 22.0)
        #expect(PickySettings.clampedDockTopAnchorPercent(0.0) == 2.0)
        #expect(PickySettings.clampedDockTopAnchorPercent(1.99) == 2.0)
        #expect(PickySettings.clampedDockTopAnchorPercent(70.0) == 70.0)
        #expect(PickySettings.clampedDockTopAnchorPercent(120.5) == 70.0)
        // Non-finite values fall back to the default rather than poisoning the saved settings file.
        #expect(PickySettings.clampedDockTopAnchorPercent(.nan) == PickySettings.defaultDockTopAnchorPercent)
        #expect(PickySettings.clampedDockTopAnchorPercent(.infinity) == PickySettings.defaultDockTopAnchorPercent)
    }

    @Test func dockTopScreenYMatchesAnchorPercentRelativeToVisibleFrameTop() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876) // 1440x900 minus a 24pt menu bar
        // 22% from the visible-frame top: 0.22 * 876 = 192.72 below visibleFrame.maxY.
        let dockTop = PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: 22.0)
        #expect(abs(dockTop - (visibleFrame.maxY - 192.72)) < 0.01)
        // Boundary clamps reflect the supported anchor range.
        let atFloor = PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: 100.0)
        let at70 = PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: 70.0)
        #expect(atFloor == at70)
    }

    @Test func dockTopAnchoredPanelKeepsDockTopAtAnchorWithinSupportedHeight() throws {
        // For a 1440x900 visible frame minus a 24pt menu bar, 22% anchor places the dock
        // top at visibleFrame.maxY - 192.72. With topPaddingFromContentTop = 32 (= dock
        // shadow vertical padding) and a moderate-height panel, the formula returns an
        // origin Y that lands the dock top exactly on the anchor.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let topPadding: CGFloat = 32
        let anchor = 22.0
        let cap = PickyHUDDockLayout.dockTopAnchoredMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )

        // Within the cap, dock top sits exactly at the requested anchor.
        let originAtCap = PickyHUDDockLayout.dockTopAnchoredPanelY(
            visibleFrame: visibleFrame,
            targetHeight: cap,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let dockTop = originAtCap + cap - topPadding
        let expectedDockTop = PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchor)
        #expect(abs(dockTop - expectedDockTop) < 0.01)

        let shorter = cap - 200
        let originShorter = PickyHUDDockLayout.dockTopAnchoredPanelY(
            visibleFrame: visibleFrame,
            targetHeight: shorter,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let dockTopShorter = originShorter + shorter - topPadding
        #expect(abs(dockTopShorter - expectedDockTop) < 0.01)
    }

    @Test func dockTopAnchoredMaxPanelHeightCapsAtVisibleFrameFloor() throws {
        // The cap must be exactly the height that places panel.origin.y at
        // visibleFrame.minY + screenMargin so the conversation card cannot push
        // through the bottom of the visible frame.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let topPadding: CGFloat = 32
        let cap = PickyHUDDockLayout.dockTopAnchoredMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: 22.0
        )
        let originAtCap = PickyHUDDockLayout.dockTopAnchoredPanelY(
            visibleFrame: visibleFrame,
            targetHeight: cap,
            topPaddingFromContentTop: topPadding,
            anchorPercent: 22.0
        )
        #expect(originAtCap == visibleFrame.minY + PickyHUDDockLayout.screenMargin)
    }

    @Test func dockTopAnchoredPointAlignedPanelKeepsDockTopStableAcrossHeights() throws {
        // Reproduces the live jitter class: a fractional anchor can put the fractional
        // remainder in origin.y for short HUDs but in height for capped HUDs. The
        // point-aligned helpers pin panelTop first, so both heights render the same
        // dock capsule top after AppKit normalizes the NSPanel frame to whole points.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        let anchor = 22.94283038094778
        let shortHeight: CGFloat = 500
        let cappedHeight = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        ) - PickyHUDExpansion.cardBreathingRoom

        let shortOrigin = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelY(
            visibleFrame: visibleFrame,
            targetHeight: shortHeight,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let cappedOrigin = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelY(
            visibleFrame: visibleFrame,
            targetHeight: cappedHeight,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let shortDockTop = shortOrigin + shortHeight - topPadding
        let cappedDockTop = cappedOrigin + cappedHeight - topPadding
        let expectedDockTop = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelTopY(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        ) - topPadding

        #expect(shortDockTop == expectedDockTop)
        #expect(cappedDockTop == expectedDockTop)
        #expect(expectedDockTop == PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchor).rounded(.down))
    }

    @Test func dockTopAnchoredPointAlignedMaxPanelHeightUsesWholePointFloor() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        let anchor = 22.94283038094778
        let pointAlignedCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let bottomFloor = (visibleFrame.minY + PickyHUDDockLayout.screenMargin).rounded(.up)
        let originAtCap = PickyHUDDockLayout.dockTopAnchoredPointAlignedPanelY(
            visibleFrame: visibleFrame,
            targetHeight: pointAlignedCap,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )

        #expect(pointAlignedCap.rounded(.down) == pointAlignedCap)
        #expect(originAtCap == bottomFloor)
    }

    @Test func dockBodyTopOffsetEqualsTopShadowPadding() throws {
        // The drag handle now lives INSIDE the dock capsule's top row, so it no
        // longer pushes the capsule top down. The distance from the panel content's
        // top edge to the dock CAPSULE's top edge is exactly the top shadow padding
        // wrapping the HStack — the anchor percent lands directly on the visible dock
        // capsule top while bottom padding can be larger for the downward shadow.
        #expect(
            PickyHUDExpansion.dockBodyTopOffsetFromContentTop
            == PickyHUDExpansion.dockShadowTopPadding
        )
    }

    @Test func dockTopAnchoredPanelUsesCapsuleOffsetSoAnchorMatchesVisibleDockTop() throws {
        // When the overlay manager passes `dockBodyTopOffsetFromContentTop` as the
        // top padding, dockTopAnchoredPanelY positions the panel so the dock CAPSULE's
        // top edge — not the handle's top edge — lands at the user's anchor percent.
        // Without this, the dock would render permanently below the anchor by exactly
        // (handle area height + spacing) points.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let anchor = 22.0
        let topPadding = PickyHUDExpansion.dockBodyTopOffsetFromContentTop
        let cap = PickyHUDDockLayout.dockTopAnchoredMaxPanelHeight(
            visibleFrame: visibleFrame,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        let originAtCap = PickyHUDDockLayout.dockTopAnchoredPanelY(
            visibleFrame: visibleFrame,
            targetHeight: cap,
            topPaddingFromContentTop: topPadding,
            anchorPercent: anchor
        )
        // Dock capsule top in screen Y = panel.top - dockBodyTopOffsetFromContentTop.
        let dockCapsuleTopScreenY = originAtCap + cap - topPadding
        let expected = PickyHUDDockLayout.dockTopScreenY(visibleFrame: visibleFrame, anchorPercent: anchor)
        #expect(abs(dockCapsuleTopScreenY - expected) < 0.01)
    }

    @Test func placementDefaultMatchesHistoricalCardCap() throws {
        // Placement starts at 1080 so the conversation card behaves identically to
        // before the dynamic-height system was introduced until the overlay manager
        // hydrates the per-screen value.
        #expect(PickyHUDPlacement.defaultAvailableCardMaxHeight == 1080)
        let placement = PickyHUDPlacement()
        #expect(placement.availableCardMaxHeight == 1080)
    }

    @Test func dockTopAnchorPercentSyncsAcrossDifferentVisibleFrameSizes() throws {
        // Same anchor percent on a tall portrait monitor and a wide laptop screen yields
        // dock-top screen Ys that are at the same relative offset from each visible
        // frame's top edge, even though the absolute pixel values differ. This is the
        // core guarantee of the synced (non-per-monitor) anchor design.
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1896)
        let pct = 22.0
        let laptopDockTop = PickyHUDDockLayout.dockTopScreenY(visibleFrame: laptop, anchorPercent: pct)
        let portraitDockTop = PickyHUDDockLayout.dockTopScreenY(visibleFrame: portrait, anchorPercent: pct)
        let laptopRelative = (laptop.maxY - laptopDockTop) / laptop.height
        let portraitRelative = (portrait.maxY - portraitDockTop) / portrait.height
        #expect(abs(laptopRelative - portraitRelative) < 0.0001)
        #expect(abs(laptopRelative - 0.22) < 0.0001)
    }

    @Test func hudExpansionDefersOuterPanelShrinkUntilCollapseFinishes() throws {
        #expect(PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 320, targetHeight: 80, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 80, targetHeight: 320, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 320, targetHeight: 80, deferShrink: false))
        #expect(PickyHUDExpansion.panelShrinkDelay > PickyHUDExpansion.duration)
        #expect(PickyHUDExpansion.anchorsContentToPanelTopDuringDeferredShrink)
    }

    @Test func hudReportedSizeHoldsActiveShrinkButResetsAcrossSessionSwitch() throws {
        let tall = CGSize(width: 540, height: 900)
        let short = CGSize(width: 540, height: 420)

        #expect(PickyHUDExpansion.reportedHUDSize(
            measuredSize: short,
            previousReportedSize: tall,
            activeSessionChanged: false,
            shouldHoldHeight: true
        ) == tall)
        #expect(PickyHUDExpansion.reportedHUDSize(
            measuredSize: short,
            previousReportedSize: tall,
            activeSessionChanged: true,
            shouldHoldHeight: true
        ) == short)
        #expect(PickyHUDExpansion.reportedHUDSize(
            measuredSize: short,
            previousReportedSize: tall,
            activeSessionChanged: false,
            shouldHoldHeight: false
        ) == short)
    }

    @Test func hudCardResizeInteractionResetClearsStickyHoverAndDragState() throws {
        var state = PickyHUDCardResizeInteractionState()

        #expect(!state.isVisible)
        state.setHovered(true)
        #expect(state.isVisible)
        let hoverOnlyResetWasDragging = state.reset()
        #expect(!hoverOnlyResetWasDragging)
        #expect(!state.isHovered)
        #expect(!state.isDragging)
        #expect(!state.isVisible)

        state.setHovered(true)
        state.beginDragging()
        #expect(state.isVisible)
        let draggingResetWasDragging = state.reset()
        #expect(draggingResetWasDragging)
        #expect(!state.isHovered)
        #expect(!state.isDragging)
        #expect(!state.isVisible)
    }

    @Test func hudCardResizeInteractionEndsDragWithoutClearingLiveHover() throws {
        var state = PickyHUDCardResizeInteractionState()

        state.setHovered(true)
        state.beginDragging()

        let firstEndWasDragging = state.endDragging()
        #expect(firstEndWasDragging)
        #expect(state.isHovered)
        #expect(!state.isDragging)
        #expect(state.isVisible)
        let secondEndWasDragging = state.endDragging()
        #expect(!secondEndWasDragging)
    }

    @Test func hudAppKitRepresentableTeardownSuppressesCallbacksThatMutateSwiftUIState() throws {
        let source = try String(contentsOfFile: "\(testProjectCwd)/Picky/HUD/PickyHUDView.swift")

        #expect(source.components(separatedBy: "static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator)").count - 1 == 3)
        #expect(!source.contains("static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {\n        (nsView as?"))
        #expect(source.contains("view.cancelTransientInteraction(notifyingCallbacks: false)"))
        #expect(source.components(separatedBy: "view.cancelInteraction(notifyingCallbacks: false)").count - 1 >= 2)
        #expect(source.contains("deinit {\n        cancelTransientInteraction(notifyingCallbacks: false)\n    }"))
        #expect(source.components(separatedBy: "deinit {\n        cancelInteraction(notifyingCallbacks: false)\n    }").count - 1 >= 2)
        #expect(source.contains("if window == nil {\n            cancelTransientInteraction(notifyingCallbacks: false)\n        }"))
        #expect(source.components(separatedBy: "if window == nil {\n            cancelInteraction(notifyingCallbacks: false)\n        }").count - 1 >= 2)
    }

    @Test func hudCardResizeStartsFromMeasuredCardSizeWithoutDefaultHeightFallback() throws {
        let measured = CGSize(width: 446, height: 344)

        #expect(PickyHUDDockLayout.resizeStartCardSize(storedSize: nil, measuredSize: measured) == PickyHUDCardSize(width: 446, height: 344))
        #expect(PickyHUDDockLayout.resizeStartCardSize(storedSize: nil, measuredSize: nil) == nil)
    }

    @Test func hudCardResizeSeedsMeasuredFallbackIntoDragStartSnapshot() throws {
        let displayKey = "42"
        let measured = CGSize(width: 446, height: 344)
        let snapshot = PickyHUDDockLayout.resizeStartCardSizes(
            storedSizes: [:],
            displayKey: displayKey,
            measuredSize: measured
        )
        let start = try #require(snapshot[displayKey])

        #expect(start == PickyHUDCardSize(width: 446, height: 344))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: -20, y: 0), dockSide: .right) == PickyHUDCardSize(width: 466, height: 344))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: -40, y: 0), dockSide: .right) == PickyHUDCardSize(width: 486, height: 344))
    }

    @Test func hudCardResizeStartSnapshotKeepsStoredSizeOverUpdatedMeasurements() throws {
        let displayKey = "42"
        let stored = PickyHUDCardSize(width: 446, height: 344)
        let updatedMeasurement = CGSize(width: 466, height: 344)

        let snapshot = PickyHUDDockLayout.resizeStartCardSizes(
            storedSizes: [displayKey: stored],
            displayKey: displayKey,
            measuredSize: updatedMeasurement
        )

        #expect(snapshot[displayKey] == stored)
    }

    @Test func hudCardResizeDeltaMapsToDockOrientation() throws {
        let start = PickyHUDCardSize(width: 446, height: 420)

        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: -40, y: -30), dockSide: .right) == PickyHUDCardSize(width: 486, height: 450))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: 40, y: -30), dockSide: .left) == PickyHUDCardSize(width: 486, height: 450))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: 40, y: -30), dockSide: .top) == PickyHUDCardSize(width: 486, height: 450))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: 40, y: 30), dockSide: .bottom) == PickyHUDCardSize(width: 486, height: 450))
    }

    @Test func hudCardResizeClampsToAllowedBounds() throws {
        let start = PickyHUDCardSize(width: 446, height: 420)

        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: -10_000, y: -10_000), dockSide: .right) == PickyHUDCardSize(width: 10_000, height: 10_000))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: 10_000, y: 10_000), dockSide: .right) == PickyHUDCardSize(width: 360, height: 320))
        #expect(PickyHUDDockLayout.resizedCardSize(from: start, delta: CGPoint(x: -10_000, y: -10_000), dockSide: .right, maxWidth: 500, maxHeight: 500) == PickyHUDCardSize(width: 500, height: 500))
    }

    @Test func hudPanelWidthTracksResizableCardWidth() throws {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let width = PickyHUDDockLayout.panelWidth(
            cardWidth: 520,
            dockSide: .right,
            sessionCount: 3,
            isAddSlotExpanded: false,
            metrics: metrics
        )

        #expect(width == 520 + PickyHUDDockLayout.panelGap + metrics.railWidth + 2 * PickyHUDExpansion.outerPadding)
    }

    @Test func hudChromeUsesSoftShadowWithShadowBleedPadding() throws {
        #expect(PickyHUDExpansion.outerPadding == PickyHUDExpansion.dockShadowHorizontalPadding)
        #expect(PickyHUDExpansion.dockShadowHorizontalPadding == PickyHUDExpansion.dockShadowRadius + PickyHUDExpansion.dockShadowHorizontalExtraBleed)
        #expect(PickyHUDExpansion.dockShadowTopPadding == PickyHUDExpansion.dockShadowRadius + PickyHUDExpansion.dockShadowVerticalExtraBleed)
        #expect(PickyHUDExpansion.dockShadowBottomPadding == PickyHUDExpansion.dockShadowRadius + PickyHUDExpansion.dockShadowYOffset + PickyHUDExpansion.dockShadowVerticalExtraBleed)
        #expect(PickyHUDExpansion.dockShadowBottomPadding > PickyHUDExpansion.dockShadowTopPadding)
        #expect(PickyHUDExpansion.dockShadowVerticalPadding == PickyHUDExpansion.dockShadowTopPadding + PickyHUDExpansion.dockShadowBottomPadding)
        #expect(PickyHUDDockLayout.detailWidth + PickyHUDDockLayout.panelGap + PickyHUDDockLayout.railWidth + 2 * PickyHUDExpansion.outerPadding <= PickyHUDDockLayout.panelWidth)
        #expect(PickyHUDExpansion.cardShadowOpacity < 0.2)
        #expect(PickyHUDExpansion.cardShadowRadius <= 8)
        #expect(PickyHUDExpansion.cardShadowYOffset <= 4)
    }

    @Test func hudExpandedContentShowsFullSummaryAndHidesRecentLog() throws {
        #expect(PickyHUDExpandedContentPolicy.summaryLineLimit == nil)
        #expect(!PickyHUDExpandedContentPolicy.showsRecentLog)
        #expect(!PickyHUDExpandedContentPolicy.showsSummary(for: .queued))
        #expect(!PickyHUDExpandedContentPolicy.showsSummary(for: .running))
        #expect(!PickyHUDExpandedContentPolicy.showsSummary(for: .waiting_for_input))
        #expect(PickyHUDExpandedContentPolicy.showsSummary(for: .blocked))
        #expect(PickyHUDExpandedContentPolicy.showsSummary(for: .completed))
        #expect(PickyHUDExpandedContentPolicy.showsSummary(for: .failed))
        #expect(PickyHUDExpandedContentPolicy.showsSummary(for: .cancelled))
    }

    @Test func hudCurrentWorkShowsOnlyToolNameAndThinkingPreview() throws {
        let tool = PickyToolActivity(
            toolCallId: "tool-1",
            name: "bash",
            status: "running",
            preview: "Agent started",
            startedAt: nil,
            endedAt: nil
        )

        #expect(PickyHUDCurrentWorkPolicy.runningDescription(
            activeTool: tool,
            thinkingPreview: "  사용자의 HUD 요청을 확인 중입니다.  "
        ) == "Tool: bash\nThinking: 사용자의 HUD 요청을 확인 중입니다.")

        #expect(PickyHUDCurrentWorkPolicy.runningDescription(
            activeTool: nil,
            thinkingPreview: "thinking only"
        ) == "Thinking: thinking only")

        #expect(PickyHUDCurrentWorkPolicy.runningDescription(
            activeTool: nil,
            thinkingPreview: nil
        ) == nil)
    }

    @Test func linkBadgeArtifactsClassifyKnownWorkURLs() throws {
        let pullRequest = PickyArtifact(
            id: "pr-1",
            kind: "pr",
            title: "GitHub PR",
            path: nil,
            url: URL(string: "https://github.com/acme/repo/pull/42")!,
            updatedAt: Date()
        )
        let issue = PickyArtifact(
            id: "github-1",
            kind: "github",
            title: "#2777",
            path: nil,
            url: URL(string: "https://github.com/acme/repo/issues/2777")!,
            updatedAt: Date()
        )
        let slack = PickyArtifact(
            id: "slack-1",
            kind: "slack",
            title: "Slack",
            path: nil,
            url: URL(string: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249")!,
            updatedAt: Date()
        )
        let notion = PickyArtifact(
            id: "notion-1",
            kind: "notion",
            title: "Notion",
            path: nil,
            url: URL(string: "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226")!,
            updatedAt: Date()
        )
        let jira = PickyArtifact(id: "jira-1", kind: "jira", title: "COM-123", path: nil, url: URL(string: "https://example.atlassian.net/browse/COM-123")!, updatedAt: Date())
        let sentry = PickyArtifact(id: "sentry-1", kind: "sentry", title: "Sentry", path: nil, url: URL(string: "https://example.sentry.io/issues/1234567890/")!, updatedAt: Date())
        let linear = PickyArtifact(id: "linear-1", kind: "linear", title: "ENG-456", path: nil, url: URL(string: "https://linear.app/acme/issue/ENG-456/fix-checkout")!, updatedAt: Date())
        let figma = PickyArtifact(id: "figma-1", kind: "figma", title: "Figma", path: nil, url: URL(string: "https://www.figma.com/design/abc123/Product")!, updatedAt: Date())
        let docs = PickyArtifact(id: "docs-1", kind: "googleDocs", title: "Docs", path: nil, url: URL(string: "https://docs.google.com/document/d/doc123/edit")!, updatedAt: Date())
        let sheets = PickyArtifact(id: "sheets-1", kind: "googleSheets", title: "Sheets", path: nil, url: URL(string: "https://docs.google.com/spreadsheets/d/sheet123/edit")!, updatedAt: Date())
        let slides = PickyArtifact(id: "slides-1", kind: "googleSlides", title: "Slides", path: nil, url: URL(string: "https://docs.google.com/presentation/d/slide123/edit")!, updatedAt: Date())
        let drive = PickyArtifact(id: "drive-1", kind: "googleDrive", title: "Drive", path: nil, url: URL(string: "https://drive.google.com/file/d/file123/view")!, updatedAt: Date())

        #expect(pullRequest.linkBadgeKind == .github)
        #expect(pullRequest.githubIssueOrPullRequestNumber == "42")
        #expect(issue.linkBadgeKind == .github)
        #expect(issue.githubIssueOrPullRequestNumber == "2777")
        #expect(slack.linkBadgeKind == .slack)
        #expect(notion.linkBadgeKind == .notion)
        #expect(jira.linkBadgeKind == .jira)
        #expect(jira.jiraIssueKey == "COM-123")
        #expect(sentry.linkBadgeKind == .sentry)
        #expect(linear.linkBadgeKind == .linear)
        #expect(linear.linearIssueKey == "ENG-456")
        #expect(figma.linkBadgeKind == .figma)
        #expect(docs.linkBadgeKind == .googleDocs)
        #expect(sheets.linkBadgeKind == .googleSheets)
        #expect(slides.linkBadgeKind == .googleSlides)
        #expect(drive.linkBadgeKind == .googleDrive)
    }

    @Test func sessionCardShowsMeaningfulLinkTextOnlyOrDuplicateIndexes() throws {
        let github = PickyArtifact(id: "github-1", kind: "github", title: "#42", path: nil, url: URL(string: "https://github.com/acme/repo/pull/42")!, updatedAt: Date())
        let jira = PickyArtifact(id: "jira-1", kind: "jira", title: "COM-123", path: nil, url: URL(string: "https://example.atlassian.net/browse/COM-123")!, updatedAt: Date())
        let linear = PickyArtifact(id: "linear-1", kind: "linear", title: "ENG-456", path: nil, url: URL(string: "https://linear.app/acme/issue/ENG-456/fix-checkout")!, updatedAt: Date())
        let slack = PickyArtifact(id: "slack-1", kind: "slack", title: "Slack", path: nil, url: URL(string: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249")!, updatedAt: Date())
        let notion1 = PickyArtifact(id: "notion-1", kind: "notion", title: "Notion", path: nil, url: URL(string: "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226")!, updatedAt: Date())
        let notion2 = PickyArtifact(id: "notion-2", kind: "notion", title: "Notion", path: nil, url: URL(string: "https://app.notion.com/p/351d62c6956180498d13e3494b488192")!, updatedAt: Date())
        let card = PickySessionListViewModel.SessionCard.fixture(artifacts: [github, jira, linear, slack, notion1, notion2])

        #expect(card.linkBadgeText(for: github) == "#42")
        #expect(card.linkBadgeText(for: jira) == "COM-123")
        #expect(card.linkBadgeText(for: linear) == "ENG-456")
        #expect(card.linkBadgeText(for: slack) == nil)
        #expect(card.linkBadgeText(for: notion1) == "#1")
        #expect(card.linkBadgeText(for: notion2) == "#2")
    }

    @Test func sessionCardSuppressesGitHubArtifactsThatDuplicateTheCurrentBranchPR() throws {
        let prURL = URL(string: "https://github.com/acme/repo/pull/42")!
        let prArtifact = PickyArtifact(id: "a", kind: "pr", title: "#42", path: nil, url: prURL, updatedAt: Date())
        let issueArtifact = PickyArtifact(id: "b", kind: "github", title: "#42 issue", path: nil, url: URL(string: "https://github.com/acme/repo/issues/42")!, updatedAt: Date())
        let differentRepoPR = PickyArtifact(id: "c", kind: "pr", title: "#42", path: nil, url: URL(string: "https://github.com/other/proj/pull/42")!, updatedAt: Date())
        let differentNumberPR = PickyArtifact(id: "d", kind: "pr", title: "#43", path: nil, url: URL(string: "https://github.com/acme/repo/pull/43")!, updatedAt: Date())
        let slackArtifact = PickyArtifact(id: "e", kind: "slack", title: "Slack", path: nil, url: URL(string: "https://example.slack.com/archives/C012/p1")!, updatedAt: Date())
        let card = PickySessionListViewModel.SessionCard.fixture(
            artifacts: [prArtifact, issueArtifact, differentRepoPR, differentNumberPR, slackArtifact]
        )

        let pr = PickyGitHubPullRequestStatus(number: 42, title: "Fix", url: prURL, state: .open)
        let visible = card.linkBadgeArtifacts(suppressingPullRequest: pr)
        let visibleIDs = visible.map(\.id)

        // The artifact pointing at the same PR is hidden; everything else stays.
        #expect(visibleIDs == ["b", "c", "d", "e"])

        // No PR: every link badge artifact remains.
        #expect(card.linkBadgeArtifacts(suppressingPullRequest: nil).map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test func githubRepositoryPathExtractsOwnerAndRepo() throws {
        let card = PickySessionListViewModel.SessionCard.self
        #expect(card.githubRepositoryPath(of: URL(string: "https://github.com/Acme/Repo/pull/1")!) == "acme/repo")
        #expect(card.githubRepositoryPath(of: URL(string: "https://github.com/owner/repo")!) == "owner/repo")
        #expect(card.githubRepositoryPath(of: URL(string: "https://gitlab.com/owner/repo/pull/1")!) == nil)
        #expect(card.githubRepositoryPath(of: URL(string: "https://github.com/owner")!) == nil)
    }

    @Test func hudPanelCanBecomeKeyForFollowUpTextInput() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func hudPanelResignsFocusedControlBeforeHandlingMouseCollapse() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let probeView = FirstResponderProbeView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let contentView = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 180))
        contentView.addSubview(probeView)
        panel.contentView = contentView
        defer { panel.close() }

        #expect(panel.makeFirstResponder(probeView))
        #expect(panel.firstResponder === probeView)

        #expect(panel.resignFocusedControl())
        #expect(panel.firstResponder !== probeView)
    }

    @Test func hudPanelKeepsFocusedControlWhenClickStaysInsideIt() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let probeView = FirstResponderProbeView(frame: NSRect(x: 40, y: 40, width: 80, height: 30))
        let contentView = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 180))
        contentView.addSubview(probeView)
        panel.contentView = contentView
        defer { panel.close() }

        #expect(panel.makeFirstResponder(probeView))

        let insideEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 60, y: 55),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(panel.clickHitsFocusedControl(insideEvent))

        let outsideEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(!panel.clickHitsFocusedControl(outsideEvent))
    }

    @MainActor @Test func selectionDefaultsForHudButOnlyExplicitSelectionPersistsForHoveredVoiceFollowUp() {
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "older", status: "completed", updatedAt: "2026-05-01T00:00:01.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "newer", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))

        #expect(viewModel.selectedSession?.id == "newer")
        #expect(selection.selectedSessionID == nil)

        viewModel.beginHoveredVoiceFollowUp(sessionID: "older")
        #expect(viewModel.hoveredVoiceFollowUpSessionID == "older")
        #expect(selection.hoveredVoiceFollowUpSessionID == "older")

        viewModel.endHoveredVoiceFollowUp(sessionID: "older")
        #expect(viewModel.hoveredVoiceFollowUpSessionID == nil)
        #expect(selection.hoveredVoiceFollowUpSessionID == nil)

        viewModel.select(sessionID: "older")
        #expect(selection.selectedSessionID == "older")
    }

    @MainActor @Test func requestOpenSessionPublishesFreshRequestAndSelectsExistingSession() throws {
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "notified", status: "completed"))))

        viewModel.requestOpenSession(sessionID: "notified")
        let firstRequest = try #require(viewModel.openSessionRequest)
        #expect(firstRequest.sessionID == "notified")
        #expect(selection.selectedSessionID == "notified")

        viewModel.requestOpenSession(sessionID: "notified")
        let secondRequest = try #require(viewModel.openSessionRequest)
        #expect(secondRequest.sessionID == "notified")
        #expect(secondRequest.id != firstRequest.id)
    }

    @Test func requestOpenSessionStillPublishesWhenSessionArrivesLater() throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.requestOpenSession(sessionID: "not-yet-loaded")

        #expect(viewModel.openSessionRequest?.sessionID == "not-yet-loaded")
    }

    @MainActor @Test func screenContextTargetDoesNotAttachToComposerFollowUp() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-screen", status: "completed"))))

        viewModel.toggleScreenContextTarget(sessionID: "pickle-screen")
        #expect(viewModel.screenContextTargetSessionID == "pickle-screen")
        #expect(selection.screenContextTargetSessionID == "pickle-screen")

        try await viewModel.followUp(text: "일반 카드 팔로업", sessionID: "pickle-screen")

        #expect(client.sentCommands.last?.type == .followUp)
        #expect(client.sentCommands.last?.context == nil)
        #expect(viewModel.screenContextTargetSessionID == "pickle-screen")
        #expect(selection.screenContextTargetSessionID == "pickle-screen")
    }

    @MainActor @Test func screenContextTargetDoesNotAttachToComposerSteer() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-running", status: "running"))))

        viewModel.toggleScreenContextTarget(sessionID: "pickle-running")
        try await viewModel.steer(text: "일반 카드 스티어", sessionID: "pickle-running")

        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.context == nil)
        #expect(viewModel.screenContextTargetSessionID == "pickle-running")
        #expect(selection.screenContextTargetSessionID == "pickle-running")
    }

    @MainActor @Test func toggleScreenContextTargetArmsOneShotByDefault() {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-sticky", status: "completed"))))

        viewModel.toggleScreenContextTarget(sessionID: "pickle-sticky")

        #expect(viewModel.screenContextTargetSessionID == "pickle-sticky")
        #expect(viewModel.screenContextTargetSticky == false)
        #expect(selection.screenContextTargetSticky == false)
    }

    @MainActor @Test func armScreenContextTargetStickyPersistsAcrossDisarmRequests() {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-locked", status: "completed"))))

        viewModel.armScreenContextTarget(sessionID: "pickle-locked", sticky: true)

        #expect(viewModel.screenContextTargetSessionID == "pickle-locked")
        #expect(viewModel.screenContextTargetSticky == true)
        #expect(selection.screenContextTargetSessionID == "pickle-locked")
        #expect(selection.screenContextTargetSticky == true)
    }

    @MainActor @Test func armScreenContextTargetBumpsCollapseToken() {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-token", status: "completed"))))

        let before = viewModel.screenContextArmCollapseToken
        viewModel.toggleScreenContextTarget(sessionID: "pickle-token")
        let afterTap = viewModel.screenContextArmCollapseToken
        viewModel.armScreenContextTarget(sessionID: "pickle-token", sticky: true)
        let afterSticky = viewModel.screenContextArmCollapseToken

        #expect(before != afterTap)
        #expect(afterTap != afterSticky)
    }

    @MainActor @Test func armingAnotherPickleReplacesStickyTarget() {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-a", status: "completed"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-b", status: "completed"))))

        viewModel.armScreenContextTarget(sessionID: "pickle-a", sticky: true)
        viewModel.toggleScreenContextTarget(sessionID: "pickle-b")

        #expect(viewModel.screenContextTargetSessionID == "pickle-b")
        #expect(viewModel.screenContextTargetSticky == false)
        #expect(selection.screenContextTargetSessionID == "pickle-b")
        #expect(selection.screenContextTargetSticky == false)
    }

    @MainActor @Test func clearScreenContextTargetResetsStickyFlag() {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-clear", status: "completed"))))

        viewModel.armScreenContextTarget(sessionID: "pickle-clear", sticky: true)
        viewModel.clearScreenContextTarget(sessionID: "pickle-clear")

        #expect(viewModel.screenContextTargetSessionID == nil)
        #expect(viewModel.screenContextTargetSticky == false)
        #expect(selection.screenContextTargetSessionID == nil)
        #expect(selection.screenContextTargetSticky == false)
    }

    @Test func activeVoiceFollowUpTargetPersistsAfterHoverEndsUntilVoiceInputClears() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()
        defer {
            NotificationCenter.default.post(name: .pickyVoiceFollowUpTargetChanged, object: nil, userInfo: [:])
        }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-voice", status: "running"))))
        try await settle()
        viewModel.beginHoveredVoiceFollowUp(sessionID: "pickle-voice")
        NotificationCenter.default.post(
            name: .pickyVoiceFollowUpTargetChanged,
            object: nil,
            userInfo: [PickyVoiceFollowUpTargetNotification.sessionIDKey: "pickle-voice"]
        )
        try await settle()

        viewModel.endHoveredVoiceFollowUp(sessionID: "pickle-voice")

        #expect(viewModel.hoveredVoiceFollowUpSessionID == nil)
        #expect(viewModel.activeVoiceFollowUpSessionID == "pickle-voice")

        NotificationCenter.default.post(name: .pickyVoiceFollowUpTargetChanged, object: nil, userInfo: [:])
        try await settle()

        #expect(viewModel.activeVoiceFollowUpSessionID == nil)
    }

    @Test func activeVoiceFollowUpTargetClearsWhenSessionDisappears() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        defer {
            NotificationCenter.default.post(name: .pickyVoiceFollowUpTargetChanged, object: nil, userInfo: [:])
        }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-voice", status: "running"))))
        try await settle()
        NotificationCenter.default.post(
            name: .pickyVoiceFollowUpTargetChanged,
            object: nil,
            userInfo: [PickyVoiceFollowUpTargetNotification.sessionIDKey: "pickle-voice"]
        )
        try await wait { viewModel.activeVoiceFollowUpSessionID == "pickle-voice" }
        #expect(viewModel.activeVoiceFollowUpSessionID == "pickle-voice")

        client.emit(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-empty","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:10.000Z","type":"sessionSnapshot","sessions":[]}
        """)))
        try await settle()

        #expect(viewModel.activeVoiceFollowUpSessionID == nil)
    }

    @Test func archivedSessionsStayHiddenAcrossSnapshots() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "main-1", title: "Main", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "pickle-1")
        // setSessionArchived 명령 송신은 Task로 분리돼 archiveStore보다 늦게 도착함.
        // 가장 늦은 효과(client.sentCommands)를 predicate로 잡아야 후속 require가
        // 안전.
        try await wait { client.sentCommands.contains { $0.type == .setSessionArchived } }
        #expect(archiveStore.archivedSessionIDs == ["pickle-1"])
        #expect(viewModel.sessions.map(\.id) == ["main-1"])
        let archiveCommand = try #require(client.sentCommands.first { $0.type == .setSessionArchived })
        #expect(archiveCommand.sessionId == "pickle-1")
        #expect(archiveCommand.archived == true)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Updated"))))
        // 아카이브 카드 lastSummary 갱신이 sessions 재정렬보다 늦게 도착하므로
        // 그 조건을 predicate로 잡아야 안전.
        try await wait { viewModel.archivedSessions.first(where: { $0.id == "pickle-1" })?.lastSummary == "Updated" }
        #expect(viewModel.sessions.map(\.id) == ["main-1"])
        #expect(viewModel.archivedSessions.first(where: { $0.id == "pickle-1" })?.lastSummary == "Updated")
    }

    @MainActor @Test func sessionSnapshotPrunesManualArchiveIDsForRemovedSessions() {
        let archiveStore = FakeArchiveStore()
        archiveStore.manuallyArchivedSessionIDs = ["alive", "ghost"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "alive", status: "running"))))

        #expect(archiveStore.manuallyArchivedSessionIDs == ["alive"])
    }

    @MainActor @Test func sessionSnapshotHydratesArchivedFromDaemonFlagWhenLocalStateEmpty() {
        // Simulates a Picky restart where local UserDefaults `manuallyArchivedSessionIDs`
        // is empty (e.g. cleared, fresh container) but the daemon still has sessions
        // persisted with `archived: true`. Without the snapshot-time hydration, every
        // archived session would resurface in the active dock.
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "archived-1", status: "completed", archived: true))))

        #expect(viewModel.sessions.map(\.id) == [])
        #expect(viewModel.archivedSessions.map(\.id) == ["archived-1"])
        #expect(archiveStore.manuallyArchivedSessionIDs == ["archived-1"])
    }

    @MainActor @Test func sessionSnapshotDoesNotWipeManualArchiveIDsOnEmptySnapshot() {
        // Guards against the regression where an empty snapshot (transient or partial)
        // would intersect manuallyArchivedSessionIDs with an empty universe and wipe
        // every archived ID from UserDefaults.
        let archiveStore = FakeArchiveStore()
        archiveStore.manuallyArchivedSessionIDs = ["keep-1", "keep-2"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )

        let emptySnapshot = """
        {"id":"snapshot-empty","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionSnapshot","sessions":[]}
        """
        viewModel.apply(.protocolEvent(.fixture(eventJSON: emptySnapshot)))

        #expect(archiveStore.manuallyArchivedSessionIDs == ["keep-1", "keep-2"])
    }

    @Test func archiveReleasesChildAfterUndoWindowExpires() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let releaser = FakeChildSessionReleaser()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore,
            childSessionReleaser: releaser,
            archiveCommitDelayNanoseconds: 50_000_000
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "pickle-1")
        #expect(releaser.releasedSessionIDs.isEmpty)

        try await wait { releaser.releasedSessionIDs == ["pickle-1"] }
        #expect(releaser.releasedSessionIDs == ["pickle-1"])
    }

    @Test func archiveKeepsRunningChildAfterUndoWindowExpires() async throws {
        let archiveStore = FakeArchiveStore()
        let releaser = FakeChildSessionReleaser()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore,
            childSessionReleaser: releaser,
            archiveCommitDelayNanoseconds: 50_000_000
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))

        viewModel.archive(sessionID: "pickle-1")

        // Wait past the 50ms commit delay so the test actually proves the
        // running pickle stays unreleased after the undo window — not just
        // "unreleased immediately".
        try await settle()
        #expect(releaser.releasedSessionIDs.isEmpty)
    }

    @Test func archiveReleasesRunningChildWhenItCompletesAfterUndoWindowExpires() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let releaser = FakeChildSessionReleaser()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore,
            childSessionReleaser: releaser,
            archiveCommitDelayNanoseconds: 50_000_000
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        try await settle()

        viewModel.archive(sessionID: "pickle-1")
        try await settle()
        #expect(releaser.releasedSessionIDs.isEmpty)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            updatedAt: "2026-05-01T00:00:05.000Z"
        ))))
        try await wait { releaser.releasedSessionIDs == ["pickle-1"] }

        #expect(releaser.releasedSessionIDs == ["pickle-1"])
    }

    @Test func unarchiveWithinUndoWindowCancelsChildRelease() async throws {
        let archiveStore = FakeArchiveStore()
        let releaser = FakeChildSessionReleaser()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore,
            childSessionReleaser: releaser,
            archiveCommitDelayNanoseconds: 50_000_000
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed"))))

        viewModel.archive(sessionID: "pickle-1")
        viewModel.unarchive(sessionID: "pickle-1")

        // Wait past the 50ms commit delay to prove the scheduled release
        // was truly cancelled by unarchive, not just deferred.
        try await settle()
        #expect(releaser.releasedSessionIDs.isEmpty)
    }

    @Test func unarchiveRestoresSessionAndClearsManualArchiveState() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "pickle-1")
        try await settle()
        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["pickle-1"])

        viewModel.unarchive(sessionID: "pickle-1")
        try await settle()

        #expect(archiveStore.archivedSessionIDs.isEmpty)
        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        #expect(viewModel.sessions.map(\.id) == ["pickle-1"])
        #expect(viewModel.archivedSessions.isEmpty)
        let unarchiveCommand = try #require(client.sentCommands.last { $0.type == .setSessionArchived })
        #expect(unarchiveCommand.sessionId == "pickle-1")
        #expect(unarchiveCommand.archived == false)
    }

    @Test func deleteArchivedSessionPurgesLocallyAndSendsDaemonCommand() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "pickle-1")
        try await settle()
        #expect(viewModel.archivedSessions.map(\.id) == ["pickle-1"])

        viewModel.deleteArchivedSession(sessionID: "pickle-1")
        try await settle()

        #expect(viewModel.archivedSessions.isEmpty)
        #expect(viewModel.sessions.isEmpty)
        #expect(archiveStore.archivedSessionIDs.isEmpty)
        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        let deleteCommand = try #require(client.sentCommands.last { $0.type == .deleteSession })
        #expect(deleteCommand.sessionId == "pickle-1")
    }

    @Test func deleteAllArchivedSessionsPurgesEveryArchivedRowAndSendsDaemonCommands() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        for id in ["pickle-1", "pickle-2", "pickle-3"] {
            client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: id, title: id, status: "completed"))))
            try await settle()
            viewModel.archive(sessionID: id)
            try await settle()
        }
        #expect(Set(viewModel.archivedSessions.map(\.id)) == ["pickle-1", "pickle-2", "pickle-3"])

        viewModel.deleteAllArchivedSessions()
        try await settle()

        #expect(viewModel.archivedSessions.isEmpty)
        #expect(viewModel.sessions.isEmpty)
        #expect(archiveStore.archivedSessionIDs.isEmpty)
        #expect(archiveStore.manuallyArchivedSessionIDs.isEmpty)
        let deleteCommandIDs = Set(client.sentCommands.filter { $0.type == .deleteSession }.compactMap(\.sessionId))
        #expect(deleteCommandIDs == ["pickle-1", "pickle-2", "pickle-3"])
    }

    @Test func deleteAllArchivedSessionsIsSafeNoOpWhenArchiveIsEmpty() async throws {
        // Header-level "Delete all" should not fire envelopes or mutate state
        // when there are no archived rows — the button is hidden in that
        // case but a misroute (deep link, programmatic call, race) must
        // remain harmless.
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        try await settle()
        #expect(viewModel.archivedSessions.isEmpty)

        viewModel.deleteAllArchivedSessions()
        try await settle()

        #expect(viewModel.archivedSessions.isEmpty)
        #expect(!client.sentCommands.contains { $0.type == .deleteSession })
    }

    // MARK: - Manual dock reorder

    @MainActor @Test func moveSessionSeedsManualOrderAndReorders() {
        let orderStore = FakeManualOrderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        // Three sessions arrive with createdAt newest → oldest = a > b > c.
        // Default order (no drag yet): sessions = [a, b, c] (newest first).
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "c", title: "C", status: "running", createdAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "b", title: "B", status: "running", createdAt: "2026-05-01T00:00:10.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "a", title: "A", status: "running", createdAt: "2026-05-01T00:00:20.000Z"))))

        #expect(viewModel.sessions.map(\.id) == ["a", "b", "c"]) // newest first, no manual order yet
        #expect(orderStore.manualOrder.isEmpty)

        // Visible order = sessions.prefix.reversed() = [c, b, a]. Drag the
        // icon at visual idx 2 (a) to visual idx 0. Standard move semantics:
        // visible becomes [a, c, b]. Reversing back to underlying sessions
        // order (= prefix.reversed of visible) gives [b, c, a].
        let moved = viewModel.moveSession(sessionID: "a", toVisibleIndex: 0)
        #expect(moved)
        #expect(viewModel.sessions.map(\.id) == ["b", "c", "a"])
        // manualOrder mirrors sessions order (newest position first).
        #expect(orderStore.manualOrder == ["b", "c", "a"])
    }

    @MainActor @Test func moveSessionIsNoOpWhenTargetEqualsCurrentIndex() {
        let orderStore = FakeManualOrderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "a", title: "A", status: "running", createdAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "b", title: "B", status: "running", createdAt: "2026-05-01T00:00:10.000Z"))))

        // sessions = [b, a]; visible = [a, b]; b's visible idx = 1.
        let didMove = viewModel.moveSession(sessionID: "b", toVisibleIndex: 1)
        #expect(!didMove)
        // Stays in the no-manual-order baseline.
        #expect(orderStore.manualOrder.isEmpty)
    }

    @MainActor @Test func newSessionLandsOnVisualEndAfterManualReorder() {
        let orderStore = FakeManualOrderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "b", title: "B", status: "running", createdAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "a", title: "A", status: "running", createdAt: "2026-05-01T00:00:10.000Z"))))
        // sessions = [a, b]; visible = [b, a]. Reorder a to visible idx 0.
        _ = viewModel.moveSession(sessionID: "a", toVisibleIndex: 0)
        #expect(viewModel.sessions.map(\.id) == ["b", "a"]) // manual order locked

        // A brand new session arrives. It must land at the visually-end slot
        // (= sessions[0]) regardless of where the user dragged existing ones.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "new", title: "New", status: "running", createdAt: "2026-05-01T00:00:20.000Z"))))

        #expect(viewModel.sessions.map(\.id) == ["new", "b", "a"])
        #expect(orderStore.manualOrder == ["new", "b", "a"])
    }

    @MainActor @Test func archivePrunesManualOrderEntryWhenSessionLeavesUniverse() {
        let orderStore = FakeManualOrderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "b", title: "B", status: "completed", createdAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "a", title: "A", status: "completed", createdAt: "2026-05-01T00:00:10.000Z"))))
        _ = viewModel.moveSession(sessionID: "a", toVisibleIndex: 0) // seed + reorder
        #expect(orderStore.manualOrder == ["b", "a"])

        viewModel.archive(sessionID: "a")

        // "a" left the active+archived universe (archive moves it to archived
        // pool which is still in universe — we keep its slot so unarchive
        // restores). Verify the still-active id ordering survives.
        #expect(viewModel.sessions.map(\.id) == ["b"])
        #expect(orderStore.manualOrder.contains("b"))
    }

    @MainActor @Test func resetManualSessionOrderRestoresCreatedAtFallback() {
        let orderStore = FakeManualOrderStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "b", title: "B", status: "running", createdAt: "2026-05-01T00:00:00.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "a", title: "A", status: "running", createdAt: "2026-05-01T00:00:10.000Z"))))
        _ = viewModel.moveSession(sessionID: "a", toVisibleIndex: 0)
        #expect(viewModel.sessions.map(\.id) == ["b", "a"]) // locked to manual order

        viewModel.resetManualSessionOrder()

        #expect(orderStore.manualOrder.isEmpty)
        #expect(viewModel.sessions.map(\.id) == ["a", "b"]) // fallback to createdAt desc
    }

    @MainActor @Test func manualOrderStoreSeedsInitialState() {
        let orderStore = FakeManualOrderStore()
        // Persisted manual order from a previous session.
        orderStore.manualOrder = ["c", "a", "b"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore
        )
        // Send all three sessions in one snapshot — mirrors how production
        // delivers the initial state after connect, where manualOrder must be
        // applied wholesale before any per-id pruning would drop entries.
        let snapshotJSON = """
        {"id":"snapshot-multi","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:30.000Z","type":"sessionSnapshot","sessions":[
            {"id":"a","title":"A","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"a","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"b","title":"B","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:10.000Z","updatedAt":"2026-05-01T00:00:10.000Z","lastSummary":"b","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"c","title":"C","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:20.000Z","updatedAt":"2026-05-01T00:00:20.000Z","lastSummary":"c","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}
        ]}
        """
        viewModel.apply(.protocolEvent(.fixture(eventJSON: snapshotJSON)))

        // Order from store wins, not createdAt.
        #expect(viewModel.sessions.map(\.id) == ["c", "a", "b"])
    }

    // MARK: - Dock layout controller seam

    @MainActor @Test func dockLayoutStoreSeedsInitialPublishedLayout() {
        let dockLayoutStore = FakeViewModelDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(
                id: "g",
                name: "G",
                color: .teal,
                memberSessionIDs: ["b"]
            ))
        ]))
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            dockLayoutStore: dockLayoutStore
        )

        #expect(viewModel.dockLayout.testEntryDescriptions == ["session:a", "group:g[b]"])
        #expect(dockLayoutStore.savedLayouts.isEmpty)
    }

    @MainActor @Test func dockLayoutMigratesManualOrderThroughViewModelReconcile() {
        let orderStore = FakeManualOrderStore()
        orderStore.manualOrder = ["c", "a", "b"]
        let dockLayoutStore = FakeViewModelDockLayoutStore()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            selectionStore: FakeSelectionStore(),
            archiveStore: FakeArchiveStore(),
            manualOrderStore: orderStore,
            dockLayoutStore: dockLayoutStore
        )
        let snapshotJSON = """
        {"id":"snapshot-dock-layout","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:30.000Z","type":"sessionSnapshot","sessions":[
            {"id":"a","title":"A","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"a","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"b","title":"B","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:10.000Z","updatedAt":"2026-05-01T00:00:10.000Z","lastSummary":"b","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},
            {"id":"c","title":"C","status":"running","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:20.000Z","updatedAt":"2026-05-01T00:00:20.000Z","lastSummary":"c","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}
        ]}
        """

        viewModel.apply(.protocolEvent(.fixture(eventJSON: snapshotJSON)))

        #expect(viewModel.sessions.map(\.id) == ["c", "a", "b"])
        #expect(viewModel.dockLayout.testSessionIDs == ["b", "a", "c"])
        #expect(dockLayoutStore.savedLayouts.map(\.testSessionIDs) == [["b", "a", "c"]])
    }

    @Test func removeDockGroupArchivesMembersAndPersistsThroughViewModel() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let dockLayoutStore = FakeViewModelDockLayoutStore(layout: PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(
                id: "g",
                name: "G",
                color: .red,
                memberSessionIDs: ["b", "c"]
            ))
        ]))
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore,
            dockLayoutStore: dockLayoutStore
        )

        viewModel.removeDockGroup(id: "g", keepMembers: false)

        try await wait { client.sentCommands.filter { $0.type == .setSessionArchived }.count == 2 }
        #expect(viewModel.dockLayout.testSessionIDs == ["a"])
        #expect(dockLayoutStore.savedLayouts.map(\.testSessionIDs) == [["a"]])
        #expect(archiveStore.manuallyArchivedSessionIDs == ["b", "c"])
        let archivedCommandIDs = Set(
            client.sentCommands
                .filter { $0.type == .setSessionArchived && $0.archived == true }
                .compactMap(\.sessionId)
        )
        #expect(archivedCommandIDs == ["b", "c"])
    }

    @MainActor @Test func copyTerminalResumeCommandUsesCapturedPiSessionFileAndCwd() {
        let notifications = PickyNoopNotificationCenter()
        let clipboard = FakeClipboardWriter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: notifications,
            clipboardWriter: clipboard
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))

        viewModel.copyTerminalResumeCommand(sessionID: "pickle-1")

        #expect(clipboard.copied == ["cd '\(testProjectCwd)' && pi --session '/tmp/pi-session.jsonl'"])
        // Resume command intentionally no longer fires a macOS banner; clipboard write is the
        // only visible feedback so users do not get a redundant notification on every copy.
        #expect(!notifications.delivered.contains(where: { $0.title == "Pi resume command copied" }))
        #expect(viewModel.lastError == nil)
    }

    @MainActor @Test func openTerminalOverlayUsesCapturedPiSessionFileAndCwd() {
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))

        viewModel.openTerminalOverlay(sessionID: "pickle-1")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-1",
            title: "Pickle",
            sessionFilePath: "/tmp/pi-session.jsonl",
            cwd: testProjectCwd
        )])
        #expect(viewModel.lastError == nil)
    }

    @MainActor @Test func openTerminalOverlayUsesExplicitPiSessionFileWhenLogsAreCompacted() {
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-explicit",
            title: "Pickle",
            status: "completed",
            logs: ["recent compacted log without session path"],
            piSessionFilePath: "/tmp/explicit-pi-session.jsonl"
        ))))

        viewModel.openTerminalOverlay(sessionID: "pickle-explicit")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-explicit",
            title: "Pickle",
            sessionFilePath: "/tmp/explicit-pi-session.jsonl",
            cwd: testProjectCwd
        )])
        #expect(viewModel.lastError == nil)
    }

    @MainActor @Test func openTerminalOverlayWorksWhileSessionIsActive() {
        // Terminal overlay should stay clickable even while the Pickle is still working
        // (running, queued, waiting_for_input). The overlay launches its own `pi --session` process
        // pointed at the on-disk session file, so the user gets a transcript view of the live run
        // even though the daemon is still writing to it.
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))

        viewModel.openTerminalOverlay(sessionID: "pickle-1")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-1",
            title: "Pickle",
            sessionFilePath: "/tmp/pi-session.jsonl",
            cwd: testProjectCwd
        )])
        #expect(viewModel.lastError == nil)
    }

    @MainActor @Test func sessionCardExtractsPiSessionFileFromHandoffTranscript() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pinned-pickle",
            title: "Pinned",
            status: "completed",
            logs: ["source transcript:\n## Source Pi session\n- Session file: /tmp/from-handoff.jsonl"]
        ))))

        #expect(viewModel.sessions.first?.piSessionFilePath == "/tmp/from-handoff.jsonl")
    }

    @Test func inlineTerminalModeCapturesBaselineAndSyncsOnClose() async throws {
        let client = FakePickyAgentClient()
        let syncer = FakeTerminalSessionSyncer()
        syncer.snapshots["/tmp/pi-session.jsonl"] = PickyTerminalSessionSnapshot(
            lastUserText: "old question",
            lastAssistantText: "Old terminal answer",
            lastMessageId: "a1"
        )
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalSessionSyncer: syncer
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.enableInlineTerminalMode(sessionID: "pickle-1")
        #expect(viewModel.isInlineTerminalMode(sessionID: "pickle-1"))
        let session = try #require(viewModel.sessions.first)
        let firstInlineSession = try #require(viewModel.inlineTerminalSession(for: session))
        let secondInlineSession = try #require(viewModel.inlineTerminalSession(for: session))
        #expect(firstInlineSession === secondInlineSession)
        #expect(!client.sentCommands.contains(where: { $0.type == .syncTerminalSession }))

        viewModel.disableInlineTerminalMode(sessionID: "pickle-1")
        #expect(!viewModel.isInlineTerminalMode(sessionID: "pickle-1"))
        // syncTerminalSession 명령 송신이 Task로 분리돼 syncer 업데이트보다
        // 늦게 도착함. 가장 늦은 효과를 predicate로.
        try await wait { client.sentCommands.contains { $0.type == .syncTerminalSession } }

        #expect(syncer.paths == ["/tmp/pi-session.jsonl"])
        let command = try #require(client.sentCommands.last)
        #expect(command.type == .syncTerminalSession)
        #expect(command.sessionId == "pickle-1")
        #expect(command.baselinePiMessageId == "a1")
    }

    @MainActor @Test func inlineTerminalAttachmentAllowsOnlyOneVisibleTerminalAndRestoresPrevious() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle 1",
            status: "completed",
            logs: ["pi session: /tmp/pi-session-1.jsonl"]
        ))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-2",
            title: "Pickle 2",
            status: "completed",
            logs: ["pi session: /tmp/pi-session-2.jsonl"]
        ))))

        viewModel.enableInlineTerminalMode(sessionID: "pickle-1")
        viewModel.activateInlineTerminalAttachment(sessionID: "pickle-1", attachmentID: "screen-a")
        #expect(viewModel.isInlineTerminalAttachmentActive(sessionID: "pickle-1", attachmentID: "screen-a"))

        viewModel.enableInlineTerminalMode(sessionID: "pickle-2")
        viewModel.activateInlineTerminalAttachment(sessionID: "pickle-2", attachmentID: "screen-b")
        #expect(!viewModel.isInlineTerminalAttachmentActive(sessionID: "pickle-1", attachmentID: "screen-a"))
        #expect(viewModel.isInlineTerminalAttachmentActive(sessionID: "pickle-2", attachmentID: "screen-b"))
        #expect(viewModel.activeInlineTerminalAttachmentSessionID == "pickle-2")

        viewModel.releaseInlineTerminalAttachment(sessionID: "pickle-2", attachmentID: "screen-b")
        #expect(viewModel.isInlineTerminalAttachmentActive(sessionID: "pickle-1", attachmentID: "screen-a"))
        #expect(viewModel.activeInlineTerminalAttachmentSessionID == "pickle-1")
    }

    @MainActor @Test func inlineTerminalModeRequiresPiSessionFile() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            logs: ["no session path here"]
        ))))

        viewModel.enableInlineTerminalMode(sessionID: "pickle-1")

        #expect(!viewModel.isInlineTerminalMode(sessionID: "pickle-1"))
        #expect(viewModel.lastError == PickySessionListViewModelError.missingPiSessionFile.localizedDescription)
    }

    @Test func terminalOverlayCloseRequestsCanonicalDaemonSyncWithBaselinePiMessage() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let syncer = FakeTerminalSessionSyncer()
        syncer.snapshots["/tmp/pi-session.jsonl"] = PickyTerminalSessionSnapshot(
            lastUserText: "old question",
            lastAssistantText: "Old terminal answer",
            lastMessageId: "a1"
        )
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter,
            terminalSessionSyncer: syncer
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            summary: "Old summary",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "pickle-1")
        presenter.close(sessionID: "pickle-1")
        // 같은 이유 — client.sentCommands(← 가장 늦은 효과)를 predicate로.
        try await wait { client.sentCommands.contains { $0.type == .syncTerminalSession } }

        #expect(syncer.paths == ["/tmp/pi-session.jsonl"])
        let command = try #require(client.sentCommands.last)
        #expect(command.type == .syncTerminalSession)
        #expect(command.sessionId == "pickle-1")
        #expect(command.baselinePiMessageId == "a1")
        #expect(viewModel.sessions.first?.lastSummary == "Old summary")
    }

    @Test func terminalOverlayCloseSerializesTailDisableBeforeCanonicalSync() async throws {
        let client = FakePickyAgentClient()
        client.beforeSend = { command in
            if command.type == .setTerminalSessionTailEnabled, command.enabled == false {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))

        viewModel.openTerminalOverlay(sessionID: "pickle-1")
        presenter.close(sessionID: "pickle-1")
        try await wait {
            client.sentCommands.filter { $0.type == .setTerminalSessionTailEnabled || $0.type == .syncTerminalSession }.count == 3
        }

        let terminalCommands = client.sentCommands.filter { $0.type == .setTerminalSessionTailEnabled || $0.type == .syncTerminalSession }
        #expect(terminalCommands.map(\.type) == [.setTerminalSessionTailEnabled, .setTerminalSessionTailEnabled, .syncTerminalSession])
        #expect(terminalCommands.map(\.enabled) == [true, false, nil])
    }

    @Test func terminalOverlayCloseRequestsCanonicalDaemonSyncWithoutBaselineWhenSnapshotUnavailable() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let syncer = FakeTerminalSessionSyncer()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter,
            terminalSessionSyncer: syncer
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            summary: "Stored summary",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "pickle-1")
        presenter.close(sessionID: "pickle-1")
        // sentCommands is the latest effect in the close -> Task -> client.send chain;
        // poll for it instead of a fixed settle() to stay deterministic under the
        // parallel full-suite MainActor contention that previously made this flaky.
        try await wait { client.sentCommands.contains { $0.type == .syncTerminalSession } }

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .syncTerminalSession)
        #expect(command.sessionId == "pickle-1")
        #expect(command.baselinePiMessageId == nil)
        #expect(viewModel.sessions.first?.lastSummary == "Stored summary")
    }

    @MainActor @Test func terminalSyncOutcomeWithImportsSetsBannerState() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: true, importedMessageCount: 2
        ))))

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome?.importedMessageCount == 2)
    }

    @MainActor @Test func terminalSyncOutcomeWithBaselineMissingSetsBannerState() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: false, importedMessageCount: 0
        ))))

        let outcome = try #require(viewModel.sessions.first?.lastTerminalSyncOutcome)
        #expect(outcome.baselineFound == false)
    }

    @MainActor @Test func terminalSyncOutcomeWithNothingNewIsSuppressed() {
        // baselineFound + 0 imports is the silent "nothing changed" case;
        // suppressing it upstream keeps the HUD from showing a banner that
        // just confirms what the user already saw when the terminal closed.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: true, importedMessageCount: 0
        ))))

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome == nil)
    }

    @MainActor @Test func terminalSyncRecoveryFlipsFailedSessionToCompleted() {
        // Regression: agentd patches `status = "completed"` after a terminal-sync recovery,
        // but the HUD's `canTransition` guard used to reject `failed -> completed`, leaving the
        // composer placeholder stuck on "Send a recovery steer or open terminal" even though
        // the terminal session resolved the failure.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "failed", summary: "Codex error",
            updatedAt: "2026-05-01T00:00:00.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "completed", summary: "terminal recovery answer",
            updatedAt: "2026-05-01T00:00:10.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))

        #expect(viewModel.sessions.first?.status == .completed)
    }

    @MainActor @Test func terminalSyncRecoveryFlipsCancelledSessionToCompleted() {
        // Mirrors the failed -> completed recovery path for cancelled sessions: when the user
        // cancels mid-turn, opens the Pi terminal overlay, finishes the work, and closes the
        // overlay, the imported assistant answer should clear the cancelled status in the HUD.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "cancelled", summary: "Cancelled by user",
            updatedAt: "2026-05-01T00:00:00.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "completed", summary: "terminal recovery answer",
            updatedAt: "2026-05-01T00:00:10.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))

        #expect(viewModel.sessions.first?.status == .completed)
    }

    @MainActor @Test func completedSessionDoesNotRegressToFailedFromStaleSnapshot() {
        // The recovery direction is opened up but the reverse is still guarded so a delayed
        // failure snapshot can't undo a real completion that the HUD already rendered.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "completed", summary: "Done",
            updatedAt: "2026-05-01T00:00:10.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1", status: "failed", summary: "Late failure snapshot",
            updatedAt: "2026-05-01T00:00:20.000Z",
            piSessionFilePath: "/tmp/pi-session.jsonl"
        ))))

        #expect(viewModel.sessions.first?.status == .completed)
    }

    @Test func terminalCommandShellQuotesPaths() throws {
        let cliCommand = PickyPiTerminalCommand.makeCliResumeCommand(
            sessionFilePath: "/tmp/pi session's.jsonl",
            cwd: "/Users/example/Project Folder"
        )
        let overlayCommand = PickyPiTerminalCommand.makeOverlayCommand(
            sessionFilePath: "/tmp/pi session's.jsonl",
            cwd: "/Users/example/Project Folder"
        )

        #expect(cliCommand == "cd '/Users/example/Project Folder' && pi --session '/tmp/pi session'\\''s.jsonl'")
        #expect(overlayCommand.contains("cd '/Users/example/Project Folder' && exec pi --session '/tmp/pi session'\\''s.jsonl'"))
        #expect(overlayCommand.contains("export PATH="))
    }

    @Test func terminalCommandDefaultsBlankCwdToHomeDirectory() throws {
        #expect(PickyPiTerminalCommand.workingDirectory(from: "  ") == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func shellTerminalCommandResolvesShellAndWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picky-shell-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(PickyShellTerminalCommand.resolvedShell(environment: ["SHELL": "/bin/sh"]) == "/bin/sh")
        #expect(PickyShellTerminalCommand.resolvedShell(environment: ["SHELL": "/definitely/missing-shell"]) == "/bin/bash")
        #expect(PickyShellTerminalCommand.workingDirectory(from: directory.path) == directory.path)
        #expect(PickyShellTerminalCommand.workingDirectory(from: directory.appendingPathComponent("missing").path) == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func shellTerminalEnvironmentPrependsFinderSafePath() throws {
        let environment = PickyShellTerminalCommand.makeEnvironment([
            "PATH": "/custom/bin",
            "LANG": "ko_KR.UTF-8",
        ])

        #expect(environment.contains("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin"))
        #expect(environment.contains("TERM=xterm-256color"))
        #expect(environment.contains("COLORTERM=truecolor"))
        #expect(environment.contains("LANG=ko_KR.UTF-8"))
        #expect(environment.contains("LC_CTYPE=en_US.UTF-8"))
    }

    @Test func terminalCommandEnvironmentPrependsFinderSafePath() throws {
        let environment = PickyPiTerminalCommand.makeOverlayEnvironment([
            "PATH": "/custom/bin",
            "LANG": "ko_KR.UTF-8",
        ])

        #expect(environment.contains("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin"))
        #expect(environment.contains("TERM=xterm-256color"))
        #expect(environment.contains("COLORTERM=truecolor"))
        #expect(environment.contains("LANG=ko_KR.UTF-8"))
        #expect(environment.contains("LC_CTYPE=en_US.UTF-8"))
    }

    @Test func piSessionFileSyncerReadsLastActiveUserAndAssistantMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picky-pi-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try """
        {"type":"session","version":3,"id":"s","timestamp":"2026-05-01T00:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-05-01T00:00:01.000Z","message":{"role":"user","content":"old prompt","timestamp":0}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-05-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}],"timestamp":0,"api":"x","provider":"x","model":"x","usage":{},"stopReason":"stop"}}
        {"type":"message","id":"u2","parentId":"a1","timestamp":"2026-05-01T00:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"new prompt"}],"timestamp":0}}
        {"type":"message","id":"a2","parentId":"u2","timestamp":"2026-05-01T00:00:04.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"new answer"}],"timestamp":0,"api":"x","provider":"x","model":"x","usage":{},"stopReason":"stop"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try PickyPiSessionFileSyncer().snapshot(sessionFilePath: file.path)

        #expect(snapshot.lastUserText == "new prompt")
        #expect(snapshot.lastAssistantText == "new answer")
        #expect(snapshot.lastMessageId == "a2")
    }

    @Test func piSessionFileSyncerUsesLastTextMessageAsBaselineWhenLatestEntryIsToolOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picky-pi-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try """
        {"type":"session","version":3,"id":"s","timestamp":"2026-05-01T00:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-05-01T00:00:01.000Z","message":{"role":"user","content":"old prompt","timestamp":0}}
        {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-05-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}],"timestamp":0,"api":"x","provider":"x","model":"x","usage":{},"stopReason":"stop"}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-05-01T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"checking"},{"type":"toolCall","name":"bash","arguments":{"command":"echo hi"}}],"timestamp":0}}
        {"type":"message","id":"t1","parentId":"a2","timestamp":"2026-05-01T00:00:04.000Z","message":{"role":"toolResult","content":[{"type":"text","text":"tool output"}],"timestamp":0}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try PickyPiSessionFileSyncer().snapshot(sessionFilePath: file.path)

        #expect(snapshot.lastUserText == "old prompt")
        #expect(snapshot.lastAssistantText == "old answer")
        #expect(snapshot.lastMessageId == "a1")
    }

    @Test func piSessionFileSyncerKeepsActivePathConnectedThroughCustomEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picky-pi-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try """
        {"type":"session","version":3,"id":"s","timestamp":"2026-05-01T00:00:00.000Z","cwd":"/tmp"}
        {"type":"message","id":"u1","parentId":null,"timestamp":"2026-05-01T00:00:01.000Z","message":{"role":"user","content":"old prompt","timestamp":0}}
        {"type":"custom_message","customType":"todo-write-context","id":"custom1","parentId":"u1","timestamp":"2026-05-01T00:00:01.500Z","content":"hidden context"}
        {"type":"message","id":"a1","parentId":"custom1","timestamp":"2026-05-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"old answer"}],"timestamp":0,"api":"x","provider":"x","model":"x","usage":{},"stopReason":"stop"}}
        {"type":"custom","customType":"todo-write-overlay-state","id":"custom2","parentId":"a1","timestamp":"2026-05-01T00:00:02.500Z","content":"hidden overlay"}
        {"type":"message","id":"u2","parentId":"custom2","timestamp":"2026-05-01T00:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"new prompt"}],"timestamp":0}}
        {"type":"message","id":"a2","parentId":"u2","timestamp":"2026-05-01T00:00:04.000Z","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}],"timestamp":0,"api":"x","provider":"x","model":"x","usage":{},"stopReason":"stop"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try PickyPiSessionFileSyncer().snapshot(sessionFilePath: file.path)

        #expect(snapshot.lastUserText == "new prompt")
        #expect(snapshot.lastAssistantText == "new answer")
        #expect(snapshot.lastMessageId == "a2")
    }

    @MainActor @Test func extensionUiLogsAreHiddenFromRecentLogPreview() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            status: "running",
            logs: ["visible log", "extension ui: setWidget"]
        ))))

        #expect(viewModel.sessions.first?.logPreview == "visible log")

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "extension ui: notify"))))
        #expect(viewModel.sessions.first?.logPreview == "visible log")

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "done"))))
        #expect(viewModel.sessions.first?.logPreview == "done")
    }

    @MainActor @Test func sessionCardsExposeLastRequestAndCompactCwd() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            status: "running",
            logs: ["Picky handoff: initial screen check", "steer: summarize the failing case"]
        ))))

        #expect(viewModel.sessions.first?.lastRequestText == "summarize the failing case")
        #expect(viewModel.sessions.first?.compactCwdDescription == "~/Documents/picky")

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: include CWD in the HUD"))))
        #expect(viewModel.sessions.first?.lastRequestText == "include CWD in the HUD")
    }

    @MainActor @Test func liveTransitionToCompletedQueuesDoneFlash() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.contains("pickle-1"))

        viewModel.markDoneFlashConsumed(sessionID: "pickle-1")
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        // A duplicate .completed update (e.g. a tool/log patch arriving after the terminal
        // status) must not re-queue the flash within the same completion phase.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Resent", updatedAt: "2026-05-01T00:00:10.000Z"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @MainActor @Test func liveAttentionTransitionMarksUnreadUntilSessionIsRead() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        #expect(viewModel.unreadSessionIDs.isEmpty)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        #expect(viewModel.unreadSessionIDs == ["pickle-1"])

        viewModel.markSessionRead(sessionID: "pickle-1")
        #expect(viewModel.unreadSessionIDs.isEmpty)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running", updatedAt: "2026-05-01T00:00:10.000Z"))))
        #expect(viewModel.unreadSessionIDs.isEmpty)
    }

    @MainActor @Test func snapshotHydrationDoesNotQueueDoneFlashForHistoricalCompletedSessions() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "historical", title: "Historical", status: "completed", summary: "Already done"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        // Snapshot already populated previousStatus = .completed for this session, so a follow-up
        // sessionUpdated still in .completed must not retroactively flash.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "historical", title: "Historical", status: "completed", summary: "Updated", updatedAt: "2026-05-01T00:00:10.000Z"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @MainActor @Test func firstSightCompletedSessionDoesNotFlash() {
        // A brand-new session whose first sessionUpdated already carries .completed (e.g. a
        // synthesized snapshot from the daemon catching up) must not flash, since the user
        // didn't watch it transition. previousStatus is nil for the first sight.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "first-sight", title: "First sight", status: "completed"))))
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @MainActor @Test func sessionRunsAgainAndCompletesLiveQueuesNewDoneFlash() {
        // After a follow-up sends the session back to .running and it completes again, the new
        // live transition should queue a fresh flash. This mirrors the completion notification
        // dedupe reset in resetTerminalNotificationKeysIfNeeded.
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        viewModel.markDoneFlashConsumed(sessionID: "pickle-1")
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running", summary: "Working", updatedAt: "2026-05-01T00:00:10.000Z"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Done again", updatedAt: "2026-05-01T00:00:20.000Z"))))

        #expect(viewModel.pendingDoneFlashSessionIDs.contains("pickle-1"))
    }

    @MainActor @Test func runtimeDetachedRestoredSessionsStayVisibleAndClearAutoArchiveState() {
        let archiveStore = FakeArchiveStore()
        archiveStore.archivedSessionIDs = ["lost-runtime", "manual-completed"]
        archiveStore.manuallyArchivedSessionIDs = ["manual-completed"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-detached","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionSnapshot","sessions":[{"id":"lost-runtime","title":"Old Pickle","status":"blocked","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Runtime not attached after daemon restart; start a new task or resume support is required","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},{"id":"manual-completed","title":"Manual archive","status":"completed","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Done","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}]}
        """)))

        #expect(viewModel.sessions.map(\.id) == ["lost-runtime"])
        #expect(viewModel.archivedSessions.map(\.id) == ["manual-completed"])
        #expect(archiveStore.archivedSessionIDs == ["manual-completed"])

        viewModel.archive(sessionID: "lost-runtime")
        #expect(archiveStore.archivedSessionIDs == ["lost-runtime", "manual-completed"])
        #expect(archiveStore.manuallyArchivedSessionIDs == ["lost-runtime", "manual-completed"])

        viewModel.apply(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-detached-2","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionSnapshot","sessions":[{"id":"lost-runtime","title":"Old Pickle","status":"blocked","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","lastSummary":"Runtime not attached after daemon restart; start a new task or resume support is required","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},{"id":"manual-completed","title":"Manual archive","status":"completed","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Done","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}]}
        """)))
        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["lost-runtime", "manual-completed"])
    }

    @MainActor @Test func runtimeDetachedFollowUpFailureStaysVisible() {
        let archiveStore = FakeArchiveStore()
        archiveStore.archivedSessionIDs = ["followup-detached"]
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "followup-detached",
            title: "Detached Pickle",
            status: "blocked",
            summary: "Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(
            sessionId: "followup-detached",
            line: "steer rejected: Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))

        #expect(viewModel.sessions.map(\.id) == ["followup-detached"])
        #expect(viewModel.sessions.first?.status == .blocked)
        #expect(viewModel.sessions.first?.isRuntimeDetached == true)
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(archiveStore.archivedSessionIDs.isEmpty)
    }

    @MainActor @Test func textSteerTargetsSelectedSessionAndRejectsEmptyInput() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-follow", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))

        try await viewModel.steer(text: "  continue here  ")
        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.sessionId == "session-follow")
        #expect(client.sentCommands.last?.text == "continue here")
        await #expect(throws: PickySessionListViewModelError.emptyFollowUp) {
            try await viewModel.steer(text: "   ")
        }
    }

    @Test func textSteerRejectsArchivedExplicitSession() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "archived-pickle", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "archived-pickle")
        try await settle()
        let commandCountAfterArchive = client.sentCommands.count

        await #expect(throws: PickySessionListViewModelError.archivedSession) {
            try await viewModel.steer(text: "  stale steer  ", sessionID: "archived-pickle")
        }
        #expect(viewModel.lastError == "Cannot steer an archived Pickle session")
        #expect(client.sentCommands.count == commandCountAfterArchive)
        #expect(client.sentCommands.last?.type == .setSessionArchived)
    }

    @Test func textFollowUpRejectsArchivedExplicitSession() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "archived-pickle", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "archived-pickle")
        try await settle()
        let commandCountAfterArchive = client.sentCommands.count

        await #expect(throws: PickySessionListViewModelError.archivedSession) {
            try await viewModel.followUp(text: "  stale follow-up  ", sessionID: "archived-pickle")
        }
        #expect(viewModel.lastError == "Cannot follow up an archived Pickle session")
        #expect(client.sentCommands.count == commandCountAfterArchive)
        #expect(client.sentCommands.last?.type == .setSessionArchived)
    }

    @MainActor @Test func pinnedCompletedSessionAcceptsFollowUpCommand() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pinned-completed",
            title: "Pinned completed Pi session",
            status: "completed",
            summary: "Pinned completed Pi session",
            updatedAt: "2026-05-01T00:00:05.000Z",
            pinned: true
        ))))

        try await viewModel.followUp(text: "  continue from pinned card  ", sessionID: "pinned-completed")

        #expect(client.sentCommands.last?.type == .followUp)
        #expect(client.sentCommands.last?.sessionId == "pinned-completed")
        #expect(client.sentCommands.last?.text == "continue from pinned card")
        #expect(viewModel.sessions.first?.pinned == true)
        #expect(viewModel.sessions.first?.lastRequestText == "continue from pinned card")
    }

    @Test func slashCommandAutocompleteRequestsCachesAndFiltersCommands() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await settle()
        var slashRequests = client.sentCommands.filter { $0.type == .listSlashCommands }
        #expect(slashRequests.count == 1)
        #expect(slashRequests.last?.sessionId == "session-commands")

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await settle()
        slashRequests = client.sentCommands.filter { $0.type == .listSlashCommands }
        #expect(slashRequests.count == 1)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: slashRequests[0].id))))
        try await wait { viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }

        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        #expect(viewModel.slashCommandSuggestions(for: "/dep", sessionID: "session-commands").map(\.name) == ["deploy"])
        #expect(viewModel.slashCommandSuggestions(for: "/skill:cont", sessionID: "session-commands").map(\.name) == ["skill:context7-cli"])
        #expect(viewModel.slashCommandSuggestions(for: "/deploy now", sessionID: "session-commands").isEmpty)
        #expect(PickySlashCommandAutocompletePolicy.completionText(for: viewModel.slashCommandsBySessionID["session-commands"]![0]) == "/deploy ")
    }

    @Test func slashCommandCacheInvalidatesWhenSessionCwdOrPiSessionFileChanges() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            cwd: "/tmp/old-product",
            piSessionFilePath: "/tmp/old-pi.jsonl"
        ))))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { !client.sentCommands.filter { $0.type == .listSlashCommands }.isEmpty }
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: client.sentCommands.filter { $0.type == .listSlashCommands }.last?.id))))
        try await wait { viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:05.000Z",
            cwd: "/tmp/new-product",
            piSessionFilePath: "/tmp/old-pi.jsonl"
        ))))
        try await wait { !viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: client.sentCommands.filter { $0.type == .listSlashCommands }.last?.id))))
        try await settle()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:10.000Z",
            cwd: "/tmp/new-product",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))
        try await wait { !viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 3 }
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 3)
    }

    @Test func slashCommandCacheInvalidatesWhenRuntimeReattachLogArrives() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        try await settle()
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { !client.sentCommands.filter { $0.type == .listSlashCommands }.isEmpty }
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: client.sentCommands.filter { $0.type == .listSlashCommands }.last?.id))))
        try await wait { viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:05.000Z",
            logs: ["runtime reattached from pi session: /tmp/pi.jsonl"],
            piSessionFilePath: "/tmp/pi.jsonl"
        ))))
        try await wait { !viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2)
    }

    @Test func slashCommandSnapshotDiscardsStaleResponseWhenNewerSnapshotArrivesFirst() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", cwd: "/tmp/old"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let oldRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", cwd: "/tmp/next"))))
        try await settle()
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        let newRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: newRequestId, commandNames: ["new-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["new-command"] }
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: oldRequestId, commandNames: ["old-command"]))))
        try await settle()

        #expect(viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["new-command"])
    }

    @Test func slashCommandResourcesReloadedBumpsEpochAndReRequestsOnlyPreviouslyRequestedSession() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-unrequested"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let staleRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionResourcesReloaded(sessionId: "session-commands"))))
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        let refreshedRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionResourcesReloaded(sessionId: "session-unrequested"))))
        try await settle()

        #expect(client.sentCommands.filter { $0.type == .listSlashCommands && $0.sessionId == "session-commands" }.count == 2)
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands && $0.sessionId == "session-unrequested" }.isEmpty)
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: staleRequestId, commandNames: ["old-command"]))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: refreshedRequestId, commandNames: ["new-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["new-command"] }
    }

    @Test func slashCommandCwdChangeDiscardsInFlightSnapshotFromPreviousEpoch() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", cwd: "/tmp/old"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let staleRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", updatedAt: "2026-05-01T00:00:05.000Z", cwd: "/tmp/new"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: staleRequestId, commandNames: ["old-command"]))))
        try await settle()

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
    }

    @Test func slashCommandInvalidationAutoRefiresWhileRequestIsInFlightSoUIRecoversWithoutReopen() async throws {
        // Reproduces the "Loading commands…" stuck state on a just-launched Pickle: the first
        // listSlashCommands request is still in flight when the runtime attaches and broadcasts a
        // pi-session log line that bumps the slash command epoch. Without auto-refire the in-flight
        // snapshot would be silently dropped on epoch mismatch and the composer would stay stuck
        // on "Loading commands…" until the HUD was closed and reopened.
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let staleRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(
            sessionId: "session-commands",
            line: "runtime reattached from pi session: /tmp/pi.jsonl"
        ))))

        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        let freshRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        #expect(staleRequestId != freshRequestId)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: staleRequestId, commandNames: ["stale-command"]))))
        try await settle()
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: freshRequestId, commandNames: ["fresh-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["fresh-command"] }
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
    }

    @Test func refreshSlashCommandsIfStillLoadingReRequestsWithoutStarvingSlowInFlightSnapshot() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let slowRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id

        viewModel.refreshSlashCommandsIfStillLoading(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }
        let pollingRequestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        #expect(slowRequestId != pollingRequestId)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: slowRequestId, commandNames: ["slow-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["slow-command"] }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: pollingRequestId, commandNames: ["polling-command"]))))
        try await settle()
        #expect(viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["slow-command"])
    }

    @Test func slashCommandSnapshotWithoutRequestIdHydratesCurrentInFlightRequest() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: nil, commandNames: ["legacy-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["legacy-command"] }
    }

    @Test func slashCommandSnapshotWithoutRequestIdAfterInvalidationDropsStaleEpochBeforeAcceptingCurrentEpoch() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", cwd: "/tmp/old"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands", updatedAt: "2026-05-01T00:00:05.000Z", cwd: "/tmp/new"))))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2 }

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: nil, commandNames: ["stale-legacy-command"]))))
        try await settle()
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: nil, commandNames: ["fresh-legacy-command"]))))
        try await wait { viewModel.slashCommandsBySessionID["session-commands"]?.map(\.name) == ["fresh-legacy-command"] }
    }

    @Test func refreshSlashCommandsIfStillLoadingIsNoOpWhenCommandsAlreadyLoaded() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        try await settle()

        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await wait { client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1 }
        let requestId = client.sentCommands.filter { $0.type == .listSlashCommands }.last!.id
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot(requestId: requestId, commandNames: ["loaded"]))))
        try await wait { viewModel.hasLoadedSlashCommands(sessionID: "session-commands") }

        viewModel.refreshSlashCommandsIfStillLoading(sessionID: "session-commands")
        try await settle()
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 1)
    }

    @Test func slashCommandAutocompleteSelectionWrapsWithArrowNavigation() {
        #expect(PickySlashCommandAutocompletePolicy.clampedSelectionIndex(10, suggestionCount: 3) == 2)
        #expect(PickySlashCommandAutocompletePolicy.clampedSelectionIndex(-2, suggestionCount: 3) == 0)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 0, suggestionCount: 3, direction: .down) == 1)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 2, suggestionCount: 3, direction: .down) == 0)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 0, suggestionCount: 3, direction: .up) == 2)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 2, suggestionCount: 0, direction: .up) == 0)
    }

    @Test func slashCommandAutocompleteKeepsMoreSuggestionsThanVisibleRowsForNavigation() {
        let commands = (0..<8).map { index in
            PickySlashCommand(name: "command-\(index)", description: nil, source: .builtin)
        }

        let suggestions = PickySlashCommandAutocompletePolicy.suggestions(for: "/command", commands: commands)

        #expect(suggestions.map(\.name) == commands.map(\.name))
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 5, suggestionCount: suggestions.count, maxVisible: 4) == 3..<7)
    }

    @Test func autocompleteVisibleRangeKeepsAtMostMaxVisibleSuggestionsAroundSelection() {
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 0, suggestionCount: 10, maxVisible: 4) == 0..<4)
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 3, suggestionCount: 10, maxVisible: 4) == 1..<5)
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 9, suggestionCount: 10, maxVisible: 4) == 6..<10)
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 8, suggestionCount: 3, maxVisible: 4) == 0..<3)
        #expect(PickySlashCommandAutocompletePolicy.visibleRange(selectedIndex: 0, suggestionCount: 10, maxVisible: 0) == 0..<0)
    }

    @MainActor @Test func textSteerCanTargetCancelledSessionByExplicitID() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-cancelled", status: "cancelled", summary: "Cancelled", updatedAt: "2026-05-01T00:00:05.000Z"))))

        try await viewModel.steer(text: "  다시 진행해줘  ", sessionID: "session-cancelled")

        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.sessionId == "session-cancelled")
        #expect(client.sentCommands.last?.text == "다시 진행해줘")
        #expect(viewModel.sessions.first?.status == .cancelled)
        #expect(viewModel.sessions.first?.lastRequestText == "다시 진행해줘")
    }

    @MainActor @Test func retryAfterRuntimeRaceResendsLastRequestViaSteer() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-race", status: "running", updatedAt: "2026-05-01T00:00:05.000Z"))))

        // Mirrors the real flow: the user sends a follow-up that the supervisor delivers
        // to Pi, which then fails with the activeRun race. The viewmodel records the text
        // before the failure surfaces, so `lastRequestText` is what the Retry chip will resend.
        try await viewModel.followUp(text: "엥 리뷰 리퀘스트 했어?", sessionID: "session-race")
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-race", status: "failed", summary: "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion.", updatedAt: "2026-05-01T00:00:06.000Z"))))

        let commandCountBeforeRetry = client.sentCommands.count
        try await viewModel.retryAfterRuntimeRace(sessionID: "session-race")

        #expect(client.sentCommands.count == commandCountBeforeRetry + 1)
        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.sessionId == "session-race")
        #expect(client.sentCommands.last?.text == "엥 리뷰 리퀘스트 했어?")
    }

    @MainActor @Test func retryAfterRuntimeRaceWithoutPreviousRequestThrows() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-empty", status: "failed", summary: "Agent is already processing a prompt.", updatedAt: "2026-05-01T00:00:05.000Z"))))

        let commandCountBeforeRetry = client.sentCommands.count
        await #expect(throws: PickySessionListViewModelError.emptyFollowUp) {
            try await viewModel.retryAfterRuntimeRace(sessionID: "session-empty")
        }
        #expect(client.sentCommands.count == commandCountBeforeRetry)
    }

    @MainActor @Test func notifyMainToggleSendsCommandAndUpdatesSession() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-notify",
            status: "completed",
            updatedAt: "2026-05-01T00:00:05.000Z",
            notifyMainOnCompletion: true
        ))))

        try await viewModel.setNotifyMainOnCompletion(sessionID: "session-notify", enabled: false)

        #expect(client.sentCommands.last?.type == .setNotifyMainOnCompletion)
        #expect(client.sentCommands.last?.sessionId == "session-notify")
        #expect(client.sentCommands.last?.enabled == false)
        #expect(viewModel.sessions.first?.notifyMainOnCompletion == false)
    }

    @Test func reportBuilderAndPrExtractionUseOnlyExplicitUrls() async throws {
        let session = PickyAgentSession.fixture(lastSummary: "Opened https://github.com/acme/repo/pull/42", status: .completed)
        let markdown = PickyArtifactReportBuilder().markdown(for: session)
        #expect(markdown.contains("Status: `completed`"))
        #expect(markdown.contains("https://github.com/acme/repo/pull/42"))
        #expect(PickyArtifactReportBuilder.githubPullRequestURLs(in: "will make a PR later").isEmpty)
    }

    @Test func markdownReportRendererParsesReportBlocks() throws {
        let markdown = """
        # Report

        Intro **done**
        - `bash`: 2
        ```
        line 1
        line 2
        ```
        """
        let renderer = PickyReportMarkdownRenderer()

        #expect(renderer.blocks(from: markdown) == [
            .heading(level: 1, text: "Report"),
            .paragraph("Intro **done**"),
            .bullet("`bash`: 2"),
            .codeBlock("line 1\nline 2"),
        ])
        #expect(String(renderer.inlineAttributedString(for: "**Done**").characters) == "Done")
    }

    @Test func markdownReportRendererParsesGithubStyleTables() throws {
        let markdown = """
        Before

        | # | Category | Concern | Response |
        |---|---|---|---|
        | 1 | 동작 동일성 | `admin`과 web 값이 다를 수 있음 | 추가 검토 |
        | 2 | 회귀 안전성 | fallback ID 테스트 부족 | `Date.now()` 고정 |

        After
        """
        let renderer = PickyReportMarkdownRenderer()

        #expect(renderer.blocks(from: markdown) == [
            .paragraph("Before"),
            .table(
                headers: ["#", "Category", "Concern", "Response"],
                rows: [
                    ["1", "동작 동일성", "`admin`과 web 값이 다를 수 있음", "추가 검토"],
                    ["2", "회귀 안전성", "fallback ID 테스트 부족", "`Date.now()` 고정"],
                ]
            ),
            .paragraph("After"),
        ])
    }

    @MainActor @Test func openReportByMessageIDOpensThatSpecificMessageNotJustTheLatest() async throws {
        // The HUD bubble's hover icon needs to be able to expand any message in
        // the conversation, not just the most recent agent reply. Verify that
        // passing a specific messageID opens that message (here: the first of
        // two appended replies) and uses a per-message file name + title.
        let generatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-msg-report-\(UUID().uuidString)", isDirectory: true)
        let presenter = FakeReportPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter,
            generatedReportDirectory: generatedRoot
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "msg-session", title: "Multi reply", status: "completed"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "msg-session", messageId: "msg-1", text: "# First", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "msg-session", messageId: "msg-2", text: "# Second", seq: 2))))

        try await viewModel.openReport(sessionID: "msg-session", messageID: "msg-1")

        let call = try #require(presenter.calls.first)
        #expect(call.sessionID == "msg-session:message:msg-1")
        #expect(call.title == "Multi reply \u{2014} Response")
        #expect(call.fileURL.lastPathComponent == "response-msg-1.md")
        #expect(call.markdown == "# First")
        #expect(FileManager.default.fileExists(atPath: call.fileURL.path))
    }

    @MainActor @Test func openLatestAgentResponseReportOpensNewestAgentTextOnly() async throws {
        let generatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-latest-response-report-\(UUID().uuidString)", isDirectory: true)
        let presenter = FakeReportPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter,
            generatedReportDirectory: generatedRoot
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "latest-response-session", title: "Latest", status: "completed"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "latest-response-session", messageId: "msg-1", text: "# First", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "latest-response-session", messageId: "msg-2", text: "# Second", seq: 2))))

        #expect(viewModel.sessions.first?.latestAgentResponseReportMessageID == "msg-2")
        #expect(viewModel.sessions.first?.hasLatestAgentResponseReport == true)

        try await viewModel.openLatestAgentResponseReport(sessionID: "latest-response-session")

        let call = try #require(presenter.calls.first)
        #expect(call.sessionID == "latest-response-session:message:msg-2")
        #expect(call.title == "Latest \u{2014} Response")
        #expect(call.fileURL.lastPathComponent == "response-msg-2.md")
        #expect(call.markdown == "# Second")
    }

    @MainActor @Test func openReportByMessageIDThrowsWhenMessageHasNoMarkdownContent() async throws {
        // Activity-only or empty messages shouldn't be openable as reports. The
        // hover icon avoids invoking this path for such messages, but the API
        // itself should still fail safely if called.
        let presenter = FakeReportPresenter()
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter
        )
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "empty-msg-session", title: "Empty", status: "completed"))))

        await #expect(throws: PickySessionListViewModelError.missingReport) {
            try await viewModel.openReport(sessionID: "empty-msg-session", messageID: "non-existent")
        }
        #expect(presenter.calls.isEmpty)
    }

    @Test func reportBuilderToolSummaryUsesOnlyToolCallCounts() async throws {
        let session = PickyAgentSession.fixture(
            lastSummary: "Done",
            status: .completed,
            tools: [
                PickyToolActivity(toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "tests passed", startedAt: nil, endedAt: nil),
                PickyToolActivity(toolCallId: "tool-2", name: "bash", status: "failed", preview: "error output", startedAt: nil, endedAt: nil),
                PickyToolActivity(toolCallId: "tool-3", name: "read", status: "succeeded", preview: "file contents", startedAt: nil, endedAt: nil)
            ]
        )
        let markdown = PickyArtifactReportBuilder().markdown(for: session)

        #expect(markdown.contains("## Tool summary\n- `bash`: 2\n- `read`: 1"))
        #expect(!markdown.contains("tests passed"))
        #expect(!markdown.contains("error output"))
        #expect(!markdown.contains("succeeded"))
        #expect(!markdown.contains("failed"))
    }

    @Test func artifactPathValidatorRejectsTraversalAndMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("report.md")
        try "# ok".write(to: file, atomically: true, encoding: .utf8)
        let validator = PickyArtifactPathValidator(appSupportRoot: root)

        #expect(try validator.validateReadableFile(path: file.path) == file.standardizedFileURL)
        #expect(throws: PickyArtifactOpeningError.escapedAppSupportRoot("/tmp/evil.md")) {
            try validator.validateReadableFile(path: "/tmp/evil.md")
        }
        #expect(throws: PickyArtifactOpeningError.missingFile(root.appendingPathComponent("missing.md").path)) {
            try validator.validateReadableFile(path: root.appendingPathComponent("missing.md").path)
        }
    }

    @Test func initialTranscriptSubmitsCreateTaskThroughClient() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        let context = PickyContextPacket(
            id: "context-1",
            source: "text",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "hello",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )

        try await viewModel.submit(transcript: "hello", context: context)

        #expect(client.submitted.first?.context.id == "context-1")
        #expect(client.submitted.first?.transcript == "hello")
    }

    @Test func sessionCardMirrorsConversationFieldsFromAgentSession() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let message = PickySessionMessage.fixture(id: "m-1", kind: .agentText, text: "hello")
        let queueItem = PickyQueueItem(text: "next", enqueuedAt: createdAt)
        let activity = PickyActivitySummary(edit: 1, bash: 2, thinking: 3, other: 4)
        let session = PickyAgentSession(
            id: "conversation-session",
            title: "Conversation",
            status: .running,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastSummary: "Started",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            messages: [message],
            queuedSteers: [queueItem],
            queuedFollowUps: [PickyQueueItem(text: "follow", enqueuedAt: createdAt)],
            steeringMode: .all,
            followUpMode: .all,
            activitySummary: activity
        )

        let card = PickySessionListViewModel.SessionCard.fromAgentSession(session)

        #expect(card.messages == [message])
        #expect(card.queuedSteers == [queueItem])
        #expect(card.queuedFollowUps.map(\.text) == ["follow"])
        #expect(card.steeringMode == .all)
        #expect(card.followUpMode == .all)
        #expect(card.activitySummary == activity)
    }

    @MainActor @Test func sessionMessageIncrementalEventsAppendReplaceRemoveAndIgnoreStaleSeq() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "conversation-session"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-1", text: "first", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageReplaced(sessionId: "conversation-session", messageId: "m-1", text: "updated", seq: 2))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-stale", text: "stale", seq: 2))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageRemoved(sessionId: "conversation-session", messageId: "m-1", seq: 3))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-old", text: "old", seq: 1))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.messages.isEmpty)
    }

    @MainActor @Test func commandReceiptMessageDecodesAndAppends() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "command-session"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.commandReceiptMessageAppended(sessionId: "command-session", messageId: "cmd-1", command: "/c", status: "failed", detail: "unmerged paths", seq: 1))))

        let message = try #require(viewModel.sessions.first?.messages.first)
        #expect(message.kind == .commandReceipt)
        #expect(message.text == "/c")
        #expect(message.commandReceipt == PickyCommandReceipt(command: "/c", status: .failed, detail: "unmerged paths"))
    }

    @MainActor @Test func sessionSnapshotResetsIncrementalSeqAfterDaemonRestart() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "restart-session", status: "running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "restart-session", messageId: "old-high-seq", text: "old high seq", seq: 10))))
        #expect(viewModel.sessions.first?.messages.map(\.text) == ["old high seq"])

        // After an agentd restart the daemon sends a fresh snapshot for the same session id, but
        // its in-memory incremental seq counter starts over at 1. The snapshot is authoritative and
        // must reset the Swift-side watermark so the new seq=1 event is not dropped as stale.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "restart-session", status: "running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "restart-session", messageId: "new-low-seq", text: "new low seq", seq: 1))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.messages.map(\.text) == ["new low seq"])
    }

    @MainActor @Test func sessionQueueUpdatedAppliesModesAndPreservesExistingModeWhenNil() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "queue-session"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "queue-session", steering: ["steer"], followUp: ["follow"], steeringMode: "all", followUpMode: "all", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "queue-session", steering: ["steer-2"], followUp: [], steeringMode: nil, followUpMode: nil, seq: 2))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.queuedSteers.map(\.text) == ["steer-2"])
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.steeringMode == .all)
        #expect(card.followUpMode == .all)
    }

    @MainActor @Test func sessionUpdatedAfterIncrementalEventDoesNotResetConversationRenderState() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "live-conversation", status: "running"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "live-conversation", messageId: "m-1", text: "rendered answer", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "live-conversation", steering: [], followUp: ["queued follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        // Runtime status/tool patches still broadcast full sessionUpdated snapshots. They often
        // carry transient empty conversation arrays because the granular message/queue events are
        // the live render source of truth. Those snapshots must not make bubbles disappear.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "live-conversation", status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:05.000Z"))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.status == .completed)
        #expect(card.messages.map(\.text) == ["rendered answer"])
        #expect(card.queuedFollowUps.map(\.text) == ["queued follow-up"])
    }

    @MainActor @Test func sessionUpdatedWithNewPiSessionFileResetsIncrementalConversationState() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "replaced-session", status: "completed", piSessionFilePath: "/tmp/old-pi.jsonl"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "replaced-session", messageId: "m-1", text: "old answer", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "replaced-session", steering: [], followUp: ["old follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "replaced-session",
            title: "New Pickle · picky",
            status: "waiting_for_input",
            summary: "Ready for instructions",
            updatedAt: "2026-05-01T00:00:05.000Z",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.title == "New Pickle · picky")
        #expect(card.status == .waiting_for_input)
        #expect(card.lastSummary == "Ready for instructions")
        #expect(card.messages.isEmpty)
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.piSessionFilePath == "/tmp/new-pi.jsonl")
    }

    @MainActor @Test func freshPiSessionResetClearsConversationEvenIfDiagnosticLogAlreadyUpdatedPath() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "replaced-session", status: "completed", piSessionFilePath: "/tmp/old-pi.jsonl"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "replaced-session", messageId: "m-1", text: "old answer", seq: 1))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "replaced-session", steering: [], followUp: ["old follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        // PiSdkRuntime used to emit the new `pi session:` diagnostic before the replacement
        // snapshot. The log event pre-updated the card's piSessionFilePath, so the subsequent
        // empty replacement snapshot looked like an ordinary transient sessionUpdated and the HUD
        // preserved stale Earlier history.
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "replaced-session", line: "pi session: /tmp/new-pi.jsonl"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "replaced-session",
            title: "New Pickle · picky",
            status: "waiting_for_input",
            summary: "Ready for instructions",
            updatedAt: "2026-05-01T00:00:05.000Z",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))

        let card = try #require(viewModel.sessions.first)
        #expect(card.title == "New Pickle · picky")
        #expect(card.status == .waiting_for_input)
        #expect(card.lastSummary == "Ready for instructions")
        #expect(card.messages.isEmpty)
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.logPreview.isEmpty)
        #expect(card.piSessionFilePath == "/tmp/new-pi.jsonl")
    }

    @MainActor @Test func sessionActivityUpdatedMirrorsSummary() {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "activity-session"))))
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionActivityUpdated(sessionId: "activity-session", edit: 2, bash: 3, thinking: 4, other: 5, seq: 1))))

        #expect(viewModel.sessions.first?.activitySummary == PickyActivitySummary(edit: 2, bash: 3, thinking: 4, other: 5))
    }

    @Test func clearQueueSendsClearQueueCommandEnvelope() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.clearQueue(sessionID: "queue-session", kind: .all)

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .clearQueue)
        #expect(command.sessionId == "queue-session")
        #expect(command.kind == .all)
    }

    @MainActor @Test func toggleThinkingBlocksPersistsPiProjectSettingAndUpdatesVisibility() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let piDirectory = cwd.appendingPathComponent(".pi", isDirectory: true)
        let settingsURL = piDirectory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: piDirectory, withIntermediateDirectories: true)
        try Data(#"{"hideThinkingBlock":false}"#.utf8).write(to: settingsURL)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.apply(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "thinking-session", status: "running", cwd: cwd.path))))

        #expect(viewModel.thinkingBlocksHidden(sessionID: "thinking-session") == false)

        viewModel.toggleThinkingBlocks(sessionID: "thinking-session")

        #expect(PickyPiSettingsReader.hideThinkingBlock(in: settingsURL) == true)
        #expect(viewModel.thinkingBlocksHidden(sessionID: "thinking-session") == true)
        #expect(viewModel.lastError == nil)
    }
}

@MainActor
private func waitForCommand(_ type: PickyCommandType, in client: FakePickyAgentClient) async throws {
    for _ in 0..<20 {
        if client.sentCommands.contains(where: { $0.type == type }) { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(client.sentCommands.contains { $0.type == type })
}

/// Fixed-deadline pause. PREFER `wait(until:)` for new tests — settle() exists
/// only for the two legacy patterns that polling cannot express:
///
///   1. Negative wait: prove that some state stays unchanged after a known
///      timer elapses (e.g. "running pickle is NOT released after the 50ms
///      archive-commit delay"). The asserted condition is true the entire
///      time, so polling would return immediately and skip the timer entirely.
///
///   2. Setup drain: flush an emit + AsyncStream + reducer chain to seed the
///      view model before exercising *another* async behavior (NotificationCenter
///      target, archive timer, terminal sync command, slash-command request).
///      The test's real subject under test is the second async channel; the
///      transport drain here is incidental, so a single fixed pause is
///      simpler than a predicate.
///
/// Do NOT use settle() to wait for a positive state change — that is the exact
/// pattern Phase 5 removed, and re-introducing it brings the original timing
/// flake back. Use `wait(until:)` instead.
private func settle() async throws {
    try await Task.sleep(nanoseconds: 200_000_000)
}

/// Polls `predicate` on the @MainActor until it returns true or `deadline`
/// elapses. Replaces fixed-time `settle()` waits whose intent is "wait for
/// X to become true" — deterministic when the underlying async dispatch is
/// faster than the deadline, and never longer than necessary. On timeout it
/// returns without throwing so the caller's `#expect` surfaces a clear
/// assertion failure instead of a generic timeout.
@MainActor
private func wait(
    until predicate: () -> Bool,
    deadline: Duration = .milliseconds(1500),
    poll: Duration = .milliseconds(2)
) async throws {
    let start = ContinuousClock.now
    while !predicate() {
        if ContinuousClock.now - start >= deadline { return }
        try await Task.sleep(for: poll)
    }
}

private enum EventJSON {
    static func sessionUpdated(
        id: String = "session-1",
        title: String = "Investigate current screen",
        status: String = "running",
        summary: String = "Started",
        createdAt: String = "2026-05-01T00:00:00.000Z",
        updatedAt: String = "2026-05-01T00:00:00.000Z",
        logs: [String] = [],
        cwd: String = testProjectCwd,
        piSessionFilePath: String? = nil,
        notifyMainOnCompletion: Bool? = nil,
        pinned: Bool? = nil
    ) -> String {
        let encodedLogs = String(decoding: try! JSONEncoder().encode(logs), as: UTF8.self)
        let encodedCwd = String(decoding: try! JSONEncoder().encode(cwd), as: UTF8.self)
        let encodedPiSessionFilePath = piSessionFilePath.map { ",\"piSessionFilePath\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        let encodedNotify = notifyMainOnCompletion.map { ",\"notifyMainOnCompletion\":\($0)" } ?? ""
        let encodedPinned = pinned.map { ",\"pinned\":\($0)" } ?? ""
        return """
        {"id":"event-\(id)-\(status)","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":\(encodedCwd),"createdAt":"\(createdAt)","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":\(encodedLogs),"tools":[],"artifacts":[],"changedFiles":[]\(encodedPiSessionFilePath)\(encodedNotify)\(encodedPinned)}}
        """
    }

    static func sessionSnapshot(
        id: String = "session-1",
        title: String = "Investigate current screen",
        status: String = "running",
        summary: String = "Started",
        createdAt: String = "2026-05-01T00:00:00.000Z",
        updatedAt: String = "2026-05-01T00:00:00.000Z",
        logs: [String] = [],
        piSessionFilePath: String? = nil,
        archived: Bool? = nil
    ) -> String {
        let encodedLogs = String(decoding: try! JSONEncoder().encode(logs), as: UTF8.self)
        let encodedPiSessionFilePath = piSessionFilePath.map { ",\"piSessionFilePath\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        let encodedArchived = archived.map { ",\"archived\":\($0)" } ?? ""
        return """
        {"id":"snapshot-\(id)-\(status)","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionSnapshot","sessions":[{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"\(testProjectCwd)","createdAt":"\(createdAt)","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":\(encodedLogs),"tools":[],"artifacts":[],"changedFiles":[]\(encodedPiSessionFilePath)\(encodedArchived)}]}
        """
    }

    static func slashCommandsSnapshot(
        sessionId: String = "session-commands",
        requestId: String?,
        commandNames: [String] = ["deploy", "fix-tests", "skill:context7-cli"]
    ) -> String {
        let encodedSessionId = String(decoding: try! JSONEncoder().encode(sessionId), as: UTF8.self)
        let encodedRequestId = requestId.map { ",\"requestId\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        let commands = commandNames.enumerated().map { index, name in
            let source: String
            switch index {
            case 1: source = "prompt"
            case 2: source = "skill"
            default: source = "extension"
            }
            let encodedName = String(decoding: try! JSONEncoder().encode(name), as: UTF8.self)
            return "{\"name\":\(encodedName),\"description\":\(encodedName),\"source\":\"\(source)\"}"
        }.joined(separator: ",")
        return """
        {"id":"event-slash-commands","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"slashCommandsSnapshot","sessionId":\(encodedSessionId)\(encodedRequestId),"commands":[\(commands)]}
        """
    }

    static func sessionResourcesReloaded(sessionId: String = "session-commands") -> String {
        """
        {"id":"event-resources-reloaded","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionResourcesReloaded","sessionId":"\(sessionId)"}
        """
    }

    static func extensionUiRequest() -> String {
        """
        {"id":"event-ui","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:02.000Z","type":"extensionUiRequest","request":{"id":"ui-1","sessionId":"session-1","method":"confirm","title":"Confirm","prompt":"Proceed?","options":null,"createdAt":"2026-05-01T00:00:02.000Z"}}
        """
    }

    static func askUserQuestionRequest() -> String {
        """
        {"id":"event-ui-form","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:02.000Z","type":"extensionUiRequest","request":{"id":"ui-form","sessionId":"session-1","method":"askUserQuestion","title":"Confirm memory","description":"Pick what to save","questions":[{"id":"scope","type":"radio","prompt":"Scope?","options":[{"value":"user","label":"User"},{"value":"project","label":"Project"}],"default":"project"},{"id":"items","type":"checkbox","prompt":"Items?","options":[{"value":"rule","label":"Rule"}],"default":["rule"],"allowOther":true},{"id":"note","type":"text","prompt":"Note","required":false}],"createdAt":"2026-05-01T00:00:02.000Z"}}
        """
    }

    static func setEditorTextRequest(text: String) -> String {
        let encodedText = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return """
        {"id":"event-ui-editor-text","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:02.000Z","type":"extensionUiRequest","request":{"id":"ui-editor-text","sessionId":"session-1","method":"set_editor_text","text":\(encodedText),"createdAt":"2026-05-01T00:00:02.000Z"}}
        """
    }

    static func sessionUpdatedWithPending(
        id: String = "session-1",
        requestId: String = "ui-form",
        status: String = "waiting_for_input",
        summary: String = "Waiting for input",
        updatedAt: String = "2026-05-01T00:00:02.000Z"
    ) -> String {
        """
        {"id":"event-\(id)-pending","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"Investigate current screen","status":"\(status)","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"pendingExtensionUiRequest":{"id":"\(requestId)","sessionId":"\(id)","method":"askUserQuestion","title":"Continue?","prompt":"Pick one","options":null,"questions":[{"id":"choice","type":"radio","prompt":"Choice","options":[{"value":"a","label":"A"}],"required":true}],"createdAt":"\(updatedAt)"}}}
        """
    }

    static func sessionUpdatedWithThinking(
        id: String = "session-1",
        status: String = "running",
        summary: String = "Started",
        thinkingPreview: String,
        updatedAt: String = "2026-05-01T00:00:01.000Z"
    ) -> String {
        let encodedThinking = String(decoding: try! JSONEncoder().encode(thinkingPreview), as: UTF8.self)
        return """
        {"id":"event-\(id)-thinking","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"Investigate current screen","status":"\(status)","cwd":"\(testProjectCwd)","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","thinkingPreview":\(encodedThinking),"logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
        """
    }

    static func sessionLog(sessionId: String, line: String) -> String {
        let encodedLine = String(decoding: try! JSONEncoder().encode(line), as: UTF8.self)
        return """
        {"id":"event-log","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionLogAppended","sessionId":"\(sessionId)","line":\(encodedLine)}
        """
    }

    static func tool(sessionId: String, toolCallId: String, name: String, status: String, preview: String) -> String {
        """
        {"id":"event-tool-\(status)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:03.000Z","type":"toolActivityUpdated","sessionId":"\(sessionId)","tool":{"toolCallId":"\(toolCallId)","name":"\(name)","status":"\(status)","preview":"\(preview)","startedAt":"2026-05-01T00:00:02.000Z","endedAt":null}}
        """
    }

    static func sessionMessageAppended(sessionId: String, messageId: String, text: String, seq: Int) -> String {
        sessionMessageEvent(type: "sessionMessageAppended", sessionId: sessionId, messageId: messageId, text: text, seq: seq)
    }

    static func sessionMessageReplaced(sessionId: String, messageId: String, text: String, seq: Int) -> String {
        sessionMessageEvent(type: "sessionMessageReplaced", sessionId: sessionId, messageId: messageId, text: text, seq: seq)
    }

    static func sessionMessageRemoved(sessionId: String, messageId: String, seq: Int) -> String {
        """
        {"id":"event-message-remove-\(seq)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"sessionMessageRemoved","sessionId":"\(sessionId)","messageId":"\(messageId)","seq":\(seq)}
        """
    }

    static func commandReceiptMessageAppended(sessionId: String, messageId: String, command: String, status: String, detail: String? = nil, seq: Int) -> String {
        let encodedCommand = String(decoding: try! JSONEncoder().encode(command), as: UTF8.self)
        let encodedDetail = detail.map { ",\"detail\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        return """
        {"id":"event-command-receipt-\(seq)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"sessionMessageAppended","sessionId":"\(sessionId)","message":{"id":"\(messageId)","kind":"command_receipt","createdAt":"2026-05-01T00:00:04.000Z","text":\(encodedCommand),"commandReceipt":{"command":\(encodedCommand),"status":"\(status)"\(encodedDetail)}},"seq":\(seq)}
        """
    }

    static func sessionQueueUpdated(sessionId: String, steering: [String], followUp: [String], steeringMode: String?, followUpMode: String?, seq: Int) -> String {
        let steeringItems = queueItemsJSON(steering)
        let followUpItems = queueItemsJSON(followUp)
        let encodedSteeringMode = steeringMode.map { ",\"steeringMode\":\"\($0)\"" } ?? ""
        let encodedFollowUpMode = followUpMode.map { ",\"followUpMode\":\"\($0)\"" } ?? ""
        return """
        {"id":"event-queue-\(seq)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"sessionQueueUpdated","sessionId":"\(sessionId)","steering":\(steeringItems),"followUp":\(followUpItems)\(encodedSteeringMode)\(encodedFollowUpMode),"seq":\(seq)}
        """
    }

    static func sessionActivityUpdated(sessionId: String, edit: Int, bash: Int, thinking: Int, other: Int, seq: Int) -> String {
        """
        {"id":"event-activity-\(seq)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"sessionActivityUpdated","sessionId":"\(sessionId)","activitySummary":{"edit":\(edit),"bash":\(bash),"thinking":\(thinking),"other":\(other)},"seq":\(seq)}
        """
    }

    static func terminalSessionSyncOutcome(
        sessionId: String = "session-1",
        baselineFound: Bool,
        importedMessageCount: Int,
        activeLastMessageId: String? = nil,
        baselinePiMessageId: String? = nil
    ) -> String {
        let active = activeLastMessageId.map { ",\"activeLastMessageId\":\"\($0)\"" } ?? ""
        let baseline = baselinePiMessageId.map { ",\"baselinePiMessageId\":\"\($0)\"" } ?? ""
        return """
        {"id":"event-tso-\(sessionId)-\(importedMessageCount)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"terminalSessionSyncOutcome","sessionId":"\(sessionId)","baselineFound":\(baselineFound),"importedMessageCount":\(importedMessageCount)\(active)\(baseline)}
        """
    }

    private static func sessionMessageEvent(type: String, sessionId: String, messageId: String, text: String, seq: Int) -> String {
        let encodedText = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return """
        {"id":"event-message-\(type)-\(seq)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:04.000Z","type":"\(type)","sessionId":"\(sessionId)","messageId":"\(messageId)","message":{"id":"\(messageId)","kind":"agent_text","createdAt":"2026-05-01T00:00:04.000Z","originatedBy":"main_agent","text":\(encodedText),"question":null,"cancelledAt":null,"report":null,"errorContext":null,"errorMessage":null},"seq":\(seq)}
        """
    }

    private static func queueItemsJSON(_ texts: [String]) -> String {
        let items = texts.map { text in
            let encodedText = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
            return "{\"text\":\(encodedText),\"enqueuedAt\":\"2026-05-01T00:00:04.000Z\"}"
        }
        return "[\(items.joined(separator: ","))]"
    }
}

private extension PickySessionMessage {
    static func fixture(id: String, kind: PickySessionMessageKind, text: String?) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: .mainAgent,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            errorContext: nil,
            errorMessage: nil
        )
    }
}

private extension PickySessionListViewModel.SessionCard {
    static func fixture(artifacts: [PickyArtifact]) -> PickySessionListViewModel.SessionCard {
        PickySessionListViewModel.SessionCard(
            id: "session-links",
            title: "Link task",
            status: .completed,
            cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            lastSummary: "Done",
            thinkingPreview: nil,
            logPreview: "",
            lastRequestText: nil,
            lastRequestAt: nil,
            tools: [],
            artifacts: artifacts,
            changedFiles: [],
            messages: [],
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            activitySummary: .zero,
            pendingExtensionUiRequest: nil,
            piSessionFilePath: nil,
            notifyMainOnCompletion: nil,
            pinned: false,
            archived: false,
            hasRuntimeDetachedFollowUpRejection: false,
            isMainAgentHandoff: false
        )
    }
}

private extension PickyEventEnvelope {
    static func fixture(eventJSON: String) -> PickyEventEnvelope {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(eventJSON.utf8))
    }
}

private extension PickyAgentSession {
    static func fixture(
        lastSummary: String,
        status: PickySessionStatus,
        tools: [PickyToolActivity] = [PickyToolActivity(toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "tests passed", startedAt: nil, endedAt: nil)]
    ) -> PickyAgentSession {
        PickyAgentSession(
            id: "session-report",
            title: "Report task",
            status: status,
            cwd: "/tmp/project",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            lastSummary: lastSummary,
            logs: [],
            tools: tools,
            artifacts: [],
            changedFiles: [],
            pendingExtensionUiRequest: nil
        )
    }
}
