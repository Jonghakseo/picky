//
//  PickySessionViewModelTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakePickyAgentClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submitted: [PickyAgentSubmission] = []

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
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() { continuation.yield(.disconnected) }
    func emit(_ event: PickyClientEvent) { continuation.yield(event) }
}

@MainActor
struct PickySessionViewModelTests {
    @Test func fakeClientEventsUpdateStreamingSessionState() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client)
        viewModel.start()

        client.emit(.protocolEvent(PickyEventEnvelope.fixture(event: .sessionUpdated(PickyAgentSession.fixture()))))
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(viewModel.sessions.first?.title == "Investigate current screen")
        #expect(viewModel.sessions.first?.status == .running)
        #expect(viewModel.sessions.first?.lastSummary == "Started")

        client.emit(.protocolEvent(PickyEventEnvelope.fixture(event: .sessionLogAppended(sessionId: "session-1", line: "Reading files"))))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(viewModel.sessions.first?.logPreview == "Reading files")
    }

    @Test func initialTranscriptSubmitsCreateTaskThroughClient() async throws {
        let client = FakePickyAgentClient()
        let viewModel = PickySessionListViewModel(client: client)
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

private extension PickyEventEnvelope {
    static func fixture(event: PickyEvent) -> PickyEventEnvelope {
        let json: String
        switch event {
        case .sessionUpdated:
            json = """
            {"id":"event-1","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"session-1","title":"Investigate current screen","status":"running","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"Started","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
            """
        case .sessionLogAppended:
            json = """
            {"id":"event-2","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:01.000Z","type":"sessionLogAppended","sessionId":"session-1","line":"Reading files"}
            """
        default:
            json = """
            {"id":"event-3","protocolVersion":"2026-05-01","timestamp":"2026-05-01T00:00:02.000Z","type":"hello","serverName":"picky-agentd","supportedProtocolVersions":["2026-05-01"]}
            """
        }
        return try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(json.utf8))
    }
}

private extension PickyAgentSession {
    static func fixture() -> PickyAgentSession {
        PickyAgentSession(
            id: "session-1",
            title: "Investigate current screen",
            status: .running,
            cwd: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSummary: "Started",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: [],
            pendingExtensionUiRequest: nil
        )
    }
}
