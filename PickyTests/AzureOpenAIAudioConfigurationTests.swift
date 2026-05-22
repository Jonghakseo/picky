//
//  AzureOpenAIAudioConfigurationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct AzureOpenAIAudioConfigurationTests {
    @Test func parsesAzurePortalTranscriptionEndpointURL() throws {
        let configuration = AzureOpenAIAudioConfiguration.fromTranscriptionEndpointURL(
            "https://picky-resource.openai.azure.com/openai/deployments/whisper-stt/audio/transcriptions?api-version=2024-02-01",
            apiKey: " test-key "
        )

        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.apiKey == "test-key")
        #expect(configuration.deploymentName == "whisper-stt")
        #expect(configuration.apiVersion == "2024-02-01")
        #expect(configuration.isConfigured)
        #expect(configuration.deploymentURL(forAudioPath: "audio/transcriptions")?.absoluteString == "https://picky-resource.openai.azure.com/openai/deployments/whisper-stt/audio/transcriptions?api-version=2024-02-01")
    }

    @Test func parsesTranscriptionEndpointWithExtraQueryTrailingSlashAndPercentEncodedDeployment() throws {
        let configuration = AzureOpenAIAudioConfiguration.fromTranscriptionEndpointURL(
            "https://picky-resource.openai.azure.com/openai/deployments/whisper%20stt/audio/transcriptions/?ignored=true&api-version=2024-02-01&extra=1",
            apiKey: "test-key"
        )

        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.deploymentName == "whisper stt")
        #expect(configuration.apiVersion == "2024-02-01")
        #expect(configuration.deploymentURL(forAudioPath: "audio/transcriptions")?.absoluteString == "https://picky-resource.openai.azure.com/openai/deployments/whisper%20stt/audio/transcriptions?api-version=2024-02-01")
    }

    @Test func parsesAzurePortalSpeechEndpointURL() throws {
        let configuration = AzureOpenAIAudioConfiguration.fromSpeechEndpointURL(
            "https://picky-resource.openai.azure.com/openai/deployments/tts-voice/audio/speech?api-version=2025-04-01-preview",
            apiKey: " test-key ",
            defaultAPIVersion: "fallback-version"
        )

        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.apiKey == "test-key")
        #expect(configuration.deploymentName == "tts-voice")
        #expect(configuration.apiVersion == "2025-04-01-preview")
        #expect(configuration.isConfigured)
        #expect(configuration.deploymentURL(forAudioPath: "audio/speech")?.absoluteString == "https://picky-resource.openai.azure.com/openai/deployments/tts-voice/audio/speech?api-version=2025-04-01-preview")
    }

    @Test func baseEndpointOnlyIsNotConfiguredBecauseDeploymentAndAPIVersionAreMissing() throws {
        let configuration = AzureOpenAIAudioConfiguration.fromTranscriptionEndpointURL(
            "https://picky-resource.openai.azure.com",
            apiKey: "test-key"
        )

        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.deploymentName == nil)
        #expect(configuration.apiVersion.isEmpty)
        #expect(!configuration.isConfigured)
        #expect(configuration.missingConfigurationExplanation?.contains("deployment name") == true)
        #expect(configuration.missingConfigurationExplanation?.contains("api version") == true)
    }

    @Test func missingAPIVersionKeepsConfigurationUnavailable() throws {
        let configuration = AzureOpenAIAudioConfiguration.fromTranscriptionEndpointURL(
            "https://picky-resource.openai.azure.com/openai/deployments/whisper-stt/audio/transcriptions",
            apiKey: "test-key"
        )

        #expect(!configuration.isConfigured)
        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.deploymentName == "whisper-stt")
        #expect(configuration.apiVersion.isEmpty)
    }

    @Test func azureSTTFactoryUsesSettingsEndpointAndAPIKey() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .azure
        settings.azureOpenAIEndpoint = "https://picky-resource.openai.azure.com/openai/deployments/whisper-stt/audio/transcriptions?api-version=2024-02-01"
        settings.azureOpenAIAPIKey = "test-key"
        settings.azureSTTPreferredLanguage = "ko"

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_STT_PROVIDER": "local",
                "AZURE_OPENAI_API_KEY": "ignored-key"
            ],
            isRealtimeOnlyBuild: false
        )

        #expect(provider.displayName == "Azure OpenAI Speech to Text")
        #expect(provider.isConfigured)
        #expect(provider.unavailableExplanation == nil)
    }

    @Test func azureTTSVoiceUsesSettingsBeforeEnvironmentAndDefault() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.azureOpenAITTSVoice = " shimmer "

        #expect(PickySpeechPlaybackProviderFactory.azureOpenAITTSVoice(
            settings: settings,
            environment: ["AZURE_OPENAI_TTS_VOICE": "nova"]
        ) == "shimmer")

        settings.azureOpenAITTSVoice = ""
        #expect(PickySpeechPlaybackProviderFactory.azureOpenAITTSVoice(
            settings: settings,
            environment: ["AZURE_OPENAI_TTS_VOICE": " alloy "]
        ) == "alloy")
    }

    @Test func azureTTSConfigurationUsesDedicatedSettingsEndpointAndFallsBackToSTTAPIKey() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .azure
        settings.azureOpenAIEndpoint = "https://picky-resource.openai.azure.com/openai/deployments/whisper-stt/audio/transcriptions?api-version=2024-02-01"
        settings.azureOpenAIAPIKey = "shared-key"
        settings.azureOpenAITTSEndpoint = "https://picky-resource.openai.azure.com/openai/deployments/tts-voice/audio/speech?api-version=2025-04-01-preview"

        let configuration = PickySpeechPlaybackProviderFactory.makeAzureOpenAITTSConfiguration(
            settings: settings,
            environment: [
                "AZURE_OPENAI_API_KEY": "ignored-env-key",
                "AZURE_OPENAI_TTS_DEPLOYMENT_NAME": "ignored-env-deployment"
            ]
        )

        #expect(configuration.endpoint == URL(string: "https://picky-resource.openai.azure.com"))
        #expect(configuration.apiKey == "shared-key")
        #expect(configuration.deploymentName == "tts-voice")
        #expect(configuration.apiVersion == "2025-04-01-preview")
        #expect(configuration.deploymentURL(forAudioPath: "audio/speech")?.absoluteString == "https://picky-resource.openai.azure.com/openai/deployments/tts-voice/audio/speech?api-version=2025-04-01-preview")
    }

    @Test func localSTTDoesNotUseEnvironmentToSelectAzure() throws {
        // The test name pins the contract: even with Azure ENV vars set, the
        // default .local sttProvider must NOT be overridden by environment
        // sniffing.
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_STT_PROVIDER": "azure",
                "AZURE_OPENAI_ENDPOINT": "https://picky-resource.openai.azure.com",
                "AZURE_OPENAI_API_KEY": "test-key",
                "AZURE_OPENAI_STT_DEPLOYMENT_NAME": "whisper-stt"
            ],
            isRealtimeOnlyBuild: false
        )

        #expect(provider.displayName == "Apple Speech")
        #expect(provider.isConfigured)
    }

    @Test func legacySettingsDefaultAzureSTTFieldsToEmptyStrings() throws {
        let legacyJSON = """
        {
          "defaultCwd": "/tmp",
          "worktreeParent": "",
          "preferredToolVisibility": "visible in context only",
          "readOnlyInvestigationPreference": true,
          "daemonPath": "/tmp/agentd",
          "logPath": "/tmp/logs"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.azureOpenAIEndpoint == "")
        #expect(settings.azureOpenAIAPIKey == "")
        #expect(settings.azureOpenAITTSEndpoint == "")
        #expect(settings.azureOpenAITTSAPIKey == "")
        #expect(settings.azureOpenAITTSVoice == "")
    }
}
