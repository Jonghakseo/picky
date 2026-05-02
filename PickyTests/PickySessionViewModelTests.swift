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

private final class FakeTerminalSessionSyncer: PickyTerminalSessionSyncing {
    var snapshots: [String: PickyTerminalSessionSnapshot] = [:]
    private(set) var paths: [String] = []

    func snapshot(sessionFilePath: String) throws -> PickyTerminalSessionSnapshot {
        paths.append(sessionFilePath)
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
        try await settle()

        #expect(client.sentCommands.contains { $0.type == .listSessions })
    }

    @Test func eventSequenceDrivesExpectedStatusChanges() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications)
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
    }

    @Test func terminalNotificationsAreDeduplicated() async throws {
        let client = FakePickyAgentClient()
        let notifications = PickyNoopNotificationCenter()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: notifications)
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(status: "completed", summary: "Done again"))))
        try await settle()

        #expect(notifications.delivered.filter { $0.identifier == "session-1:completed" }.count == 1)
    }

    @Test func hudStatusToneMatchesSideAgentColorRules() throws {
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

    @Test func hudExpansionDefersOuterPanelShrinkUntilCollapseFinishes() throws {
        #expect(PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 320, targetHeight: 80, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 80, targetHeight: 320, deferShrink: true))
        #expect(!PickyHUDExpansion.shouldDeferPanelShrink(currentHeight: 320, targetHeight: 80, deferShrink: false))
        #expect(PickyHUDExpansion.panelShrinkDelay > PickyHUDExpansion.duration)
        #expect(PickyHUDExpansion.anchorsContentToPanelTopDuringDeferredShrink)
    }

    @Test func hudChromeUsesSoftShadowWithExtraTransparentPadding() throws {
        #expect(PickyHUDExpansion.outerPadding > 8)
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

    @Test func archivedSessionsStayHiddenAcrossSnapshots() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "side-1", title: "Side", status: "completed"))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "main-1", title: "Main", status: "completed"))))
        try await settle()

        viewModel.archive(sessionID: "side-1")
        #expect(archiveStore.archivedSessionIDs == ["side-1"])
        #expect(viewModel.sessions.map(\.id) == ["main-1"])

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "side-1", title: "Side", status: "completed", summary: "Updated"))))
        try await settle()
        #expect(viewModel.sessions.map(\.id) == ["main-1"])
        #expect(viewModel.archivedSessions.first(where: { $0.id == "side-1" })?.lastSummary == "Updated")
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
            id: "side-1",
            title: "Side",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.copyTerminalResumeCommand(sessionID: "side-1")

        #expect(clipboard.copied == ["cd '/Users/creatrip/Documents/picky' && pi --session '/tmp/pi-session.jsonl'"])
        #expect(notifications.delivered.last?.title == "Pi resume command copied")
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
            id: "side-1",
            title: "Side",
            status: "completed",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "side-1")

        #expect(presenter.calls == [FakeTerminalOverlayPresenter.Call(
            sessionID: "side-1",
            title: "Side",
            sessionFilePath: "/tmp/pi-session.jsonl",
            cwd: "/Users/creatrip/Documents/picky"
        )])
        #expect(viewModel.lastError == nil)
    }

    @Test func openTerminalOverlayRejectsActiveSessions() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "side-1",
            status: "running",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "side-1")

        #expect(presenter.calls.isEmpty)
        #expect(viewModel.lastError == PickySessionListViewModelError.sessionActiveForTerminal.localizedDescription)
    }

    @Test func sessionCardExtractsPiSessionFileFromHandoffTranscript() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "pinned-side",
            title: "Pinned",
            status: "completed",
            logs: ["source transcript:\n## Source Pi session\n- Session file: /tmp/from-handoff.jsonl"]
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.piSessionFilePath == "/tmp/from-handoff.jsonl")
    }

    @Test func terminalOverlayCloseSyncsSessionFileOnce() async throws {
        let client = FakePickyAgentClient()
        let presenter = FakeTerminalOverlayPresenter()
        let syncer = FakeTerminalSessionSyncer()
        syncer.snapshots["/tmp/pi-session.jsonl"] = PickyTerminalSessionSnapshot(
            lastUserText: "what changed?",
            lastAssistantText: "Here is a synced terminal answer with enough text to be visible in the card."
        )
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            terminalPresenter: presenter,
            terminalSessionSyncer: syncer
        )
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "side-1",
            title: "Side",
            status: "completed",
            summary: "Old summary",
            logs: ["pi session: /tmp/pi-session.jsonl"]
        ))))
        try await settle()

        viewModel.openTerminalOverlay(sessionID: "side-1")
        presenter.close(sessionID: "side-1")

        #expect(syncer.paths == ["/tmp/pi-session.jsonl"])
        #expect(viewModel.sessions.first?.lastRequestText == "what changed?")
        #expect(viewModel.sessions.first?.lastSummary == "Here is a synced terminal answer with enough text to be visible in the card.")
        #expect(viewModel.sessions.first?.logPreview == "Synced from Pi terminal session")
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
            logs: ["main-agent handoff: initial screen check", "follow-up: summarize the failing case"]
        ))))
        try await settle()

        #expect(viewModel.sessions.first?.lastRequestText == "summarize the failing case")
        #expect(viewModel.sessions.first?.compactCwdDescription == "~/Documents/picky")

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(sessionId: "session-1", line: "follow-up: include CWD in the HUD"))))
        try await settle()
        #expect(viewModel.sessions.first?.lastRequestText == "include CWD in the HUD")
    }

    @Test func runtimeDetachedRestoredSessionsAreAutoArchived() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: """
        {"id":"snapshot-detached","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionSnapshot","sessions":[{"id":"lost-runtime","title":"Old side agent","status":"blocked","cwd":"/Users/creatrip/Documents/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Runtime not attached after daemon restart; start a new task or resume support is required","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}]}
        """)))
        try await settle()

        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.archivedSessions.map(\.id) == ["lost-runtime"])
        #expect(archiveStore.archivedSessionIDs == ["lost-runtime"])
    }

    @Test func runtimeDetachedFollowUpFailureStaysVisible() async throws {
        let client = FakePickyAgentClient()
        let archiveStore = FakeArchiveStore()
        let viewModel = PickySessionListViewModel(
            client: client,
            notificationCenter: PickyNoopNotificationCenter(),
            archiveStore: archiveStore
        )
        viewModel.start()

        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(
            id: "followup-detached",
            title: "Detached side agent",
            status: "blocked",
            summary: "Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionLog(
            sessionId: "followup-detached",
            line: "follow-up rejected: Runtime session is not attached after daemon restart; this runtime cannot resume saved Pi sessions, so start a new task or open the Pi terminal overlay"
        ))))
        try await settle()

        #expect(viewModel.sessions.map(\.id) == ["followup-detached"])
        #expect(viewModel.sessions.first?.status == .blocked)
        #expect(viewModel.sessions.first?.isRuntimeDetached == true)
        #expect(viewModel.archivedSessions.isEmpty)
        #expect(archiveStore.archivedSessionIDs.isEmpty)
    }

    @Test func textFollowUpTargetsSelectedSessionAndRejectsEmptyInput() async throws {
        let client = FakePickyAgentClient()
        let selection = FakeSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: EventJSON.sessionUpdated(id: "session-follow", status: "completed", updatedAt: "2026-05-01T00:00:05.000Z"))))
        try await settle()

        try await viewModel.followUp(text: "  continue here  ")
        #expect(client.sentCommands.last?.type == .followUp)
        #expect(client.sentCommands.last?.sessionId == "session-follow")
        #expect(client.sentCommands.last?.text == "continue here")
        await #expect(throws: PickySessionListViewModelError.emptyFollowUp) {
            try await viewModel.followUp(text: "   ")
        }
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
        notifyMainOnCompletion: Bool? = nil
    ) -> String {
        let encodedLogs = String(decoding: try! JSONEncoder().encode(logs), as: UTF8.self)
        let encodedNotify = notifyMainOnCompletion.map { ",\"notifyMainOnCompletion\":\($0)" } ?? ""
        return """
        {"id":"event-\(id)-\(status)","protocolVersion":"2026-05-01","timestamp":"\(updatedAt)","type":"sessionUpdated","session":{"id":"\(id)","title":"\(title)","status":"\(status)","cwd":"/Users/creatrip/Documents/picky","createdAt":"\(createdAt)","updatedAt":"\(updatedAt)","lastSummary":"\(summary)","logs":\(encodedLogs),"tools":[],"artifacts":[],"changedFiles":[]\(encodedNotify)}}
        """
    }

    static func extensionUiRequest() -> String {
        """
        {"id":"event-ui","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:02.000Z","type":"extensionUiRequest","request":{"id":"ui-1","sessionId":"session-1","method":"confirm","title":"Confirm","prompt":"Proceed?","options":null,"createdAt":"2026-05-01T00:00:02.000Z"}}
        """
    }

    static func askUserQuestionRequest() -> String {
        """
        {"id":"event-ui-form","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:02.000Z","type":"extensionUiRequest","request":{"id":"ui-form","sessionId":"session-1","method":"askUserQuestion","title":"Confirm memory","description":"Pick what to save","questions":[{"id":"scope","type":"radio","prompt":"Scope?","options":[{"value":"user","label":"User"},{"value":"project","label":"Project"}],"default":"project"},{"id":"items","type":"checkbox","prompt":"Items?","options":[{"value":"rule","label":"Rule"}],"default":["rule"],"allowOther":true},{"id":"note","type":"text","prompt":"Note","required":false}],"createdAt":"2026-05-01T00:00:02.000Z"}}
        """
    }

    static func sessionLog(sessionId: String, line: String) -> String {
        let encodedLine = String(decoding: try! JSONEncoder().encode(line), as: UTF8.self)
        return """
        {"id":"event-log","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:03.000Z","type":"sessionLogAppended","sessionId":"\(sessionId)","line":\(encodedLine)}
        """
    }

    static func tool(sessionId: String, toolCallId: String, name: String, status: String, preview: String) -> String {
        """
        {"id":"event-tool-\(status)","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:03.000Z","type":"toolActivityUpdated","sessionId":"\(sessionId)","tool":{"toolCallId":"\(toolCallId)","name":"\(name)","status":"\(status)","preview":"\(preview)","startedAt":"2026-05-01T00:00:02.000Z","endedAt":null}}
        """
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
