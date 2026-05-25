//
//  ElevenLabsSpeechPlaybackProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("ElevenLabs TTS provider")
struct ElevenLabsSpeechPlaybackProviderTests {
    @Test func configurationRequiresAPIKeyAndVoiceID() {
        let configuration = ElevenLabsSpeechConfiguration(apiKey: nil, voiceID: nil)

        #expect(configuration.isConfigured == false)
        #expect(configuration.missingConfigurationExplanation?.contains("API key") == true)
        #expect(configuration.missingConfigurationExplanation?.contains("voice ID") == true)
    }

    @Test func factoryUsesPersistedTTSSettings() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.elevenLabsTTSAPIKey = " el-tts-key "
        settings.elevenLabsTTSVoiceID = " voice-123 "
        settings.elevenLabsTTSModel = " eleven_flash_v2_5 "
        settings.elevenLabsTTSOutputFormat = " pcm_24000 "
        settings.elevenLabsTTSBaseURL = " https://api.elevenlabs.io "

        let configuration = PickySpeechPlaybackProviderFactory.makeElevenLabsTTSConfiguration(
            settings: settings,
            environment: [:]
        )

        #expect(configuration.apiKey == "el-tts-key")
        #expect(configuration.voiceID == "voice-123")
        #expect(configuration.modelID == "eleven_flash_v2_5")
        #expect(configuration.outputFormat == "pcm_24000")
        #expect(configuration.baseURL.absoluteString == "https://api.elevenlabs.io")
    }

    @Test func factoryFallsBackToSTTKeyWhenTTSKeyEmpty() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.elevenLabsTTSAPIKey = ""
        settings.elevenLabsSTTAPIKey = " el-shared-key "
        settings.elevenLabsTTSVoiceID = "voice-123"

        let configuration = PickySpeechPlaybackProviderFactory.makeElevenLabsTTSConfiguration(
            settings: settings,
            environment: [:]
        )

        #expect(configuration.apiKey == "el-shared-key")
        #expect(configuration.voiceID == "voice-123")
    }

    @MainActor
    @Test func factoryRoutesToElevenLabsWhenSelected() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .elevenLabs
        settings.elevenLabsTTSAPIKey = "el-tts-key"
        settings.elevenLabsTTSVoiceID = "voice-123"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [:],
            isRealtimeOnlyBuild: false
        )

        #expect(provider.displayName.contains("ElevenLabs") == true)
        #expect(provider.displayName.contains("fallback") == true)
    }
}
