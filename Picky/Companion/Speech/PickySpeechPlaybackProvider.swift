//
//  PickySpeechPlaybackProvider.swift
//  Picky
//
//  Shared abstraction for spoken response playback. The default implementation
//  keeps the existing local macOS speech path, while remote providers can plug
//  in later without changing CompanionManager's voice-state orchestration.
//

import AppKit
import Foundation

@MainActor
protocol PickySpeechPlaybackProvider: AnyObject {
    var displayName: String { get }
    var isSpeaking: Bool { get }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool
    func stopSpeaking()
}

enum PickySpeechPlaybackProviderFactory {
    @MainActor
    static func makeDefaultProvider(
        settings: PickySettings = PickySettingsStore().load(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any PickySpeechPlaybackProvider {
        let requestedProvider = providerName(from: settings.ttsProvider, environment: environment)

        if requestedProvider == "azure" || requestedProvider == "azure-openai" {
            let provider = AzureOpenAISpeechPlaybackProvider(
                configuration: .fromEnvironment(
                    deploymentEnvironmentKey: "AZURE_OPENAI_TTS_DEPLOYMENT_NAME",
                    defaultAPIVersion: AzureOpenAISpeechPlaybackProvider.defaultAPIVersion,
                    environment: environment
                ),
                voice: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_VOICE", environment: environment)
                    ?? AzureOpenAIKeychainStore.value(for: "PICKY_TTS_VOICE", environment: environment)
                    ?? "nova",
                responseFormat: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_RESPONSE_FORMAT", environment: environment) ?? "wav",
                instructions: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_INSTRUCTIONS", environment: environment),
                modelName: AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_MODEL", environment: environment)
            )
            let fallback = PickyFallbackSpeechPlaybackProvider(
                primary: provider,
                fallback: PickySystemSpeechPlaybackProvider()
            )
            print("🔊 TTS: using provider \(fallback.displayName)")
            return fallback
        }

        if requestedProvider == "elevenlabs" || requestedProvider == "eleven-labs" {
            let provider = ElevenLabsSpeechPlaybackProvider(
                configuration: .fromEnvironment(environment: environment)
            )
            let fallback = PickyFallbackSpeechPlaybackProvider(
                primary: provider,
                fallback: PickySystemSpeechPlaybackProvider()
            )
            print("🔊 TTS: using provider \(fallback.displayName)")
            return fallback
        }

        let provider = PickySystemSpeechPlaybackProvider()
        print("🔊 TTS: using local provider \(provider.displayName)")
        return provider
    }

    private static func providerName(
        from selection: PickyVoiceProviderSelection,
        environment: [String: String]
    ) -> String? {
        switch selection {
        case .automatic:
            return (AzureOpenAIKeychainStore.value(for: "PICKY_TTS_PROVIDER", environment: environment)
                ?? AzureOpenAIKeychainStore.value(for: "PICKY_SPEECH_PLAYBACK_PROVIDER", environment: environment))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        case .local:
            return "local"
        case .azure:
            return "azure"
        case .elevenLabs:
            return "elevenlabs"
        }
    }
}

@MainActor
final class PickyFallbackSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName: String

    var isSpeaking: Bool {
        // Report only real provider playback/request activity. `activeSpeechID`
        // is an internal callback guard; treating it as speaking means the
        // manager's polling safety net can never recover when a provider drops
        // its finish callback after playback has already stopped, leaving the
        // cursor response bubble stuck in `.responding`.
        primary.isSpeaking || fallback.isSpeaking
    }

    private let primary: any PickySpeechPlaybackProvider
    private let fallback: any PickySpeechPlaybackProvider
    private var activeSpeechID: UUID?

    init(primary: any PickySpeechPlaybackProvider, fallback: any PickySpeechPlaybackProvider) {
        self.primary = primary
        self.fallback = fallback
        self.displayName = "\(primary.displayName) + \(fallback.displayName) fallback"
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()

        let speechID = UUID()
        activeSpeechID = speechID

        let startedPrimary = primary.speak(utterance) { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.handlePrimaryFinished(
                    speechID: speechID,
                    utterance: utterance,
                    didFinish: didFinish,
                    onFinish: onFinish
                )
            }
        }

        guard startedPrimary else {
            return startFallback(speechID: speechID, utterance: utterance, onFinish: onFinish)
        }
        return true
    }

    func stopSpeaking() {
        activeSpeechID = nil
        primary.stopSpeaking()
        fallback.stopSpeaking()
    }

    private func handlePrimaryFinished(
        speechID: UUID,
        utterance: String,
        didFinish: Bool,
        onFinish: @escaping (Bool) -> Void
    ) {
        guard activeSpeechID == speechID else { return }
        guard !didFinish else {
            activeSpeechID = nil
            onFinish(true)
            return
        }

        print("🔊 TTS primary failed — falling back to \(fallback.displayName)")
        _ = startFallback(speechID: speechID, utterance: utterance, onFinish: onFinish)
    }

    @discardableResult
    private func startFallback(
        speechID: UUID,
        utterance: String,
        onFinish: @escaping (Bool) -> Void
    ) -> Bool {
        guard activeSpeechID == speechID else { return false }
        primary.stopSpeaking()

        let startedFallback = fallback.speak(utterance) { [weak self] didFinish in
            Task { @MainActor [weak self] in
                guard self?.activeSpeechID == speechID else { return }
                self?.activeSpeechID = nil
                onFinish(didFinish)
            }
        }

        guard startedFallback else {
            activeSpeechID = nil
            onFinish(false)
            return false
        }
        return true
    }
}

private final class PickySpeechSynthesizerDelegate: NSObject, NSSpeechSynthesizerDelegate {
    private let onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        onFinish(finishedSpeaking)
    }
}

enum PickySpeechPlaybackPreparation {
    /// Short pre-roll for macOS system speech. Some output devices need a tiny
    /// amount of generated audio time before the first audible phoneme; without
    /// it, the start of short TTS replies can be clipped.
    static let prerollSilenceMilliseconds = 500

    static func prepareForPlayback(_ utterance: String) -> String {
        "[[slnc \(prerollSilenceMilliseconds)]]\(utterance)"
    }
}

@MainActor
final class PickySystemSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "macOS Speech"

    var isSpeaking: Bool {
        speechSynthesizer?.isSpeaking ?? false
    }

    private var speechSynthesizer: NSSpeechSynthesizer?
    private var speechSynthesizerDelegate: PickySpeechSynthesizerDelegate?

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()

        let delegate = PickySpeechSynthesizerDelegate { [weak self] didFinish in
            self?.speechSynthesizer?.delegate = nil
            self?.speechSynthesizerDelegate = nil
            onFinish(didFinish)
        }

        let synthesizer = reusableSpeechSynthesizer()
        synthesizer.delegate = delegate
        speechSynthesizerDelegate = delegate

        let preparedUtterance = PickySpeechPlaybackPreparation.prepareForPlayback(utterance)
        guard synthesizer.startSpeaking(preparedUtterance) else {
            synthesizer.delegate = nil
            speechSynthesizerDelegate = nil
            return false
        }

        return true
    }

    func stopSpeaking() {
        speechSynthesizer?.delegate = nil
        speechSynthesizer?.stopSpeaking()
        speechSynthesizerDelegate = nil
    }

    private func reusableSpeechSynthesizer() -> NSSpeechSynthesizer {
        if let speechSynthesizer {
            return speechSynthesizer
        }

        let synthesizer = NSSpeechSynthesizer()
        speechSynthesizer = synthesizer
        return synthesizer
    }
}
