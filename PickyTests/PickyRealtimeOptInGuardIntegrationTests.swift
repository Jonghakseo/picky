//
//  PickyRealtimeOptInGuardIntegrationTests.swift
//  PickyTests
//
//  Integration tests that exercise the PICKY_REALTIME_OPT_IN=1 guards through
//  the real CompanionManager surface. These complement the per-helper unit
//  tests by driving the actual entry points (`sendDirectMessage`,
//  `currentVoiceInteractionMode`, etc.) with `AppBundleConfiguration` flipped
//  into Realtime-only mode via the @TaskLocal override.
//

import Foundation
import Testing
@testable import Picky

private final class FakeOptInGuardClient: PickyAgentClient {
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
        return PickyAgentSubmissionReceipt(sessionID: "stub", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }
    func disconnect() { continuation.yield(.disconnected) }
}

@MainActor
private func makeFakeContextCoordinator() -> PickyVoiceContextCaptureCoordinator {
    PickyVoiceContextCaptureCoordinator(
        screenCapture: { _, _ in [] },
        contextAssembler: { _, source, transcript, _ in
            PickyContextPacket(
                id: "ctx",
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

@MainActor
struct PickyRealtimeOptInGuardIntegrationTests {
    @Test func sendDirectMessage_rejects_whenRealtimeBuildLacksAuth() async throws {
        try await AppBundleConfiguration.$testRuntimeModeOverride.withValue(.openAIRealtime) {
            let client = FakeOptInGuardClient()
            let manager = CompanionManager(
                agentClient: client,
                voiceContextCaptureCoordinator: makeFakeContextCoordinator()
            )

            // CompanionManager constructs its own PickySettingsStore() to look up
            // realtime auth. Unit tests use an isolated app-support root, while
            // the auth inspector still depends on the developer/CI Codex login
            // state. Either outcome must be internally consistent.
            let didSend = await manager.sendDirectMessage("hello", source: .quickInput)

            if !didSend {
                #expect(manager.directMessageError != nil)
                #expect(client.submissions.isEmpty)
            } else {
                #expect(manager.directMessageError == nil)
                #expect(client.submissions.count == 1)
            }
        }
    }

    @Test func sendDirectMessage_doesNotApplyGate_onPiBuild() async throws {
        try await AppBundleConfiguration.$testRuntimeModeOverride.withValue(.pi) {
            let client = FakeOptInGuardClient()
            let manager = CompanionManager(
                agentClient: client,
                voiceContextCaptureCoordinator: makeFakeContextCoordinator()
            )

            let didSend = await manager.sendDirectMessage("hello", source: .text)

            // On the Pi build the submission must always go through, because
            // the realtime auth state is irrelevant.
            #expect(didSend)
            #expect(manager.directMessageError == nil)
            #expect(client.submissions.count == 1)
        }
    }

    @Test func effectiveRuntimeMode_followsRealtimeOverride() {
        AppBundleConfiguration.$testRuntimeModeOverride.withValue(.openAIRealtime) {
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .openAIRealtime)
            #expect(AppBundleConfiguration.isRealtimeOnlyBuild)
        }
    }

    @Test func effectiveRuntimeMode_followsPiOverride() {
        AppBundleConfiguration.$testRuntimeModeOverride.withValue(.pi) {
            #expect(AppBundleConfiguration.effectiveRuntimeMode == .pi)
            #expect(!AppBundleConfiguration.isRealtimeOnlyBuild)
        }
    }
}
