//
//  PickySessionViewModelTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

private final class FakePickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submitted: [PickyAgentSubmission] = []
    private(set) var sentCommands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        submitted.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }
    func send(_ command: PickyCommandEnvelope) async throws { sentCommands.append(command) }
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

private final class FakeSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
}

private final class FakeArchiveStore: PickySessionArchiveStoring {
    var archivedSessionIDs = Set<String>()
    var manuallyArchivedSessionIDs = Set<String>()
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

    @Test func hidesDockUntilInitialSessionSnapshotArrives() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        #expect(viewModel.isLoadingInitialSessionSnapshot)
        viewModel.start()
        try await settle()
        #expect(viewModel.isLoadingInitialSessionSnapshot)

        client.emit(.protocolEvent(.fixture(eventJSON: #"""
        {"id":"snapshot-empty","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:10.000Z","type":"sessionSnapshot","sessions":[]}
        """#)))
        try await settle()

        #expect(viewModel.isLoadingInitialSessionSnapshot == false)
    }

    @Test func createEmptyPickleSessionSendsSystemContextWithSelectedCwd() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.createEmptyPickleSession(cwd: "  /tmp/manual-project  ")

        #expect(client.sentCommands.count == 1)
        let command = try #require(client.sentCommands.first)
        #expect(command.type == .createEmptyPickleSession)
        #expect(command.context?.source == "system")
        #expect(command.context?.cwd == "/tmp/manual-project")
        #expect(command.context?.transcript == nil)
        #expect(command.context?.screenshots.isEmpty == true)
        #expect(command.context?.warnings == ["manualPickle=true"])
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

    @Test func eventSequenceDrivesExpectedStatusChanges() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "queued", summary: "Queued"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Started"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.extensionUiRequest())))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        try await settle()

        #expect(viewModel.sessions.first?.status == .completed)
        #expect(viewModel.sessions.first?.lastSummary == "Done")
        #expect(notifications.delivered.map(\.title).contains("Picky가 입력을 기다립니다"))
        #expect(notifications.delivered.map(\.title).contains("분석이 끝났습니다"))
    }

    @Test func cancelledSessionAcceptsRunningUpdateAfterSteeringResume() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "cancelled", summary: "Cancelled"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Steering message sent", updatedAt: "2026-05-01T00:00:10.000Z"))))
        try await settle()

        #expect(viewModel.sessions.first?.status == .running)
        #expect(viewModel.sessions.first?.lastSummary == "Steering message sent")
    }

    @Test func sessionsRemainOrderedByCreationTimeAcrossStatusChanges() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "completed", title: "Completed", status: "completed", createdAt: "2026-05-01T00:00:00.000Z", updatedAt: "2026-05-01T00:00:30.000Z"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "running", title: "Running", status: "running", createdAt: "2026-05-01T00:00:20.000Z", updatedAt: "2026-05-01T00:00:00.000Z"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "waiting", title: "Waiting", status: "waiting_for_input", createdAt: "2026-05-01T00:00:10.000Z", updatedAt: "2026-05-01T00:00:40.000Z"))))
        try await settle()

        #expect(viewModel.sessions.map(\.id) == ["running", "waiting", "completed"])
        #expect(viewModel.sessions.contains { $0.id == "completed" && $0.status == .completed })
    }

    @Test func toolEventsCorrelateByToolCallId() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated())))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.tool(sessionId: "session-1", toolCallId: "tool-1", name: "bash", status: "running", preview: "pnpm test"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.tool(sessionId: "session-1", toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "passed"))))
        try await settle()

        let tools = viewModel.sessions.first?.tools ?? []
        #expect(tools.count == 1)
        #expect(tools.first?.status == "succeeded")
        #expect(tools.first?.preview == "passed")
        #expect(tools.first?.riskLevel == .elevated)
    }

    @Test func stopButtonDispatchesAbortCommandAndUpdatesState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running"))))
        try await settle()
        try await viewModel.abort(sessionID: "session-1")

        let abortCommand = try #require(client.sentCommands.first { $0.type == .abort })
        #expect(abortCommand.sessionId == "session-1")
        #expect(viewModel.sessions.first?.status == .cancelled)
    }

    @Test func extensionUiAnswersEmitConfirmValueAndCancellationCommands() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.extensionUiRequest())))
        try await settle()

        try await viewModel.answerExtensionUi(sessionID: "session-1", requestID: "ui-1", value: .bool(true))
        try await viewModel.cancelExtensionUi(sessionID: "session-1", requestID: "ui-2")

        let answers = client.sentCommands.filter { $0.type == .answerExtensionUi }
        #expect(answers.first?.sessionId == "session-1")
        #expect(answers.first?.requestId == "ui-1")
        #expect(answers.first?.value == .bool(true))
        #expect(answers.last?.requestId == "ui-2")
        #expect(answers.last?.value == .object(["cancelled": .bool(true)]))
    }

    @Test func setEditorTextRequestPrimesComposerDraftWithoutWaitingState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Started"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.setEditorTextRequest(text: "review comments"))))
        try await settle()

        let draftRequest = try #require(viewModel.composerDraftRequest(for: "session-1"))
        #expect(draftRequest.text == "review comments")
        #expect(viewModel.sessions.first?.status == .running)
        #expect(viewModel.sessions.first?.pendingExtensionUiRequest == nil)

        viewModel.consumeComposerDraftRequest(sessionID: "session-1", requestID: draftRequest.id)
        #expect(viewModel.composerDraftRequest(for: "session-1") == nil)
    }

    @Test func askUserQuestionRequestStoresQuestionsAndSendsCompositeAnswer() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.askUserQuestionRequest())))
        try await settle()

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

    @Test func extensionUiAnswerLogLineUpdatesLastRequestText() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: 계속 진행해줘."))))
        try await settle()
        #expect(viewModel.sessions.first?.lastRequestText == "계속 진행해줘.")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "extension ui answer: Stop and review"))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.lastRequestText == "Stop and review")
    }

    @Test func sessionUpdateClearsPendingExtensionUiRequestWhenIncomingHasNone() async throws {
        // Reproduces the askUserQuestion form sticking around after Submit: a stale sessionUpdated
        // that was queued by the daemon before it processed the answer arrives after Picky's local
        // clear and re-attaches the pending request. The daemon's subsequent post-answer
        // sessionUpdated carries an explicit `nil`, so the merge must trust it instead of falling
        // back to the just-resurrected existing value.
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(status: "waiting_for_input"))))
        try await settle()
        #expect(viewModel.sessions.first?.pendingExtensionUiRequest != nil)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Extension UI answered", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.status == .running)
    }

    @Test func sessionUpdateClearsThinkingPreviewWhenIncomingHasNone() async throws {
        // Daemon explicitly drops `thinkingPreview` on terminal status and on extension UI answer
        // (runtime-event-handler.applyStatusEvent + supervisor.answerExtensionUi). The merge used
        // to fall back to the existing value whenever the incoming snapshot carried `nil`, so the
        // previous "Thinking: ..." stayed pinned to the card and would briefly resurface the next
        // time the session re-entered `.running` (e.g. after a follow-up).
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithThinking(status: "running", thinkingPreview: "deciding next step"))))
        try await settle()
        #expect(viewModel.sessions.first?.thinkingPreview == "deciding next step")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.thinkingPreview == nil)
        #expect(card.status == .completed)
    }

    @Test func answerExtensionUiKeepsPriorRequestTextWhenUserCancels() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "waiting_for_input"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: 계속 진행해줘."))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.askUserQuestionRequest())))
        try await settle()

        try await viewModel.cancelExtensionUi(sessionID: "session-1", requestID: "ui-form")

        let card = try #require(viewModel.sessions.first)
        #expect(card.pendingExtensionUiRequest == nil)
        #expect(card.lastRequestText == "계속 진행해줘.")
    }

    @Test func terminalNotificationsAreDeduplicated() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done again"))))
        try await settle()

        #expect(notifications.delivered.filter { $0.identifier == "session-1:completed" }.count == 1)
    }

    @Test func terminalNotificationResetsAfterSessionRunsAgain() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "First done"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Running again"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Second done", updatedAt: "2026-05-01T00:00:10.000Z"))))
        try await settle()

        #expect(notifications.delivered.filter { $0.identifier == "session-1:completed" }.count == 2)
    }

    @Test func snapshotHydrationDoesNotNotifyHistoricalCompletedSessions() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(status: "completed", summary: "Already done"))))
        try await settle()

        #expect(notifications.delivered.isEmpty)
    }

    @Test func snapshotTransitionFromRunningToCompletedDeliversNotification() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Running"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:10.000Z"))))
        try await settle()

        #expect(notifications.delivered.map(\.title).contains("분석이 끝났습니다"))
    }

    @Test func pinnedPickleSessionDoesNotDeliverCompletedNotification() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Pinned completed Pi session", pinned: true))))
        try await settle()

        #expect(viewModel.sessions.first?.status == .completed)
        #expect(viewModel.sessions.first?.pinned == true)
        #expect(!notifications.delivered.map(\.title).contains("분석이 끝났습니다"))
    }

    @Test func notifyOnCompletedToggleSuppressesCompletedBanner() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: false,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        try await settle()

        #expect(!notifications.delivered.map(\.title).contains("분석이 끝났습니다"))
    }

    @Test func notifyOnFailedToggleSuppressesFailureBanner() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: false,
            notifyOnWaitingForInput: true
        ))
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "failed", summary: "Boom"))))
        try await settle()

        #expect(!notifications.delivered.map(\.title).contains("Picky 작업이 실패했습니다"))
    }

    @Test func notifyOnWaitingForInputToggleSuppressesPendingBanner() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences(notificationPreferences: PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: false
        ))
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(status: "waiting_for_input", summary: "Waiting"))))
        try await settle()

        #expect(!notifications.delivered.map(\.title).contains("Picky가 입력을 기다립니다"))
    }

    @Test func waitingForInputWithoutPendingRequestDoesNotDeliverBanner() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            title: "New Pickle · manual-project",
            status: "waiting_for_input",
            summary: "Ready for instructions"
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.status == .waiting_for_input)
        #expect(!notifications.delivered.map(\.title).contains("Picky가 입력을 기다립니다"))
    }

    @Test func defaultNotificationPreferencesPreserveExistingDeliveryBehavior() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let preferences = PickyStubNotificationPreferences()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: notifications,
            notificationPreferencesProvider: preferences
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "failure", status: "failed", summary: "Boom", updatedAt: "2026-05-01T00:00:10.000Z"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdatedWithPending(id: "pending", status: "waiting_for_input", summary: "Waiting", updatedAt: "2026-05-01T00:00:20.000Z"))))
        try await settle()

        let titles = notifications.delivered.map(\.title)
        #expect(titles.contains("분석이 끝났습니다"))
        #expect(titles.contains("Picky 작업이 실패했습니다"))
        #expect(titles.contains("Picky가 입력을 기다립니다"))
    }

    @Test func unpinnedAfterFollowUpDeliversCompletedNotification() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications, notificationPreferencesProvider: PickyStubNotificationPreferences(notificationPreferences: .defaults))
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Pinned completed Pi session", pinned: true))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "running", summary: "Steering message sent", updatedAt: "2026-05-01T00:00:10.000Z", pinned: false))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:20.000Z", pinned: false))))
        try await settle()

        #expect(viewModel.sessions.first?.pinned == false)
        #expect(notifications.delivered.map(\.title).contains("분석이 끝났습니다"))
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
        #expect(PickyConversationScrollPolicy.initialScrollDelayNanoseconds == 16_000_000)
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

    @Test func hudDockHeldStateIsExclusiveAcrossClicks() throws {
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: nil, clicked: "agent-a") == .open("agent-a"))
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-a") == nil)
        #expect(PickyHUDDockLayout.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-b") == .open("agent-b"))
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
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 0, charactersIgnoringModifiers: "R", modifiers: .command) == true)
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
            url: URL(string: "https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249")!,
            updatedAt: Date()
        )
        let notion = PickyArtifact(
            id: "notion-1",
            kind: "notion",
            title: "Notion",
            path: nil,
            url: URL(string: "https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226")!,
            updatedAt: Date()
        )
        let jira = PickyArtifact(id: "jira-1", kind: "jira", title: "COM-123", path: nil, url: URL(string: "https://creatrip.atlassian.net/browse/COM-123")!, updatedAt: Date())
        let sentry = PickyArtifact(id: "sentry-1", kind: "sentry", title: "Sentry", path: nil, url: URL(string: "https://creatrip.sentry.io/issues/1234567890/")!, updatedAt: Date())
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
        let jira = PickyArtifact(id: "jira-1", kind: "jira", title: "COM-123", path: nil, url: URL(string: "https://creatrip.atlassian.net/browse/COM-123")!, updatedAt: Date())
        let linear = PickyArtifact(id: "linear-1", kind: "linear", title: "ENG-456", path: nil, url: URL(string: "https://linear.app/acme/issue/ENG-456/fix-checkout")!, updatedAt: Date())
        let slack = PickyArtifact(id: "slack-1", kind: "slack", title: "Slack", path: nil, url: URL(string: "https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249")!, updatedAt: Date())
        let notion1 = PickyArtifact(id: "notion-1", kind: "notion", title: "Notion", path: nil, url: URL(string: "https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226")!, updatedAt: Date())
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
        let slackArtifact = PickyArtifact(id: "e", kind: "slack", title: "Slack", path: nil, url: URL(string: "https://creatrip.slack.com/archives/C012/p1")!, updatedAt: Date())
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

    @Test func selectionDefaultsForHudButOnlyExplicitSelectionPersistsForHoveredVoiceFollowUp() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "older", status: "completed", updatedAt: "2026-05-01T00:00:01.000Z"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "newer", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

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
        try await settle()
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
        try await settle()
        #expect(archiveStore.archivedSessionIDs == ["pickle-1"])
        #expect(viewModel.sessions.map(\.id) == ["main-1"])
        let archiveCommand = try #require(client.sentCommands.first { $0.type == .setSessionArchived })
        #expect(archiveCommand.sessionId == "pickle-1")
        #expect(archiveCommand.archived == true)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Updated"))))
        try await settle()
        #expect(viewModel.sessions.map(\.id) == ["main-1"])
        #expect(viewModel.archivedSessions.first(where: { $0.id == "pickle-1" })?.lastSummary == "Updated")
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

    @Test func copyTerminalResumeCommandUsesCapturedPiSessionFileAndCwd() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let clipboard = FakeClipboardWriter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: notifications,
            clipboardWriter: clipboard
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.copyTerminalResumeCommand(sessionID: "pickle-1")

        #expect(clipboard.copied == ["cd '/Users/creatrip/Documents/picky' && pi --session '/tmp/pi-session.jsonl'"])
        // Resume command intentionally no longer fires a macOS banner; clipboard write is the
        // only visible feedback so users do not get a redundant notification on every copy.
        #expect(!notifications.delivered.contains(where: { $0.title == "Pi resume command copied" }))
        #expect(viewModel.lastError == nil)
    }

    @Test func openTerminalOverlayUsesCapturedPiSessionFileAndCwd() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "completed",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "pickle-1")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-1",
            title: "Pickle",
            sessionFilePath: "/tmp/pi-session.jsonl",
            cwd: "/Users/creatrip/Documents/picky"
        )])
        #expect(viewModel.lastError == nil)
    }

    @Test func openTerminalOverlayUsesExplicitPiSessionFileWhenLogsAreCompacted() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-explicit",
            title: "Pickle",
            status: "completed",
            logs: ["recent compacted log without session path"],
            piSessionFilePath: "/tmp/explicit-pi-session.jsonl"
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "pickle-explicit")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-explicit",
            title: "Pickle",
            sessionFilePath: "/tmp/explicit-pi-session.jsonl",
            cwd: "/Users/creatrip/Documents/picky"
        )])
        #expect(viewModel.lastError == nil)
    }

    @Test func openTerminalOverlayWorksWhileSessionIsActive() async throws {
        // Earlier history pill should stay clickable even while the Pickle is still working
        // (running, queued, waiting_for_input). The overlay launches its own `pi --session` process
        // pointed at the on-disk session file, so the user gets a transcript view of the live run
        // even though the daemon is still writing to it.
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pickle-1",
            title: "Pickle",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "pickle-1")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "pickle-1",
            title: "Pickle",
            sessionFilePath: "/tmp/pi-session.jsonl",
            cwd: "/Users/creatrip/Documents/picky"
        )])
        #expect(viewModel.lastError == nil)
    }

    @Test func sessionCardExtractsPiSessionFileFromHandoffTranscript() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pinned-pickle",
            title: "Pinned",
            status: "completed",
            logs: ["source transcript:\n## Source Pi session\n- Session file: /tmp/from-handoff.jsonl"]
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.piSessionFilePath == "/tmp/from-handoff.jsonl")
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
        try await settle()

        #expect(syncer.paths == ["/tmp/pi-session.jsonl"])
        let command = try #require(client.sentCommands.last)
        #expect(command.type == .syncTerminalSession)
        #expect(command.sessionId == "pickle-1")
        #expect(command.baselinePiMessageId == "a1")
        #expect(viewModel.sessions.first?.lastSummary == "Old summary")
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
        try await settle()

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .syncTerminalSession)
        #expect(command.sessionId == "pickle-1")
        #expect(command.baselinePiMessageId == nil)
        #expect(viewModel.sessions.first?.lastSummary == "Stored summary")
    }

    @Test func terminalSyncOutcomeWithImportsSetsBannerState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: true, importedMessageCount: 2
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome?.importedMessageCount == 2)
    }

    @Test func terminalSyncOutcomeWithBaselineMissingSetsBannerState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: false, importedMessageCount: 0
        ))))
        try await settle()

        let outcome = try #require(viewModel.sessions.first?.lastTerminalSyncOutcome)
        #expect(outcome.baselineFound == false)
    }

    @Test func terminalSyncOutcomeWithNothingNewIsSuppressed() async throws {
        // baselineFound + 0 imports is the silent "nothing changed" case;
        // suppressing it upstream keeps the HUD from showing a banner that
        // just confirms what the user already saw when the terminal closed.
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.terminalSessionSyncOutcome(
            sessionId: "pickle-1", baselineFound: true, importedMessageCount: 0
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.lastTerminalSyncOutcome == nil)
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

    @Test func extensionUiLogsAreHiddenFromRecentLogPreview() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            status: "running",
            logs: ["visible log", "extension ui: setWidget"]
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.logPreview == "visible log")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "extension ui: notify"))))
        try await settle()
        #expect(viewModel.sessions.first?.logPreview == "visible log")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "done"))))
        try await settle()
        #expect(viewModel.sessions.first?.logPreview == "done")
    }

    @Test func sessionCardsExposeLastRequestAndCompactCwd() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            status: "running",
            logs: ["Picky handoff: initial screen check", "steer: summarize the failing case"]
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.lastRequestText == "summarize the failing case")
        #expect(viewModel.sessions.first?.compactCwdDescription == "~/Documents/picky")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "steer: include CWD in the HUD"))))
        try await settle()
        #expect(viewModel.sessions.first?.lastRequestText == "include CWD in the HUD")
    }

    @Test func liveTransitionToCompletedQueuesDoneFlash() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.contains("pickle-1"))

        viewModel.markDoneFlashConsumed(sessionID: "pickle-1")
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        // A duplicate .completed update (e.g. a tool/log patch arriving after the terminal
        // status) must not re-queue the flash within the same completion phase.
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Resent", updatedAt: "2026-05-01T00:00:10.000Z"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @Test func snapshotHydrationDoesNotQueueDoneFlashForHistoricalCompletedSessions() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionSnapshot(id: "historical", title: "Historical", status: "completed", summary: "Already done"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        // Snapshot already populated previousStatus = .completed for this session, so a follow-up
        // sessionUpdated still in .completed must not retroactively flash.
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "historical", title: "Historical", status: "completed", summary: "Updated", updatedAt: "2026-05-01T00:00:10.000Z"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @Test func firstSightCompletedSessionDoesNotFlash() async throws {
        // A brand-new session whose first sessionUpdated already carries .completed (e.g. a
        // synthesized snapshot from the daemon catching up) must not flash, since the user
        // didn't watch it transition. previousStatus is nil for the first sight.
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "first-sight", title: "First sight", status: "completed"))))
        try await settle()
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)
    }

    @Test func sessionRunsAgainAndCompletesLiveQueuesNewDoneFlash() async throws {
        // After a follow-up sends the session back to .running and it completes again, the new
        // live transition should queue a fresh flash. This mirrors the completion notification
        // dedupe reset in resetTerminalNotificationKeysIfNeeded.
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()
        viewModel.markDoneFlashConsumed(sessionID: "pickle-1")
        #expect(viewModel.pendingDoneFlashSessionIDs.isEmpty)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "running", summary: "Working", updatedAt: "2026-05-01T00:00:10.000Z"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "pickle-1", title: "Pickle", status: "completed", summary: "Done again", updatedAt: "2026-05-01T00:00:20.000Z"))))
        try await settle()

        #expect(viewModel.pendingDoneFlashSessionIDs.contains("pickle-1"))
    }

    @Test func runtimeDetachedRestoredSessionsStayVisibleAndClearAutoArchiveState() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        archiveStore.archivedSessionIDs = ["lost-runtime", "manual-completed"]
        archiveStore.manuallyArchivedSessionIDs = ["manual-completed"]
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-detached","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionSnapshot","sessions":[{"id":"lost-runtime","title":"Old Pickle","status":"blocked","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Runtime not attached after daemon restart; start a new task or resume support is required","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},{"id":"manual-completed","title":"Manual archive","status":"completed","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Done","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}]}
        """)))
        try await settle()

