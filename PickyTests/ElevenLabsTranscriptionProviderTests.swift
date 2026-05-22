//
//  ElevenLabsTranscriptionProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("ElevenLabs STT provider")
struct ElevenLabsTranscriptionProviderTests {
    // 1) 미설정 시 isConfigured=false
    @Test func unconfiguredProviderReportsMissingAPIKey() {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: nil)
        )
        #expect(provider.isConfigured == false)
        #expect(provider.unavailableExplanation?.contains("api key") == true)
    }

    // 2) 키 있으면 isConfigured=true
    @Test func configuredProviderIsReady() {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: "el-key")
        )
        #expect(provider.isConfigured == true)
        #expect(provider.unavailableExplanation == nil)
    }

    // 3) displayName
    @Test func displayNameIsElevenLabs() {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: "el-key")
        )
        #expect(provider.displayName == "ElevenLabs Speech to Text")
    }

    // 4) requiresSpeechRecognitionPermission=false
    @Test func doesNotRequireSpeechRecognitionPermission() {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: "el-key")
        )
        #expect(provider.requiresSpeechRecognitionPermission == false)
    }

    // 5) 미설정 + startStreamingSession → notConfigured throw
    @Test func startStreamingSessionThrowsWhenUnconfigured() async {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: nil)
        )
        await #expect(throws: ElevenLabsTranscriptionProviderError.self) {
            _ = try await provider.startStreamingSession(
                keyterms: [],
                onTranscriptUpdate: { _ in },
                onFinalTranscriptReady: { _ in },
                onError: { _ in }
            )
        }
    }

    // 6) 빈 modelID → default scribe_v2 fallback
    @Test func emptyModelIDFallsBackToDefault() {
        let provider = ElevenLabsTranscriptionProvider(
            configuration: ElevenLabsTranscriptionConfiguration(apiKey: "el-key"),
            modelID: "  "
        )
        #expect(provider.isConfigured == true)
        #expect(provider.displayName == "ElevenLabs Speech to Text")
    }

    // 7) configuration trim
    @Test func configurationTrimsAPIKey() {
        let configuration = ElevenLabsTranscriptionConfiguration(apiKey: "  el-key  ")
        #expect(configuration.apiKey == "el-key")
    }

    // 8) transcriptionURL
    @Test func transcriptionURLIsBaseURLPlusV1Path() {
        let configuration = ElevenLabsTranscriptionConfiguration(apiKey: "el-key")
        #expect(configuration.transcriptionURL().absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    }

    // 9) configuredAPIKey throws when missing
    @Test func configuredAPIKeyThrowsWhenMissing() {
        let configuration = ElevenLabsTranscriptionConfiguration(apiKey: nil)
        #expect(throws: ElevenLabsTranscriptionProviderError.self) {
            _ = try configuration.configuredAPIKey()
        }
    }

    // 10) fromEnvironment override
    @Test func fromEnvironmentPrefersExplicitOverride() {
        let configuration = ElevenLabsTranscriptionConfiguration.fromEnvironment(
            apiKeyOverride: "el-explicit",
            environment: ["ELEVENLABS_API_KEY": "el-env"]
        )
        #expect(configuration.apiKey == "el-explicit")
    }

    // 11) fromEnvironment env fallback
    @Test func fromEnvironmentFallsBackToEnvironmentVariable() {
        let configuration = ElevenLabsTranscriptionConfiguration.fromEnvironment(
            apiKeyOverride: nil,
            environment: ["ELEVENLABS_API_KEY": "el-env"]
        )
        #expect(configuration.apiKey == "el-env")
    }

    // 12) Factory: settings.sttProvider == .elevenLabs 이고 key 있으면 ElevenLabs 라우팅
    @Test func factoryRoutesToElevenLabsWhenSelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .elevenLabs
        settings.elevenLabsSTTAPIKey = "el-key"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )
        #expect(provider.displayName == "ElevenLabs Speech to Text")
    }

    // 13) Factory: ENV provider routing no longer overrides the local default
    @Test func envPickySTTProviderNoLongerRoutesToElevenLabsAutomatically() {
        // The factory must not infer a provider from ENV alone — the user's
        // settings.sttProvider is the source of truth. PickySettings.defaults()
        // baselines to .local (Apple Speech).
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_STT_PROVIDER": "elevenlabs",
                "ELEVENLABS_API_KEY": "el-env"
            ],
            isRealtimeOnlyBuild: false
        )
        #expect(provider.displayName == AppleSpeechTranscriptionProvider().displayName)
    }

    // 14) Factory: 키 없어도 ElevenLabs provider 만들고 unavailableExplanation 노출
    @Test func factoryStillRoutesToElevenLabsEvenWithoutKey() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .elevenLabs

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )
        #expect(provider.displayName == "ElevenLabs Speech to Text")
        #expect(provider.isConfigured == false)
        #expect(provider.unavailableExplanation != nil)
    }

    // 15) Factory: OpenAI/Azure 회귀 보호
    @Test func factoryOpenAIPathStillRoutesToOpenAI() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai
        settings.openAISTTAPIKey = "sk-test"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )
        #expect(provider.displayName == "OpenAI Speech to Text")
    }
}
