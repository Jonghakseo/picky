//
//  BuddyTranscriptionProvider.swift
//  Picky
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider(
        settings: PickySettings = PickySettingsStore().load(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any BuddyTranscriptionProvider {
        let requestedProvider = providerName(from: settings.sttProvider, environment: environment)

        if requestedProvider == "azure" || requestedProvider == "azure-openai" {
            let language = settings.azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_STT_LANGUAGE", environment: environment)
                ?? AzureOpenAIKeychainStore.value(for: "PICKY_STT_LANGUAGE", environment: environment)
            let provider = AzureOpenAITranscriptionProvider(
                configuration: .fromEnvironment(
                    deploymentEnvironmentKey: "AZURE_OPENAI_STT_DEPLOYMENT_NAME",
                    defaultAPIVersion: AzureOpenAITranscriptionProvider.defaultAPIVersion,
                    environment: environment
                ),
                preferredLanguage: language
            )
            print("🎙️ Transcription: using provider \(provider.displayName), language: \(language ?? "auto")")
            return provider
        }

        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using local provider \(provider.displayName)")
        return provider
    }

    private static func providerName(
        from selection: PickyVoiceProviderSelection,
        environment: [String: String]
    ) -> String? {
        switch selection {
        case .automatic:
            return (AzureOpenAIKeychainStore.value(for: "PICKY_STT_PROVIDER", environment: environment)
                ?? AzureOpenAIKeychainStore.value(for: "PICKY_TRANSCRIPTION_PROVIDER", environment: environment))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        case .local:
            return "local"
        case .azure:
            return "azure"
        case .elevenLabs:
            return "local"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