        #expect(viewModel.sessions.map(\.id) == ["lost-runtime"])
        #expect(viewModel.archivedSessions.map(\.id) == ["manual-completed"])
        #expect(archiveStore.archivedSessionIDs == ["manual-completed"])

        viewModel.archive(sessionID: "lost-runtime")
        #expect(archiveStore.archivedSessionIDs == ["lost-runtime", "manual-completed"])
        #expect(archiveStore.manuallyArchivedSessionIDs == ["lost-runtime", "manual-completed"])

        client.emit(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-detached-2","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionSnapshot","sessions":[{"id":"lost-runtime","title":"Old Pickle","status":"blocked","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:01.000Z","lastSummary":"Runtime not attached after daemon restart; start a new task or resume support is required","logs":[],"tools":[],"artifacts":[],"changedFiles":[]},{"id":"manual-completed","title":"Manual archive","status":"completed","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Done","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}]}
        """)))
        try await settle()
        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["lost-runtime", "manual-completed"])
    }

    @Test func runtimeDetachedFollowUpFailureStaysVisible() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        archiveStore.archivedSessionIDs = ["followup-detached"]
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "followup-detached",
            title: "Detached Pickle",
            status: "blocked",
            summary: "Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(
            sessionId: "followup-detached",
            line: "steer rejected: Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))
        try await settle()

        #expect(viewModel.sessions.map(\.id) == ["followup-detached"])
        #expect(viewModel.sessions.first?.status == .blocked)
        #expect(viewModel.sessions.first?.isRuntimeDetached == true)
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(archiveStore.archivedSessionIDs.isEmpty)
    }

    @Test func textSteerTargetsSelectedSessionAndRejectsEmptyInput() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-follow", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        try await viewModel.steer(text: "  continue here  ")
        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.sessionId == "session-follow")
        #expect(client.sentCommands.last?.text == "continue here")
        await #expect(throws: PickySessionListViewModelError.emptyFollowUp) {
            try await viewModel.steer(text: "   ")
        }
    }

    @Test func pinnedCompletedSessionAcceptsFollowUpCommand() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pinned-completed",
            title: "Pinned completed Pi session",
            status: "completed",
            summary: "Pinned completed Pi session",
            updatedAt: "2026-05-01T00:00:05.000Z",
            pinned: true
        ))))
        try await settle()

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

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot())))
        try await settle()

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
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot())))
        try await settle()
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:05.000Z",
            cwd: "/tmp/new-product",
            piSessionFilePath: "/tmp/old-pi.jsonl"
        ))))
        try await settle()
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await settle()
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2)

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot())))
        try await settle()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:10.000Z",
            cwd: "/tmp/new-product",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))
        try await settle()
        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await settle()
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 3)
    }

    @Test func slashCommandCacheInvalidatesWhenRuntimeReattachLogArrives() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-commands"))))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.slashCommandsSnapshot())))
        try await settle()
        #expect(viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-commands",
            updatedAt: "2026-05-01T00:00:05.000Z",
            logs: ["runtime reattached from pi session: /tmp/pi.jsonl"],
            piSessionFilePath: "/tmp/pi.jsonl"
        ))))
        try await settle()

        #expect(!viewModel.hasLoadedSlashCommands(sessionID: "session-commands"))
        viewModel.ensureSlashCommandsLoaded(sessionID: "session-commands")
        try await settle()
        #expect(client.sentCommands.filter { $0.type == .listSlashCommands }.count == 2)
    }

    @Test func slashCommandAutocompleteSelectionWrapsWithArrowNavigation() {
        #expect(PickySlashCommandAutocompletePolicy.clampedSelectionIndex(10, suggestionCount: 3) == 2)
        #expect(PickySlashCommandAutocompletePolicy.clampedSelectionIndex(-2, suggestionCount: 3) == 0)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 0, suggestionCount: 3, direction: .down) == 1)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 2, suggestionCount: 3, direction: .down) == 0)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 0, suggestionCount: 3, direction: .up) == 2)
        #expect(PickySlashCommandAutocompletePolicy.movedSelectionIndex(current: 2, suggestionCount: 0, direction: .up) == 0)
    }

    @Test func textSteerCanTargetCancelledSessionByExplicitID() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-cancelled", status: "cancelled", summary: "Cancelled", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        try await viewModel.steer(text: "  다시 진행해줘  ", sessionID: "session-cancelled")

        #expect(client.sentCommands.last?.type == .steer)
        #expect(client.sentCommands.last?.sessionId == "session-cancelled")
        #expect(client.sentCommands.last?.text == "다시 진행해줘")
        #expect(viewModel.sessions.first?.status == .cancelled)
        #expect(viewModel.sessions.first?.lastRequestText == "다시 진행해줘")
    }

    @Test func notifyMainToggleSendsCommandAndUpdatesSession() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "session-notify",
            status: "completed",
            updatedAt: "2026-05-01T00:00:05.000Z",
            notifyMainOnCompletion: true
        ))))
        try await settle()

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

    @Test func openReportByMessageIDOpensThatSpecificMessageNotJustTheLatest() async throws {
        // The HUD bubble's hover icon needs to be able to expand any message in
        // the conversation, not just the most recent agent reply. Verify that
        // passing a specific messageID opens that message (here: the first of
        // two appended replies) and uses a per-message file name + title.
        let generatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-msg-report-\(UUID().uuidString)", isDirectory: true)
        let presenter = FakeReportPresenter()
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter,
            generatedReportDirectory: generatedRoot
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "msg-session", title: "Multi reply", status: "completed"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "msg-session", messageId: "msg-1", text: "# First", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "msg-session", messageId: "msg-2", text: "# Second", seq: 2))))
        try await settle()

        try await viewModel.openReport(sessionID: "msg-session", messageID: "msg-1")

        let call = try #require(presenter.calls.first)
        #expect(call.sessionID == "msg-session:message:msg-1")
        #expect(call.title == "Multi reply \u{2014} Response")
        #expect(call.fileURL.lastPathComponent == "response-msg-1.md")
        #expect(call.markdown == "# First")
        #expect(FileManager.default.fileExists(atPath: call.fileURL.path))
    }

    @Test func openLatestAgentResponseReportOpensNewestAgentTextOnly() async throws {
        let generatedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("picky-latest-response-report-\(UUID().uuidString)", isDirectory: true)
        let presenter = FakeReportPresenter()
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter,
            generatedReportDirectory: generatedRoot
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "latest-response-session", title: "Latest", status: "completed"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "latest-response-session", messageId: "msg-1", text: "# First", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "latest-response-session", messageId: "msg-2", text: "# Second", seq: 2))))
        try await settle()

        #expect(viewModel.sessions.first?.latestAgentResponseReportMessageID == "msg-2")
        #expect(viewModel.sessions.first?.hasLatestAgentResponseReport == true)

        try await viewModel.openLatestAgentResponseReport(sessionID: "latest-response-session")

        let call = try #require(presenter.calls.first)
        #expect(call.sessionID == "latest-response-session:message:msg-2")
        #expect(call.title == "Latest \u{2014} Response")
        #expect(call.fileURL.lastPathComponent == "response-msg-2.md")
        #expect(call.markdown == "# Second")
    }

    @Test func openReportByMessageIDThrowsWhenMessageHasNoMarkdownContent() async throws {
        // Activity-only or empty messages shouldn't be openable as reports. The
        // hover icon avoids invoking this path for such messages, but the API
        // itself should still fail safely if called.
        let presenter = FakeReportPresenter()
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            reportPresenter: presenter
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "empty-msg-session", title: "Empty", status: "completed"))))
        try await settle()

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

    @Test func sessionMessageIncrementalEventsAppendReplaceRemoveAndIgnoreStaleSeq() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "conversation-session"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-1", text: "first", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageReplaced(sessionId: "conversation-session", messageId: "m-1", text: "updated", seq: 2))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-stale", text: "stale", seq: 2))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageRemoved(sessionId: "conversation-session", messageId: "m-1", seq: 3))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "conversation-session", messageId: "m-old", text: "old", seq: 1))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.messages.isEmpty)
    }

    @Test func sessionQueueUpdatedAppliesModesAndPreservesExistingModeWhenNil() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "queue-session"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "queue-session", steering: ["steer"], followUp: ["follow"], steeringMode: "all", followUpMode: "all", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "queue-session", steering: ["steer-2"], followUp: [], steeringMode: nil, followUpMode: nil, seq: 2))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.queuedSteers.map(\.text) == ["steer-2"])
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.steeringMode == .all)
        #expect(card.followUpMode == .all)
    }

    @Test func sessionUpdatedAfterIncrementalEventDoesNotResetConversationRenderState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "live-conversation", status: "running"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "live-conversation", messageId: "m-1", text: "rendered answer", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "live-conversation", steering: [], followUp: ["queued follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        // Runtime status/tool patches still broadcast full sessionUpdated snapshots. They often
        // carry transient empty conversation arrays because the granular message/queue events are
        // the live render source of truth. Those snapshots must not make bubbles disappear.
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "live-conversation", status: "completed", summary: "Done", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.status == .completed)
        #expect(card.messages.map(\.text) == ["rendered answer"])
        #expect(card.queuedFollowUps.map(\.text) == ["queued follow-up"])
    }

    @Test func sessionUpdatedWithNewPiSessionFileResetsIncrementalConversationState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "replaced-session", status: "completed", piSessionFilePath: "/tmp/old-pi.jsonl"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "replaced-session", messageId: "m-1", text: "old answer", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "replaced-session", steering: [], followUp: ["old follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "replaced-session",
            title: "New Pickle · picky",
            status: "waiting_for_input",
            summary: "Ready for instructions",
            updatedAt: "2026-05-01T00:00:05.000Z",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.title == "New Pickle · picky")
        #expect(card.status == .waiting_for_input)
        #expect(card.lastSummary == "Ready for instructions")
        #expect(card.messages.isEmpty)
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.piSessionFilePath == "/tmp/new-pi.jsonl")
    }

    @Test func freshPiSessionResetClearsConversationEvenIfDiagnosticLogAlreadyUpdatedPath() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "replaced-session", status: "completed", piSessionFilePath: "/tmp/old-pi.jsonl"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionMessageAppended(sessionId: "replaced-session", messageId: "m-1", text: "old answer", seq: 1))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionQueueUpdated(sessionId: "replaced-session", steering: [], followUp: ["old follow-up"], steeringMode: nil, followUpMode: nil, seq: 2))))

        // PiSdkRuntime used to emit the new `pi session:` diagnostic before the replacement
        // snapshot. The log event pre-updated the card's piSessionFilePath, so the subsequent
        // empty replacement snapshot looked like an ordinary transient sessionUpdated and the HUD
        // preserved stale Earlier history.
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "replaced-session", line: "pi session: /tmp/new-pi.jsonl"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "replaced-session",
            title: "New Pickle · picky",
            status: "waiting_for_input",
            summary: "Ready for instructions",
            updatedAt: "2026-05-01T00:00:05.000Z",
            piSessionFilePath: "/tmp/new-pi.jsonl"
        ))))
        try await settle()

        let card = try #require(viewModel.sessions.first)
        #expect(card.title == "New Pickle · picky")
        #expect(card.status == .waiting_for_input)
        #expect(card.lastSummary == "Ready for instructions")
        #expect(card.messages.isEmpty)
        #expect(card.queuedFollowUps.isEmpty)
        #expect(card.logPreview.isEmpty)
        #expect(card.piSessionFilePath == "/tmp/new-pi.jsonl")
    }

    @Test func sessionActivityUpdatedMirrorsSummary() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "activity-session"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionActivityUpdated(sessionId: "activity-session", edit: 2, bash: 3, thinking: 4, other: 5, seq: 1))))
        try await settle()

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
}

private func waitForCommand(_ type: PickyCommandType, in client: FakePickyAgentClient) async throws {
    for _ in 0..<20 {
        if client.sentCommands.contains(where: { $0.type == type }) { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(client.sentCommands.contains { $0.type == type })
}

private func settle() async throws {
    try await Task.sleep(nanoseconds: 200_000_000)
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
        cwd: String = "/Users/creatrip/Documents/picky",
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
        piSessionFilePath: String? = nil
    ) -> String {
        let encodedLogs = String(decoding: try! JSONEncoder().encode(logs), as: UTF8.self)
        let encodedPiSessionFilePath = piSessionFilePath.map { ",\"piSessionFilePath\":\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))" } ?? ""
        return """
        {"id":"snapshot-\(id)-\(status)","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionSnapshot","sessions":[{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"/Users/creatrip/Documents/picky","createdAt":"\(createdAt)","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":\(encodedLogs),"tools":[],"artifacts":[],"changedFiles":[]\(encodedPiSessionFilePath)}]}
        """
    }

    static func slashCommandsSnapshot() -> String {
        """
        {"id":"event-slash-commands","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"slashCommandsSnapshot","sessionId":"session-commands","commands":[{"name":"deploy","description":"Deploy an environment","source":"extension"},{"name":"fix-tests","description":"Fix failing tests","source":"prompt"},{"name":"skill:context7-cli","description":"Look up library docs","source":"skill"}]}
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
        status: String = "waiting_for_input",
        summary: String = "Waiting for input",
        updatedAt: String = "2026-05-01T00:00:02.000Z"
    ) -> String {
        """
        {"id":"event-\(id)-pending","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"Investigate current screen","status":"\(status)","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"pendingExtensionUiRequest":{"id":"ui-form","sessionId":"\(id)","method":"askUserQuestion","title":"Continue?","prompt":"Pick one","options":null,"questions":[{"id":"choice","type":"radio","prompt":"Choice","options":[{"value":"a","label":"A"}],"required":true}],"createdAt":"\(updatedAt)"}}}
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
        {"id":"event-\(id)-thinking","protocolVersion":"2026-05-09","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"Investigate current screen","status":"\(status)","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","thinkingPreview":\(encodedThinking),"logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
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
