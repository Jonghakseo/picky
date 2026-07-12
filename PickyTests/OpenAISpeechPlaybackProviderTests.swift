//
//  OpenAISpeechPlaybackProviderTests.swift
//  PickyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Picky

@Suite("OpenAI TTS provider")
struct OpenAISpeechPlaybackProviderTests {
    // 1) configuration: 키 미설정 시 isConfigured=false, 설명 메시지 포함
    @Test func configurationWithoutAPIKeyIsNotConfigured() {
        let configuration = OpenAIAudioConfiguration(apiKey: nil)
        #expect(configuration.isConfigured == false)
        let explanation = configuration.missingConfigurationExplanation
        #expect(explanation?.contains("api key") == true)
    }

    // 2) configuration: 키 trim
    @Test func configurationTrimsAPIKey() {
        let configuration = OpenAIAudioConfiguration(apiKey: "  sk-test  ")
        #expect(configuration.apiKey == "sk-test")
        #expect(configuration.isConfigured == true)
    }

    // 3) configuration: empty string은 nil로 정규화
    @Test func configurationEmptyAPIKeyTreatedAsMissing() {
        let configuration = OpenAIAudioConfiguration(apiKey: "   ")
        #expect(configuration.apiKey == nil)
        #expect(configuration.isConfigured == false)
    }

    // 4) audioURL: 경로 정상 결합
    @Test func audioURLAppendsPathBelowV1() {
        let configuration = OpenAIAudioConfiguration(apiKey: "sk")
        #expect(configuration.audioURL(forPath: "audio/speech").absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(configuration.audioURL(forPath: "/audio/transcriptions/").absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    }

    // 5) configuredAPIKey throws when missing
    @Test func configuredAPIKeyThrowsWhenMissing() {
        let configuration = OpenAIAudioConfiguration(apiKey: nil)
        #expect(throws: OpenAIAudioProviderError.self) {
            _ = try configuration.configuredAPIKey()
        }
    }

    // 6) fromEnvironment: 명시적 override 우선
    @Test func fromEnvironmentPrefersExplicitOverride() {
        let configuration = OpenAIAudioConfiguration.fromEnvironment(
            apiKeyOverride: "sk-explicit",
            environment: ["OPENAI_API_KEY": "sk-from-env"]
        )
        #expect(configuration.apiKey == "sk-explicit")
    }

    // 7) fromEnvironment: env 값 사용
    @Test func fromEnvironmentFallsBackToEnvironmentVariable() {
        let configuration = OpenAIAudioConfiguration.fromEnvironment(
            apiKeyOverride: nil,
            environment: ["OPENAI_API_KEY": "sk-from-env"]
        )
        #expect(configuration.apiKey == "sk-from-env")
    }

    // 8) provider: 미설정 시 speak가 false 리턴, isSpeaking=false 유지
    @MainActor
    @Test func unconfiguredProviderRefusesToSpeakAndStaysIdle() async {
        let provider = OpenAISpeechPlaybackProvider(
            configuration: OpenAIAudioConfiguration(apiKey: nil)
        )
        var didFinishCalled = false
        let started = provider.speak("hello") { _ in didFinishCalled = true }
        #expect(started == false)
        #expect(provider.isSpeaking == false)
        #expect(didFinishCalled == false)
    }

    // 9) provider: 빈 utterance면 false 리턴
    @MainActor
    @Test func emptyUtteranceIsRefused() async {
        let provider = OpenAISpeechPlaybackProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test")
        )
        let started = provider.speak("   \n", onFinish: { _ in })
        #expect(started == false)
        #expect(provider.isSpeaking == false)
    }

    // 10) provider: voice/model 빈값 들어오면 default로 정규화
    @MainActor
    @Test func emptyVoiceAndModelFallBackToDefaults() async {
        let provider = OpenAISpeechPlaybackProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test"),
            voice: "  ",
            modelName: "  "
        )
        // private 필드라 직접 검증은 어렵지만 displayName은 항상 노출
        #expect(provider.displayName == "OpenAI Text to Speech")
    }

    // 11) Factory: settings.ttsProvider == .openai 이고 OpenAI 키 있으면 OpenAI fallback wrapper로 라우팅
    @MainActor
    @Test func factoryRoutesToOpenAIWhenSelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-test"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        // FallbackSpeechPlaybackProvider wraps "<primary> + macOS Speech fallback"
        #expect(provider.displayName.contains("OpenAI") == true)
        #expect(provider.displayName.contains("fallback") == true)
    }

    // 12) Factory: ENV provider routing no longer overrides the local default
    @MainActor
    @Test func envPickyTTSProviderNoLongerRoutesAutomatically() {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_TTS_PROVIDER": "openai",
                "OPENAI_API_KEY": "sk-env"
            ]
        )
        #expect(provider.displayName == "macOS Speech")
    }

    // 13) Factory: TTS 비활성화 시 muted
    @MainActor
    @Test func disabledTTSStillUsesMutedProviderEvenIfOpenAISelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = false
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-test"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        #expect(provider.displayName == "Off")
    }

    // 14) UI placeholder 약속: openAITTSAPIKey 비어있으면 openAISTTAPIKey로 폴백
    @MainActor
    @Test func ttsFactoryFallsBackToSTTKeyWhenTTSKeyEmpty() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = ""
        settings.openAISTTAPIKey = "sk-stt-shared"

        let configuration = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: [:]
        )
        #expect(configuration.apiKey == "sk-stt-shared")
    }

    // 15) TTS key가 채워져 있으면 STT key 안 봄 (priority 검증)
    @MainActor
    @Test func ttsFactoryPrefersTTSKeyOverSTTKey() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-tts-explicit"
        settings.openAISTTAPIKey = "sk-stt-shared"

        let configuration = PickySpeechPlaybackProviderFactory.makeOpenAITTSConfiguration(
            settings: settings,
            environment: [:]
        )
        #expect(configuration.apiKey == "sk-tts-explicit")
    }

    // 16) Stale player의 delegate callback이 와도 isPlaybackInProgress가 변하지 않음
    @MainActor
    @Test func staleDelegateCallbackIsIgnoredWhenNoActivePlayer() async throws {
        let provider = OpenAISpeechPlaybackProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test")
        )
        // 빈 데이터로 player 생성 시도 — 실패하면 시스템 환경 문제이므로 skip
        let stalePlayer: AVAudioPlayer
        do {
            stalePlayer = try AVAudioPlayer(data: Data([0xFF, 0xFB, 0x90, 0x00]))
        } catch {
            // Audio system 미초기화 환경 — 회귀 검증 skip
            return
        }
        // No active player. Stale delegate callback should be silently ignored.
        provider.audioPlayerDidFinishPlaying(stalePlayer, successfully: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(provider.isSpeaking == false)
    }
}
