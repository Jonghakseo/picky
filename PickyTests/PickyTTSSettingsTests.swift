//
//  PickyTTSSettingsTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class TTSTestVoiceClient: PickyAgentClient, @unchecked Sendable {
    let events = AsyncStream<PickyClientEvent> { _ in }

    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "tts-test-session", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() {}
}

private final class TTSTestVoiceSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
}

@MainActor
private func waitForTTSCondition(
    timeout: TimeInterval = 1,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("Timed out waiting for TTS test condition")
}

@Suite("Picky TTS settings")
struct PickyTTSSettingsTests {
    @Test func legacySettingsDefaultTTSEnabledToTrue() throws {
        let legacyJSON = """
        {
            "defaultCwd": "/tmp",
            "worktreeParent": "",
            "preferredToolVisibility": "visible in context only",
            "readOnlyInvestigationPreference": true,
            "daemonPath": "/tmp/agentd",
            "logPath": "/tmp/logs",
            "sttProvider": "automatic",
            "ttsProvider": "automatic"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.ttsEnabled == true)
    }

    @Test func ttsEnabledRoundTripsThroughJSON() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = false

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(restored.ttsEnabled == false)
    }

    @MainActor
    @Test func disabledTTSUsesMutedSpeechProvider() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = false
        settings.ttsProvider = .azure

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(settings: settings, environment: [:])

        #expect(provider.displayName == "Off")
        #expect(provider.isSpeaking == false)

        var didFinish: Bool?
        let didStart = provider.speak("hello") { finished in
            didFinish = finished
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(didStart == true)
        #expect(didFinish == nil)
        #expect(provider.isSpeaking == true)

        provider.stopSpeaking()
        #expect(provider.isSpeaking == false)
    }

    @MainActor
    @Test func mutedTTSKeepsCursorReplyVisiblePastMinimumDisplayWindow() async throws {
        let speechProvider = PickyMutedSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: TTSTestVoiceClient(),
            selectionStore: TTSTestVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "muted-tts-context",
            text: "소리 없이 보여줄 답변입니다.",
            originSource: .voice,
            replyKind: .main
        )))
        try await waitForTTSCondition { manager.voiceState == .responding }

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(manager.voiceState == .responding)
        #expect(speechProvider.isSpeaking == true)
        speechProvider.stopSpeaking()
    }
}
