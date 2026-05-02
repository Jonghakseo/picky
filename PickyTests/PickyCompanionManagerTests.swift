//
//  PickyCompanionManagerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeVoiceClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submissions: [PickyAgentSubmission] = []
    private(set) var commands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        submissions.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "created-session", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws { commands.append(command) }
    func disconnect() { continuation.yield(.disconnected) }
}

private final class FakeVoiceSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
}

@MainActor
struct PickyCompanionManagerTests {
    @Test func voiceTranscriptCreatesTaskWhenNoSessionIsSelected() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice")

        let receipt = try await manager.routeVoiceTranscript(transcript: "new task", contextPacket: context)

        #expect(receipt.sessionID == "created-session")
        #expect(client.submissions.first?.context.source == "voice")
        #expect(client.commands.isEmpty)
    }

    @Test func voiceTranscriptFollowsUpSelectedSession() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.selectedSessionID = "session-selected"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "continue", contextPacket: context)

        #expect(receipt.sessionID == "session-selected")
        #expect(client.commands.first?.type == .followUp)
        #expect(client.commands.first?.sessionId == "session-selected")
        #expect(client.commands.first?.text == "continue")
        #expect(client.commands.first?.context?.source == "voice-follow-up")
        #expect(receipt.message.isEmpty)
        #expect(client.submissions.isEmpty)
    }

    @Test func emptyVoiceFollowUpReceiptClearsProcessingState() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "session-selected", message: ""),
            source: "voice-follow-up"
        )

        #expect(manager.voiceState == .idle)
        #expect(manager.latestAgentSessionSummary == "후속 입력을 선택한 세션에 전달했어요.")
    }

    @Test func emptyNewVoiceTaskReceiptKeepsWaitingForAgentEvents() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: ""),
            source: "voice"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.latestAgentSessionSummary == "응답 준비 중…")
    }

    private func context(source: String) -> PickyContextPacket {
        PickyContextPacket(
            id: "context-voice",
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "continue",
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }
}
