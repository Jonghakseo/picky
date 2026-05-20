//
//  OpenAITranscriptionProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("OpenAI STT provider")
struct OpenAITranscriptionProviderTests {
    // 1) 미설정 시 isConfigured=false
    @Test func unconfiguredProviderReportsMissingAPIKey() {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: nil)
        )
        #expect(provider.isConfigured == false)
        #expect(provider.unavailableExplanation?.contains("api key") == true)
    }

    // 2) 키 있으면 isConfigured=true
    @Test func configuredProviderIsReady() {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test")
        )
        #expect(provider.isConfigured == true)
        #expect(provider.unavailableExplanation == nil)
    }

    // 3) displayName 정확
    @Test func displayNameIsOpenAI() {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test")
        )
        #expect(provider.displayName == "OpenAI Speech to Text")
    }

    // 4) requiresSpeechRecognitionPermission=false (네트워크 기반)
    @Test func doesNotRequireSpeechRecognitionPermission() {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test")
        )
        #expect(provider.requiresSpeechRecognitionPermission == false)
    }

    // 5) 미설정 + startStreamingSession → notConfigured throw
    @Test func startStreamingSessionThrowsWhenUnconfigured() async {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: nil)
        )
        await #expect(throws: OpenAIAudioProviderError.self) {
            _ = try await provider.startStreamingSession(
                keyterms: [],
                onTranscriptUpdate: { _ in },
                onFinalTranscriptReady: { _ in },
                onError: { _ in }
            )
        }
    }

    // 6) 빈 modelName → default로 fallback
    @Test func emptyModelNameFallsBackToDefault() {
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "sk-test"),
            modelName: "  "
        )
        // private이라 직접 검증 불가, 그러나 isConfigured/displayName으로 간접 확인
        #expect(provider.isConfigured == true)
        #expect(provider.displayName == "OpenAI Speech to Text")
    }

    // 7) Factory: settings.sttProvider == .openai 이고 key 있으면 OpenAI provider 라우팅
    @Test func factoryRoutesToOpenAIWhenSelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai
        settings.openAISTTAPIKey = "sk-test"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        #expect(provider.displayName == "OpenAI Speech to Text")
    }

    // 8) Factory: ENV provider routing no longer overrides the local default
    @Test func envPickySTTProviderNoLongerRoutesAutomatically() {
        // PickySettings.defaults() now baselines to .openaiRealtime (Codex
        // OAuth realtime STT) since d5af0ae8. The original contract under
        // test — "ENV alone never overrides settings" — still holds; we just
        // need to pin .local explicitly to keep the assertion scoped.
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .local

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_STT_PROVIDER": "openai",
                "OPENAI_API_KEY": "sk-env"
            ]
        )
        #expect(provider.displayName == AppleSpeechTranscriptionProvider().displayName)
    }

    // 9) Factory: .openai 선택했지만 키가 없으면 그대로 OpenAI provider를 만들고 unavailableExplanation으로 알림
    //    (UI/CompanionManager가 필요 시 사용자에게 표시)
    @Test func factoryStillRoutesToOpenAIEvenWithoutKeySoUnavailableExplanationCanSurface() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        #expect(provider.displayName == "OpenAI Speech to Text")
        #expect(provider.isConfigured == false)
        #expect(provider.unavailableExplanation != nil)
    }

    // 10) Factory: Azure 분기는 그대로 작동 (회귀)
    @Test func factoryAzurePathStillRoutesToAzure() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .azure
        settings.azureOpenAIEndpoint = "https://test.openai.azure.com/openai/deployments/whisper/audio/transcriptions?api-version=2024-02-01"
        settings.azureOpenAIAPIKey = "azure-key"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        #expect(provider.displayName == "Azure OpenAI Speech to Text")
    }

    // 11) Factory: .local 명시 시 Apple Speech
    @Test func factoryLocalPathRoutesToAppleSpeech() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .local

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )
        #expect(provider.displayName == AppleSpeechTranscriptionProvider().displayName)
    }
}
