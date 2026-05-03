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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any BuddyTranscriptionProvider {
        let requestedProvider = (AzureOpenAIKeychainStore.value(for: "PICKY_STT_PROVIDER", environment: environment)
            ?? AzureOpenAIKeychainStore.value(for: "PICKY_TRANSCRIPTION_PROVIDER", environment: environment))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if requestedProvider == "azure" || requestedProvider == "azure-openai" {
            let provider = AzureOpenAITranscriptionProvider(
                configuration: .fromEnvironment(
                    deploymentEnvironmentKey: "AZURE_OPENAI_STT_DEPLOYMENT_NAME",
                    defaultAPIVersion: AzureOpenAITranscriptionProvider.defaultAPIVersion,
                    environment: environment
                )
            )
            print("🎙️ Transcription: using provider \(provider.displayName)")
            return provider
        }

        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using local provider \(provider.displayName)")
        return provider
    }
}
