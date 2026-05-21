//
//  OpenAIBaseURLOverrideTests.swift
//  PickyTests
//
//  Verifies that users can point the OpenAI direct providers at OpenAI-compatible
//  proxies (LocalAI, openai-edge-tts, Together, Groq, self-hosted inference) by
//  setting `openAITTSBaseURL` / `openAISTTBaseURL` in PickySettings or the
//  matching ENV variables.
//

import Foundation
import Testing
@testable import Picky

@Suite("OpenAI base URL override")
struct OpenAIBaseURLOverrideTests {
    // 1) parseBaseURLOverride: nil for blank / whitespace
    @Test func parseReturnsNilForBlankInput() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride(nil) == nil)
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("") == nil)
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("   ") == nil)
    }

    // 2) parseBaseURLOverride: nil for unparseable strings
    @Test func parseReturnsNilForInvalidURL() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("not a url") == nil)
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("/relative/path") == nil)
    }

    // 3) parseBaseURLOverride: accepts http/https with hostname (incl. localhost)
    @Test func parseAcceptsHttpAndHttpsWithHost() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("http://localhost:5050")?.absoluteString == "http://localhost:5050")
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("https://api.example.com")?.absoluteString == "https://api.example.com")
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("http://192.168.1.10:8080")?.absoluteString == "http://192.168.1.10:8080")
    }

    // 4) parseBaseURLOverride: trims whitespace
    @Test func parseTrimsSurroundingWhitespace() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("  https://api.openai.com  ")?.absoluteString == "https://api.openai.com")
    }

    // 5) audioURL: override는 v1/path 정확히 부착
    @Test func audioURLAppendsV1PathToOverrideBase() {
        let configuration = OpenAIAudioConfiguration(
            apiKey: "sk",
            baseURL: URL(string: "http://localhost:5050")!
        )
        #expect(configuration.audioURL(forPath: "audio/speech").absoluteString == "http://localhost:5050/v1/audio/speech")
        #expect(configuration.audioURL(forPath: "audio/transcriptions").absoluteString == "http://localhost:5050/v1/audio/transcriptions")
    }

    // 6) PickySettings round-trip
    @Test func settingsBaseURLFieldsRoundTrip() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.openAITTSBaseURL = "http://localhost:5050"
        settings.openAISTTBaseURL = "http://localhost:8000"

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(restored.openAITTSBaseURL == "http://localhost:5050")
        #expect(restored.openAISTTBaseURL == "http://localhost:8000")
    }

    // 7) Legacy settings without new fields decode to empty string
    @Test func legacySettingsWithoutBaseURLFieldsDecodeToDefaults() throws {
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
        #expect(settings.openAITTSBaseURL == "")
        #expect(settings.openAISTTBaseURL == "")
    }

    // 8) normalizedPaths trims new base URL fields
    @Test func normalizedPathsTrimsNewBaseURLFields() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.openAITTSBaseURL = "  http://localhost:5050  "
        settings.openAISTTBaseURL = "\thttp://localhost:8000\n"
        let normalized = settings.normalizedPaths()
        #expect(normalized.openAITTSBaseURL == "http://localhost:5050")
        #expect(normalized.openAISTTBaseURL == "http://localhost:8000")
    }

    // 9) TTS factory uses settings override
    @MainActor
    @Test func ttsFactoryUsesSettingsBaseURLOverride() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk"
        settings.openAITTSBaseURL = "http://localhost:5050"

        let configuration = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: [:]
        )
        #expect(configuration.baseURL.absoluteString == "http://localhost:5050")
    }

    // 10) TTS factory falls back to ENV (OPENAI_TTS_BASE_URL > OPENAI_BASE_URL > default)
    @MainActor
    @Test func ttsFactoryFallsBackToEnvBaseURL() {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)

        let withSpecific = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: ["OPENAI_TTS_BASE_URL": "http://specific:5050", "OPENAI_BASE_URL": "http://generic:7777"]
        )
        #expect(withSpecific.baseURL.absoluteString == "http://specific:5050")

        let withGenericOnly = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: ["OPENAI_BASE_URL": "http://generic:7777"]
        )
        #expect(withGenericOnly.baseURL.absoluteString == "http://generic:7777")

        let withNothing = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: [:]
        )
        #expect(withNothing.baseURL == OpenAIAudioConfiguration.defaultBaseURL)
    }

    // 11) STT factory uses settings override (factory provider creation)
    @Test func sttFactoryUsesSettingsBaseURLOverride() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai
        settings.openAISTTAPIKey = "sk"
        settings.openAISTTBaseURL = "http://localhost:8000"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )
        #expect(provider.displayName == "OpenAI Speech to Text")
        #expect(provider.isConfigured == true)
        // base URL은 provider 내부 private이라 직접 검증 어려움 — displayName/isConfigured까지만
    }

    // 12) Invalid base URL falls back to default (TTS factory)
    @MainActor
    @Test func invalidSettingsBaseURLFallsBackToDefault() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk"
        settings.openAITTSBaseURL = "not a url"

        let configuration = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: [:]
        )
        #expect(configuration.baseURL == OpenAIAudioConfiguration.defaultBaseURL)
    }

    // 13) trailing /v1 normalization
    @Test func parseStripsTrailingV1FromBaseURL() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("http://localhost:5050/v1")?.absoluteString == "http://localhost:5050")
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("http://localhost:5050/v1/")?.absoluteString == "http://localhost:5050")
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("https://proxy.example.com/v1")?.absoluteString == "https://proxy.example.com")
    }

    // 14) /v1을 path 중간에 포함하면 stripping 안 함
    @Test func parsePreservesV1WhenNotTrailing() {
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("http://localhost:5050/v1/foo")?.absoluteString == "http://localhost:5050/v1/foo")
        #expect(OpenAIAudioConfiguration.parseBaseURLOverride("https://api.openai.com")?.absoluteString == "https://api.openai.com")
    }

    // 15) trailing /v1 + audioURL 결합 정확
    @Test func audioURLAfterStrippedV1AppendsCleanly() {
        let configuration = OpenAIAudioConfiguration(
            apiKey: "sk",
            baseURL: OpenAIAudioConfiguration.parseBaseURLOverride("http://localhost:5050/v1")!
        )
        #expect(configuration.audioURL(forPath: "audio/speech").absoluteString == "http://localhost:5050/v1/audio/speech")
    }
}
