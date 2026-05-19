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
    /// Optional weak reference Picky sets at boot so the realtime STT provider
    /// can talk back through the same agentd command channel. Holds a weak
    /// reference so the factory itself never extends the lifetime of
    /// `PickyAgentClient`. Reads and writes happen on the main actor in
    /// production (CompanionManager.reloadVoiceProvidersFromSettings), but the
    /// stored property itself is left nonisolated so the existing factory
    /// callers (including tests) can keep their synchronous signatures.
    nonisolated(unsafe) static weak var sharedAgentClient: PickyAgentClient?

    static func makeDefaultProvider(
        settings: PickySettings = PickySettingsStore().load(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRealtimeOnlyBuild: Bool? = nil
    ) -> any BuddyTranscriptionProvider {
        // Resolve the build flag through MainActor.assumeIsolated when the
        // caller did not pass one in explicitly. Production call sites are
        // already MainActor-isolated (CompanionManager, BuddyDictationManager)
        // so the assumption holds; tests pass the value explicitly to avoid
        // tripping the assumption from a nonisolated `@Test` context.
        let isRealtimeOnlyBuild = isRealtimeOnlyBuild
            ?? MainActor.assumeIsolated { AppBundleConfiguration.isRealtimeOnlyBuild }
        // PICKY_REALTIME_OPT_IN=1 builds force the Realtime transcription
        // provider regardless of what is currently saved in settings.sttProvider.
        // The Settings UI on this build no longer exposes an STT picker, but
        // existing user settings files may still carry a legacy provider
        // selection (e.g. "openai" or "azure") inherited from a previous
        // opt-in=0 install. Honouring that value would silently pop a
        // key-input requirement we can no longer satisfy.
        if isRealtimeOnlyBuild {
            let language = settings.openAISTTPreferredLanguage
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let provider = OpenAIRealtimeTranscriptionProvider(
                agentClient: BuddyTranscriptionProviderFactory.sharedAgentClient,
                preferredLanguage: language
            )
            print("🎙️ Transcription: realtime build — forced provider \(provider.displayName), language: \(language ?? "auto")")
            return provider
        }

        let requestedProvider = providerName(from: settings.sttProvider)

        if requestedProvider == "openai-realtime" || requestedProvider == "openaiRealtime" {
            let language = settings.openAISTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let provider = OpenAIRealtimeTranscriptionProvider(
                agentClient: BuddyTranscriptionProviderFactory.sharedAgentClient,
                preferredLanguage: language
            )
            print("🎙️ Transcription: using provider \(provider.displayName), language: \(language ?? "auto")")
            return provider
        }

        if requestedProvider == "openai" {
            let language = settings.openAISTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_STT_LANGUAGE", environment: environment)
            let modelName = settings.openAISTTModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_STT_MODEL", environment: environment)
                ?? OpenAITranscriptionProvider.defaultModelName
            let apiKey = settings.openAISTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_API_KEY", environment: environment)
            let baseURL = OpenAIAudioConfiguration.parseBaseURLOverride(settings.openAISTTBaseURL)
                ?? OpenAIAudioConfiguration.parseBaseURLOverride(
                    AzureOpenAIKeychainStore.value(for: "OPENAI_STT_BASE_URL", environment: environment)
                )
                ?? OpenAIAudioConfiguration.parseBaseURLOverride(
                    AzureOpenAIKeychainStore.value(for: "OPENAI_BASE_URL", environment: environment)
                )
                ?? OpenAIAudioConfiguration.defaultBaseURL
            let provider = OpenAITranscriptionProvider(
                configuration: OpenAIAudioConfiguration(apiKey: apiKey, baseURL: baseURL),
                preferredLanguage: language,
                modelName: modelName
            )
            print("🎙️ Transcription: using provider \(provider.displayName), model: \(modelName), language: \(language ?? "auto")")
            return provider
        }

        if requestedProvider == "elevenlabs" || requestedProvider == "eleven-labs" {
            let language = settings.elevenLabsSTTLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_STT_LANGUAGE", environment: environment)
            let modelID = settings.elevenLabsSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_STT_MODEL", environment: environment)
                ?? ElevenLabsTranscriptionProvider.defaultModelID
            let apiKey = settings.elevenLabsSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (environment.isEmpty ? nil : AzureOpenAIKeychainStore.value(for: "ELEVENLABS_API_KEY", environment: environment))
            let provider = ElevenLabsTranscriptionProvider(
                configuration: ElevenLabsTranscriptionConfiguration(apiKey: apiKey),
                modelID: modelID,
                preferredLanguage: language
            )
            print("🎙️ Transcription: using provider \(provider.displayName), model: \(modelID), language: \(language ?? "auto")")
            return provider
        }

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
        case .local:
            return "local"
        case .openai:
            return "openai"
        case .openaiRealtime:
            return "openai-realtime"
        case .azure:
            return "azure"
        case .elevenLabs:
            return "elevenlabs"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
