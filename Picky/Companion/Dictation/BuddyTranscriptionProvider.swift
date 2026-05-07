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
        _ = environment
        let requestedProvider = providerName(from: settings.sttProvider)

        if requestedProvider == "azure" || requestedProvider == "azure-openai" {
            let language = settings.azureSTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let provider = AzureOpenAITranscriptionProvider(
                configuration: .fromTranscriptionEndpointURL(
                    settings.azureOpenAIEndpoint,
                    apiKey: settings.azureOpenAIAPIKey
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

    private static func providerName(from selection: PickyVoiceProviderSelection) -> String? {
        switch selection {
        case .automatic:
            return nil
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
