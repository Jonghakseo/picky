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
        let requestedProvider = providerName(from: settings.sttProvider)
        let vocabulary = PickyTranscriptionVocabulary(settings: settings)

        if requestedProvider == "groq" {
            let language = settings.groqSTTLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = GroqTranscriptionDefaults.modelName(from: settings)
            let provider = OpenAITranscriptionProvider(
                configuration: makeGroqSTTConfiguration(settings: settings, environment: environment),
                preferredLanguage: language,
                modelName: modelName,
                vocabulary: vocabulary,
                displayName: GroqTranscriptionDefaults.displayName
            )
            print("🎙️ Transcription: using provider \(provider.displayName), model: \(modelName), language: \(language ?? "auto")")
            return provider
        }

        if requestedProvider == "openai" {
            let language = settings.openAISTTPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_STT_LANGUAGE", environment: environment)
            let modelName = settings.openAISTTModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? AzureOpenAIKeychainStore.value(for: "OPENAI_STT_MODEL", environment: environment)
                ?? OpenAITranscriptionProvider.defaultModelName
            let provider = OpenAITranscriptionProvider(
                configuration: makeOpenAISTTConfiguration(settings: settings, environment: environment),
                preferredLanguage: language,
                modelName: modelName,
                vocabulary: vocabulary
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
                preferredLanguage: language,
                vocabulary: vocabulary
            )
            print("🎙️ Transcription: using provider \(provider.displayName), language: \(language ?? "auto")")
            return provider
        }

        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using local provider \(provider.displayName)")
        return provider
    }

    /// Resolves the direct OpenAI STT settings without constructing a provider,
    /// keeping the precedence contract observable without HTTP or audio setup.
    static func makeOpenAISTTConfiguration(
        settings: PickySettings,
        environment: [String: String]
    ) -> OpenAIAudioConfiguration {
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
        return OpenAIAudioConfiguration(apiKey: apiKey, baseURL: baseURL)
    }

    /// Groq exposes Whisper through an OpenAI-compatible API, so it reuses the
    /// OpenAI provider with a fixed base URL and its own key.
    static func makeGroqSTTConfiguration(
        settings: PickySettings,
        environment: [String: String]
    ) -> OpenAIAudioConfiguration {
        let apiKey = settings.groqSTTAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (environment.isEmpty ? nil : AzureOpenAIKeychainStore.value(for: "GROQ_API_KEY", environment: environment))
        return OpenAIAudioConfiguration(apiKey: apiKey, baseURL: GroqTranscriptionDefaults.baseURL)
    }

    private static func providerName(from selection: PickyVoiceProviderSelection) -> String? {
        switch selection {
        case .local:
            return "local"
        case .groq:
            return "groq"
        case .openai:
            return "openai"
        case .azure:
            return "azure"
        case .elevenLabs:
            return "elevenlabs"
        case .edge:
            // Edge is playback-only. A stale/corrupt STT setting safely keeps
            // the established local transcription path.
            return "local"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum GroqTranscriptionDefaults {
    static let baseURL = URL(string: "https://api.groq.com/openai")!
    static let displayName = "Groq Speech to Text"
    /// Highest-accuracy Groq Whisper model; the free tier limits are the same
    /// for both Groq Whisper models, so accuracy is the default.
    static let accurateModelName = "whisper-large-v3"
    static let fastModelName = "whisper-large-v3-turbo"
    static let consoleKeysURL = URL(string: "https://console.groq.com/keys")!

    static func modelName(from settings: PickySettings) -> String {
        settings.groqSTTModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? accurateModelName
    }
}
