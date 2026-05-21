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
private final class TTSTestLongRunningSpeechProvider: PickySpeechPlaybackProvider {
    let displayName = "Off"
    private(set) var isSpeaking = false
    private var onFinish: ((Bool) -> Void)?

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        self.onFinish = onFinish
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        onFinish = nil
        isSpeaking = false
    }
}

private struct TTSTestTimeoutError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func waitForTTSCondition(
    timeout: TimeInterval = 5,
    description: @autoclosure () -> String = "TTS test condition",
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw TTSTestTimeoutError(description: "Timed out waiting for \(description()) after \(timeout)s")
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

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(settings: settings, environment: [:], isRealtimeOnlyBuild: false)

        #expect(provider.displayName == "Off")
        #expect(provider.isSpeaking == false)

        var didFinish: Bool?
        let didStart = provider.speak("hello") { finished in
            didFinish = finished
        }

        #expect(didStart == true)
        #expect(didFinish == nil)
        #expect(provider.isSpeaking == true)

        provider.stopSpeaking()
        #expect(provider.isSpeaking == false)
    }

    @MainActor
    @Test func mutedTTSDisplayDurationExceedsCursorMinimumDisplayWindow() {
        #expect(PickyMutedSpeechPlaybackProvider.displayDuration(for: "소리 없이 보여줄 답변입니다.") > PickyInteractionReducer.minimumDisplayDuration)
    }

    @MainActor
    @Test func mutedTTSKeepsCursorReplyVisiblePastMinimumDisplayWindow() async throws {
        // Use a manually controlled provider so the assertion is not affected by
        // wall-clock delays from other highly parallel MainActor-heavy tests.
        // The production muted provider's duration is covered by
        // mutedTTSDisplayDurationExceedsCursorMinimumDisplayWindow().
        let speechProvider = TTSTestLongRunningSpeechProvider()
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
        try await waitForTTSCondition(description: "muted TTS response to enter responding state") {
            manager.voiceState == .responding && speechProvider.isSpeaking
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(manager.voiceState == .responding)
        #expect(speechProvider.isSpeaking == true)
        speechProvider.stopSpeaking()
    }
}
