//
//  PickySettingsVoiceProvidersTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickySettings voice provider extensions")
struct PickySettingsVoiceProvidersTests {
    @Test func voiceProviderEnumIncludesAllSelectableCases() {
        #expect(PickyVoiceProviderSelection.allCases == [.local, .openai, .azure, .elevenLabs])
    }

    @Test func transcriptionCapabilityListsAllProviders() {
        let cases = PickyVoiceProviderSelection.cases(for: .transcription)
        #expect(cases == [.local, .openai, .azure, .elevenLabs])
    }

    @Test func speechPlaybackCapabilityListsAllProviders() {
        let cases = PickyVoiceProviderSelection.cases(for: .speechPlayback)
        #expect(cases == [.local, .openai, .azure, .elevenLabs])
    }

    @Test func openAIDisplayNamesAreOpenAI() {
        #expect(PickyVoiceProviderSelection.openai.displayName == "OpenAI")
        #expect(PickyVoiceProviderSelection.openai.displayName(for: .transcription) == "OpenAI")
        #expect(PickyVoiceProviderSelection.openai.displayName(for: .speechPlayback) == "OpenAI")
    }

    @Test func freshInstallDefaultsToAppleSpeechTranscription() {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        #expect(settings.sttProvider == .local)
    }

    @Test func newOpenAIAndElevenLabsFieldsDefaultToEmpty() {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        #expect(settings.openAITTSAPIKey == "")
        #expect(settings.openAITTSVoice == "")
        #expect(settings.openAITTSModel == "")
        #expect(settings.openAISTTAPIKey == "")
        #expect(settings.openAISTTModel == "")
        #expect(settings.openAISTTPreferredLanguage == "")
        #expect(settings.elevenLabsTTSAPIKey == "")
        #expect(settings.elevenLabsTTSVoiceID == "")
        #expect(settings.elevenLabsTTSModel == "")
        #expect(settings.elevenLabsTTSOutputFormat == "")
        #expect(settings.elevenLabsTTSBaseURL == "")
        #expect(settings.elevenLabsSTTAPIKey == "")
        #expect(settings.elevenLabsSTTModel == "")
        #expect(settings.elevenLabsSTTLanguage == "")
    }

    @Test func openAIAndElevenLabsFieldsRoundTripThroughJSON() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.openAITTSAPIKey = "sk-tts-key"
        settings.openAITTSVoice = "alloy"
        settings.openAITTSModel = "gpt-4o-mini-tts"
        settings.openAISTTAPIKey = "sk-stt-key"
        settings.openAISTTModel = "gpt-4o-transcribe"
        settings.openAISTTPreferredLanguage = "ko"
        settings.elevenLabsTTSAPIKey = "el-tts-key"
        settings.elevenLabsTTSVoiceID = "voice-123"
        settings.elevenLabsTTSModel = "eleven_multilingual_v2"
        settings.elevenLabsTTSOutputFormat = "pcm_24000"
        settings.elevenLabsTTSBaseURL = "https://api.elevenlabs.io"
        settings.elevenLabsSTTAPIKey = "el-key"
        settings.elevenLabsSTTModel = "scribe_v1"
        settings.elevenLabsSTTLanguage = "en"
        settings.sttProvider = .openai
        settings.ttsProvider = .elevenLabs

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(restored.openAITTSAPIKey == "sk-tts-key")
        #expect(restored.openAITTSVoice == "alloy")
        #expect(restored.openAITTSModel == "gpt-4o-mini-tts")
        #expect(restored.openAISTTAPIKey == "sk-stt-key")
        #expect(restored.openAISTTModel == "gpt-4o-transcribe")
        #expect(restored.openAISTTPreferredLanguage == "ko")
        #expect(restored.elevenLabsTTSAPIKey == "el-tts-key")
        #expect(restored.elevenLabsTTSVoiceID == "voice-123")
        #expect(restored.elevenLabsTTSModel == "eleven_multilingual_v2")
        #expect(restored.elevenLabsTTSOutputFormat == "pcm_24000")
        #expect(restored.elevenLabsTTSBaseURL == "https://api.elevenlabs.io")
        #expect(restored.elevenLabsSTTAPIKey == "el-key")
        #expect(restored.elevenLabsSTTModel == "scribe_v1")
        #expect(restored.elevenLabsSTTLanguage == "en")
        #expect(restored.sttProvider == .openai)
        #expect(restored.ttsProvider == .elevenLabs)
    }

    @Test func legacySettingsWithAutomaticProviderMigratesToLocal() throws {
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

        #expect(settings.openAITTSAPIKey == "")
        #expect(settings.openAITTSVoice == "")
        #expect(settings.openAITTSModel == "")
        #expect(settings.openAISTTAPIKey == "")
        #expect(settings.openAISTTModel == "")
        #expect(settings.openAISTTPreferredLanguage == "")
        #expect(settings.elevenLabsTTSAPIKey == "")
        #expect(settings.elevenLabsTTSVoiceID == "")
        #expect(settings.elevenLabsTTSModel == "")
        #expect(settings.elevenLabsTTSOutputFormat == "")
        #expect(settings.elevenLabsTTSBaseURL == "")
        #expect(settings.elevenLabsSTTAPIKey == "")
        #expect(settings.elevenLabsSTTModel == "")
        #expect(settings.elevenLabsSTTLanguage == "")
        #expect(settings.sttProvider == .local)
        #expect(settings.ttsProvider == .local)
    }

    @Test func normalizedPathsTrimsNewVoiceFields() {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.openAITTSAPIKey = "  sk-key  "
        settings.openAITTSVoice = " alloy \n"
        settings.openAITTSModel = "\t gpt-4o-mini-tts "
        settings.openAISTTAPIKey = "  sk-stt  "
        settings.openAISTTModel = " gpt-4o-transcribe "
        settings.openAISTTPreferredLanguage = "  ko  "
        settings.elevenLabsTTSAPIKey = " el-tts "
        settings.elevenLabsTTSVoiceID = " voice-123 "
        settings.elevenLabsTTSModel = " eleven_multilingual_v2 "
        settings.elevenLabsTTSOutputFormat = " mp3_44100_128 "
        settings.elevenLabsTTSBaseURL = " https://api.elevenlabs.io "
        settings.elevenLabsSTTAPIKey = " el-key "
        settings.elevenLabsSTTModel = " scribe_v1 "
        settings.elevenLabsSTTLanguage = " en "

        let normalized = settings.normalizedPaths()

        #expect(normalized.openAITTSAPIKey == "sk-key")
        #expect(normalized.openAITTSVoice == "alloy")
        #expect(normalized.openAITTSModel == "gpt-4o-mini-tts")
        #expect(normalized.openAISTTAPIKey == "sk-stt")
        #expect(normalized.openAISTTModel == "gpt-4o-transcribe")
        #expect(normalized.openAISTTPreferredLanguage == "ko")
        #expect(normalized.elevenLabsTTSAPIKey == "el-tts")
        #expect(normalized.elevenLabsTTSVoiceID == "voice-123")
        #expect(normalized.elevenLabsTTSModel == "eleven_multilingual_v2")
        #expect(normalized.elevenLabsTTSOutputFormat == "mp3_44100_128")
        #expect(normalized.elevenLabsTTSBaseURL == "https://api.elevenlabs.io")
        #expect(normalized.elevenLabsSTTAPIKey == "el-key")
        #expect(normalized.elevenLabsSTTModel == "scribe_v1")
        #expect(normalized.elevenLabsSTTLanguage == "en")
    }
}
