//
//  PickyRealtimeOptInProviderGuardTests.swift
//  PickyTests
//
//  Unit tests for the OpenAI Realtime runtime short-circuits inside the
//  Speech and Transcription provider factories. On the realtime runtime:
//    * `BuddyTranscriptionProviderFactory.makeDefaultProvider` must force the
//      Realtime transcription provider regardless of whatever
//      `settings.sttProvider` happens to be on disk (legacy installs may still
//      carry an "openai" or "azure" selection).
//    * `PickySpeechPlaybackProviderFactory.makeDefaultProvider` must never
//      return an external-API TTS provider (OpenAI/Azure/ElevenLabs).
//      Onboarding narration is the only TTS path on the realtime build and it
//      should always fall back to the bundled macOS synthesizer.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyRealtimeOptInProviderGuardTests {
    @Test func realtimeBuild_forcesRealtimeTranscriptionProvider_regardlessOfSettings() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai
        settings.openAISTTAPIKey = "sk-leftover"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: true
        )

        #expect(provider is OpenAIRealtimeTranscriptionProvider)
    }

    @Test func realtimeBuild_forcesRealtimeProvider_evenWhenLegacyAzureWasSelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .azure
        settings.azureOpenAIAPIKey = "azure-leftover"
        settings.azureOpenAIEndpoint = "https://example.openai.azure.com/openai/deployments/x/audio/transcriptions"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: true
        )

        #expect(provider is OpenAIRealtimeTranscriptionProvider)
    }

    @Test func realtimeRuntimeSetting_forcesRealtimeTranscriptionProvider_withoutOverrideParameter() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.mainAgentRuntimeMode = .openAIRealtime
        settings.sttProvider = .azure
        settings.azureOpenAIAPIKey = "azure-leftover"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )

        #expect(provider is OpenAIRealtimeTranscriptionProvider)
    }

    @Test func legacyBuild_stillHonoursStoredSttProvider() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .openai
        settings.openAISTTAPIKey = "sk-test"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )

        #expect(provider is OpenAITranscriptionProvider)
    }

    @Test func realtimeBuild_forcesSystemTtsProvider_evenWhenSettingsAskedForOpenAI() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = true
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-leftover"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: true
        )

        #expect(provider is PickySystemSpeechPlaybackProvider)
    }

    @Test func realtimeBuild_respectsTtsDisabledToggle() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = false
        settings.ttsProvider = .openai

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: true
        )

        #expect(provider is PickyMutedSpeechPlaybackProvider)
    }

    @Test func realtimeRuntimeSetting_forcesSystemTtsProvider_withoutOverrideParameter() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.mainAgentRuntimeMode = .openAIRealtime
        settings.ttsEnabled = true
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-leftover"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:]
        )

        #expect(provider is PickySystemSpeechPlaybackProvider)
    }

    @Test func legacyBuild_stillRoutesToConfiguredTtsProvider() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsEnabled = true
        settings.ttsProvider = .openai
        settings.openAITTSAPIKey = "sk-test"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )

        #expect(provider is PickyFallbackSpeechPlaybackProvider)
    }
}
