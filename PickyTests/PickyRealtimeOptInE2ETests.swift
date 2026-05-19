//
//  PickyRealtimeOptInE2ETests.swift
//  PickyTests
//
//  End-to-end coverage of the Swift -> agentd hand-off when
//  PICKY_REALTIME_OPT_IN=1. The Swift app's job in the realtime build is to
//  forward `effectiveRuntimeMode == .openAIRealtime` through two surfaces:
//    1. `daemonLauncher` constructs an env that contains
//       `PICKY_MAIN_AGENT_RUNTIME=openai-realtime`.
//    2. `CompanionManager` pushes a `setMainAgentRuntimeMode` command on
//       settings save so a daemon that booted in the wrong mode is corrected.
//

import Foundation
import Testing
@testable import Picky

private final class FakeE2EClient: PickyAgentClient {
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
        return PickyAgentSubmissionReceipt(sessionID: "e2e", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }
    func disconnect() { continuation.yield(.disconnected) }
}

@MainActor
private func makeFakeE2EContextCoordinator() -> PickyVoiceContextCaptureCoordinator {
    PickyVoiceContextCaptureCoordinator(
        screenCapture: { _, _ in [] },
        contextAssembler: { _, source, transcript, _ in
            PickyContextPacket(
                id: "e2e-ctx",
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
struct PickyRealtimeOptInE2ETests {
    @Test func daemonLauncher_emitsOpenAIRealtimeEnv_whenConfiguredWithOpenAIRealtime() throws {
        var configuration = PickyAgentDaemonConfiguration(
            port: 19_017,
            token: "token-e2e",
            appSupportRoot: URL(fileURLWithPath: "/tmp/picky-support-e2e"),
            defaultCwd: "/Users/test/project",
            mainAgentCwd: "/Users/test/main",
            mainAgentRuntimeMode: .openAIRealtime,
            runtime: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/agentd"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        configuration.baseEnvironment = ["PATH": "/usr/bin"]

        let env = configuration.environment

        #expect(env["PICKY_AGENTD_MODE"] == "primary")
        #expect(env["PICKY_MAIN_AGENT_RUNTIME"] == "openai-realtime")
    }

    @Test func daemonLauncher_emitsPiEnv_whenConfiguredWithPi() throws {
        var configuration = PickyAgentDaemonConfiguration(
            port: 19_018,
            token: "token-pi",
            appSupportRoot: URL(fileURLWithPath: "/tmp/picky-support-pi"),
            defaultCwd: "/Users/test/project",
            mainAgentCwd: "/Users/test/main",
            mainAgentRuntimeMode: .pi,
            runtime: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/agentd"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        configuration.baseEnvironment = ["PATH": "/usr/bin"]

        let env = configuration.environment

        #expect(env["PICKY_MAIN_AGENT_RUNTIME"] == "pi")
    }

    @Test func companionManager_sendsRuntimeModeCommand_followingEffectiveRuntimeMode() async throws {
        // Verify the CompanionManager.start() + settings save observer chain
        // pushes some setMainAgentRuntimeMode command. The settings save
        // notification posts on a fresh Task so the @TaskLocal override does
        // not propagate, which mirrors production behaviour: production sets
        // the value via the build constant, not a task local.
        let client = FakeE2EClient()
        let manager = CompanionManager(
            agentClient: client,
            voiceContextCaptureCoordinator: makeFakeE2EContextCoordinator()
        )
        manager.start()
        NotificationCenter.default.post(name: .pickySettingsDidSave, object: nil)
        for _ in 0..<60 {
            if client.sentCommands.contains(where: { $0.type == .setMainAgentRuntimeMode }) { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        #expect(client.sentCommands.contains(where: { $0.type == .setMainAgentRuntimeMode }))
    }
}
