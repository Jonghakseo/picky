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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any PickySpeechPlaybackProvider {
        let requestedProvider = (AzureOpenAIKeychainStore.value(for: "PICKY_TTS_PROVIDER", environment: environment)
            ?? AzureOpenAIKeychainStore.value(for: "PICKY_SPEECH_PLAYBACK_PROVIDER", environment: environment))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

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
            print("🔊 TTS: using provider \(provider.displayName)")
            return provider
        }

        let provider = PickySystemSpeechPlaybackProvider()
        print("🔊 TTS: using local provider \(provider.displayName)")
        return provider
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
