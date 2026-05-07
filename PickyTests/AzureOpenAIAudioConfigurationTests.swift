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
            ]
        )

        #expect(provider.displayName == "Azure OpenAI Speech to Text")
        #expect(provider.isConfigured)
        #expect(provider.unavailableExplanation == nil)
    }

    @Test func automaticSTTNoLongerUsesEnvironmentToSelectAzure() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.sttProvider = .automatic

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings,
            environment: [
                "PICKY_STT_PROVIDER": "azure",
                "AZURE_OPENAI_ENDPOINT": "https://picky-resource.openai.azure.com",
                "AZURE_OPENAI_API_KEY": "test-key",
                "AZURE_OPENAI_STT_DEPLOYMENT_NAME": "whisper-stt"
            ]
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
    }
}
