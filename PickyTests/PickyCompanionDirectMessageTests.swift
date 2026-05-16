//
//  PickyCompanionDirectMessageTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeDirectMessageClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submissions: [PickyAgentSubmission] = []
    private(set) var sentCommands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        submissions.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "typed-session", message: "")
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }
    func disconnect() { continuation.yield(.disconnected) }
}

@MainActor
private final class FakeDirectMessageSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "Fake Speech"
    private(set) var spokenUtterances: [String] = []
    var isSpeaking = false

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        spokenUtterances.append(utterance)
        return true
    }

    func stopSpeaking() {}
}

@MainActor
struct PickyCompanionDirectMessageTests {
    @Test func resetMainAgentSessionClearsMessagesAndSendsResetCommand() async throws {
        let client = FakeDirectMessageClient()
        let manager = CompanionManager(
            agentClient: client,
            voiceContextCaptureCoordinator: fakeDirectMessageContextCaptureCoordinator()
        )
        manager.applyAgentEvent(.mainMessageAppended(PickyMainAgentMessage(role: .user, text: "old prompt", createdAt: Date(timeIntervalSince1970: 1_800_000_000))))
        manager.applyAgentEvent(.mainMessageAppended(PickyMainAgentMessage(role: .assistant, text: "old reply", createdAt: Date(timeIntervalSince1970: 1_800_000_001))))

        let didReset = await manager.resetMainAgentSession()

        #expect(didReset)
        #expect(client.sentCommands.map(\.type) == [.resetMainAgent])
        #expect(manager.mainAgentMessages.isEmpty)
        #expect(manager.latestAgentSessionSummary == "Started a new Messages session")
    }

    @Test func directMessageRoutesTypedContextAndDoesNotSpeakQuickReply() async throws {
        let client = FakeDirectMessageClient()
        let speechProvider = FakeDirectMessageSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: client,
            speechPlaybackProvider: speechProvider,
            voiceContextCaptureCoordinator: fakeDirectMessageContextCaptureCoordinator()
        )

        let didSend = await manager.sendDirectMessage("  hello from messages  ")

        #expect(didSend)
        #expect(client.submissions.count == 1)
        #expect(client.submissions.first?.transcript == "hello from messages")
        #expect(client.submissions.first?.context.source == "text")
        #expect(client.submissions.first?.context.transcript == "hello from messages")

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "typed-context", text: "typed reply")))
        try await waitUntil { manager.latestAgentSessionSummary == "typed reply" }

        #expect(manager.latestAgentSessionSummary == "typed reply")
        #expect(manager.voiceState != .responding)
        #expect(speechProvider.spokenUtterances.isEmpty)
    }

    @Test func quickInputMessageShowsCursorLoadingAndSpeaksQuickReply() async throws {
        let client = FakeDirectMessageClient()
        let speechProvider = FakeDirectMessageSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: client,
            speechPlaybackProvider: speechProvider,
            voiceContextCaptureCoordinator: fakeDirectMessageContextCaptureCoordinator()
        )

        let didSend = await manager.sendDirectMessage("  hello from cursor  ", source: .quickInput)

        #expect(didSend)
        #expect(client.submissions.count == 1)
        #expect(client.submissions.first?.transcript == "hello from cursor")
        #expect(manager.voiceState == .processing)
        #expect(manager.overlayVisibilityReasons.contains(.waitingForVoiceResponse))

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "typed-context", text: "cursor reply")))
        try await waitUntil { speechProvider.spokenUtterances == ["cursor reply"] }

        #expect(manager.latestAgentSessionSummary == "cursor reply")
        #expect(manager.voiceState == .responding)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }

    private func fakeDirectMessageContextCaptureCoordinator() -> PickyVoiceContextCaptureCoordinator {
        PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            contextAssembler: { _, source, transcript, _ in
                PickyContextPacket(
                    id: "typed-context",
                    source: source,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    transcript: transcript,
                    selectedText: nil,
                    cwd: "/tmp/project",
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    screenshots: [],
                    warnings: []
                )
            }
        )
    }
}
