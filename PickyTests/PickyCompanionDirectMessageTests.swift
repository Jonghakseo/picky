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

    func send(_ command: PickyCommandEnvelope) async throws {}
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
        #expect(client.submissions.first?.context.source == "typed-message")
        #expect(client.submissions.first?.context.transcript == "hello from messages")

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "typed-context", text: "typed reply")))

        #expect(manager.latestAgentSessionSummary == "typed reply")
        #expect(manager.voiceState != .responding)
        #expect(speechProvider.spokenUtterances.isEmpty)
    }

    private func fakeDirectMessageContextCaptureCoordinator() -> PickyVoiceContextCaptureCoordinator {
        PickyVoiceContextCaptureCoordinator(
            screenCapture: { [] },
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
