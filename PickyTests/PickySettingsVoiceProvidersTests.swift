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
        #expect(PickyVoiceProviderSelection.allCases == [.local, .openai, .openaiRealtime, .azure, .elevenLabs])
    }

    @Test func transcriptionCapabilityListsAllProviders() {
        // openaiRealtime is STT-only: it streams through agentd's Codex OAuth
        // bearer to the Realtime transcription session. The speech-playback
        // picker intentionally does NOT include it because the same OAuth
        // does not yet have a tested TTS path.
        let cases = PickyVoiceProviderSelection.cases(for: .transcription)
        #expect(cases == [.local, .openai, .openaiRealtime, .azure, .elevenLabs])
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

    @Test func newOpenAIAndElevenLabsFieldsDefaultToEmpty() {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        #expect(settings.openAITTSAPIKey == "")
        #expect(settings.openAITTSVoice == "")
        #expect(settings.openAITTSModel == "")
        #expect(settings.openAISTTAPIKey == "")
        #expect(settings.openAISTTModel == "")
        #expect(settings.openAISTTPreferredLanguage == "")
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
        settings.elevenLabsSTTAPIKey = "el-key"
        settings.elevenLabsSTTModel = "scribe_v1"
        settings.elevenLabsSTTLanguage = "en"
        settings.sttProvider = .openai
        settings.ttsProvider = .openai

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(PickySettings.self, from: data)

        #expect(restored.openAITTSAPIKey == "sk-tts-key")
        #expect(restored.openAITTSVoice == "alloy")
        #expect(restored.openAITTSModel == "gpt-4o-mini-tts")
        #expect(restored.openAISTTAPIKey == "sk-stt-key")
        #expect(restored.openAISTTModel == "gpt-4o-transcribe")
        #expect(restored.openAISTTPreferredLanguage == "ko")
        #expect(restored.elevenLabsSTTAPIKey == "el-key")
        #expect(restored.elevenLabsSTTModel == "scribe_v1")
        #expect(restored.elevenLabsSTTLanguage == "en")
        #expect(restored.sttProvider == .openai)
        #expect(restored.ttsProvider == .openai)
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
        #expect(normalized.elevenLabsSTTAPIKey == "el-key")
        #expect(normalized.elevenLabsSTTModel == "scribe_v1")
        #expect(normalized.elevenLabsSTTLanguage == "en")
    }
}
