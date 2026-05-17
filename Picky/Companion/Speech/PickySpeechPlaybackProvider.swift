//
//  PickySpeechPlaybackProvider.swift
//  Picky
//
//  Shared abstraction for spoken response playback. The default implementation
//  keeps the existing local macOS speech path, while remote providers can plug
//  in later without changing CompanionManager's voice-state orchestration.
//

import AVFoundation
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
        guard settings.ttsEnabled else {
            let provider = PickyMutedSpeechPlaybackProvider()
            print("🔇 TTS: spoken replies disabled")
            return provider
        }

        let requestedProvider = providerName(from: settings.ttsProvider)

        if requestedProvider == "openai" {
            let provider = OpenAISpeechPlaybackProvider(
                configuration: makeOpenAITTSConfiguration(settings: settings, environment: environment),
                voice: openAITTSVoice(settings: settings, environment: environment),
                responseFormat: AzureOpenAIKeychainStore.value(for: "OPENAI_TTS_RESPONSE_FORMAT", environment: environment) ?? "wav",
                instructions: AzureOpenAIKeychainStore.value(for: "OPENAI_TTS_INSTRUCTIONS", environment: environment),
                modelName: openAITTSModel(settings: settings, environment: environment)
            )
            let fallback = PickyFallbackSpeechPlaybackProvider(
                primary: provider,
                fallback: PickySystemSpeechPlaybackProvider()
            )
            print("🔊 TTS: using provider \(fallback.displayName)")
            return fallback
        }

        if requestedProvider == "azure" || requestedProvider == "azure-openai" {
            let provider = AzureOpenAISpeechPlaybackProvider(
                configuration: makeAzureOpenAITTSConfiguration(settings: settings, environment: environment),
                voice: azureOpenAITTSVoice(settings: settings, environment: environment),
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

    static func makeAzureOpenAITTSConfiguration(
        settings: PickySettings,
        environment: [String: String]
    ) -> AzureOpenAIAudioConfiguration {
        let configuredTTSEndpoint = trimmedNonEmpty(settings.azureOpenAITTSEndpoint)
        let configuredTTSAPIKey = trimmedNonEmpty(settings.azureOpenAITTSAPIKey)
        let fallbackAPIKey = configuredTTSAPIKey
            ?? trimmedNonEmpty(settings.azureOpenAIAPIKey)
            ?? AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_API_KEY", environment: environment)
        let fallbackDeploymentName = AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_DEPLOYMENT_NAME", environment: environment)
            ?? AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_DEPLOYMENT_NAME", environment: environment)

        if configuredTTSEndpoint != nil || configuredTTSAPIKey != nil {
            return .fromSpeechEndpointURL(
                configuredTTSEndpoint,
                apiKey: fallbackAPIKey,
                fallbackDeploymentName: fallbackDeploymentName,
                defaultAPIVersion: AzureOpenAISpeechPlaybackProvider.defaultAPIVersion
            )
        }

        return .fromEnvironment(
            deploymentEnvironmentKey: "AZURE_OPENAI_TTS_DEPLOYMENT_NAME",
            defaultAPIVersion: AzureOpenAISpeechPlaybackProvider.defaultAPIVersion,
            environment: environment
        )
    }

    static func azureOpenAITTSVoice(
        settings: PickySettings,
        environment: [String: String]
    ) -> String {
        trimmedNonEmpty(settings.azureOpenAITTSVoice)
            ?? AzureOpenAIKeychainStore.value(for: "AZURE_OPENAI_TTS_VOICE", environment: environment)
            ?? AzureOpenAIKeychainStore.value(for: "PICKY_TTS_VOICE", environment: environment)
            ?? "nova"
    }

    static func makeOpenAITTSConfiguration(
        settings: PickySettings,
        environment: [String: String]
    ) -> OpenAIAudioConfiguration {
        let apiKey = trimmedNonEmpty(settings.openAITTSAPIKey)
            ?? trimmedNonEmpty(settings.openAISTTAPIKey)
            ?? AzureOpenAIKeychainStore.value(for: "OPENAI_API_KEY", environment: environment)
        let baseURL = OpenAIAudioConfiguration.parseBaseURLOverride(settings.openAITTSBaseURL)
            ?? OpenAIAudioConfiguration.parseBaseURLOverride(
                AzureOpenAIKeychainStore.value(for: "OPENAI_TTS_BASE_URL", environment: environment)
            )
            ?? OpenAIAudioConfiguration.parseBaseURLOverride(
                AzureOpenAIKeychainStore.value(for: "OPENAI_BASE_URL", environment: environment)
            )
            ?? OpenAIAudioConfiguration.defaultBaseURL
        return OpenAIAudioConfiguration(apiKey: apiKey, baseURL: baseURL)
    }

    static func openAITTSVoice(
        settings: PickySettings,
        environment: [String: String]
    ) -> String {
        trimmedNonEmpty(settings.openAITTSVoice)
            ?? AzureOpenAIKeychainStore.value(for: "OPENAI_TTS_VOICE", environment: environment)
            ?? OpenAISpeechPlaybackProvider.defaultVoice
    }

    static func openAITTSModel(
        settings: PickySettings,
        environment: [String: String]
    ) -> String {
        trimmedNonEmpty(settings.openAITTSModel)
            ?? AzureOpenAIKeychainStore.value(for: "OPENAI_TTS_MODEL", environment: environment)
            ?? OpenAISpeechPlaybackProvider.defaultModelName
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func providerName(from selection: PickyVoiceProviderSelection) -> String? {
        switch selection {
        case .local:
            return "local"
        case .openai:
            return "openai"
        case .azure:
            return "azure"
        case .elevenLabs:
            return "elevenlabs"
        }
    }
}

@MainActor
final class PickyMutedSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    static let minimumDisplayDuration: TimeInterval = 2.5
    static let maximumDisplayDuration: TimeInterval = 6.0
    private static let charactersPerSecond: Double = 10.0

    let displayName = "Off"
    private(set) var isSpeaking = false

    private var finishTask: Task<Void, Never>?

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()
        isSpeaking = true

        let displayDuration = Self.displayDuration(for: utterance)
        finishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isSpeaking else { return }
                self.isSpeaking = false
                self.finishTask = nil
                onFinish(true)
            }
        }
        return true
    }

    func stopSpeaking() {
        finishTask?.cancel()
        finishTask = nil
        isSpeaking = false
    }

    static func displayDuration(for utterance: String) -> TimeInterval {
        let visibleCharacterCount = utterance.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard visibleCharacterCount > 0 else { return minimumDisplayDuration }
        let estimated = Double(visibleCharacterCount) / charactersPerSecond
        return min(max(estimated, minimumDisplayDuration), maximumDisplayDuration)
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

@MainActor
protocol PickyAVSpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }
    var verifiesStartSynchronously: Bool { get }

    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: PickyAVSpeechSynthesizing {
    var verifiesStartSynchronously: Bool { false }
}

enum PickyAVSpeechSynthesizerDelegateEvent {
    case didStart
    case willSpeak
    case didFinish
    case didCancel
}

private final class PickyAVSpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onEvent: @MainActor (PickyAVSpeechSynthesizerDelegateEvent, AVSpeechUtterance) -> Void

    init(onEvent: @escaping @MainActor (PickyAVSpeechSynthesizerDelegateEvent, AVSpeechUtterance) -> Void) {
        self.onEvent = onEvent
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delegate didStart synthesizerSpeaking=\(synthesizer.isSpeaking)")
        dispatch(.didStart, utterance: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delegate willSpeak range=\(characterRange) synthesizerSpeaking=\(synthesizer.isSpeaking)")
        dispatch(.willSpeak, utterance: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delegate didFinish synthesizerSpeaking=\(synthesizer.isSpeaking)")
        dispatch(.didFinish, utterance: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delegate didCancel synthesizerSpeaking=\(synthesizer.isSpeaking)")
        dispatch(.didCancel, utterance: utterance)
    }

    private func dispatch(_ event: PickyAVSpeechSynthesizerDelegateEvent, utterance: AVSpeechUtterance) {
        Task { @MainActor [onEvent] in
            onEvent(event, utterance)
        }
    }
}

enum PickySpeechPlaybackPreparation {
    /// Short pre-roll for macOS system speech. AVSpeech uses
    /// `preUtteranceDelay` to guard against output device wake-up clipping;
    /// this replaces the old NSSpeech `[[slnc 500]]` prefix.
    static let prerollSilenceMilliseconds = 500

    static func prepareForPlayback(_ utterance: String) -> String {
        "[[slnc \(prerollSilenceMilliseconds)]]\(utterance)"
    }
}

@MainActor
final class PickySystemSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "macOS Speech"

    private(set) var isSpeaking = false

    private let speechSynthesizer: any PickyAVSpeechSynthesizing
    private var speechSynthesizerDelegate: PickyAVSpeechSynthesizerDelegate?
    private var activeSpeechID: UUID?
    private var activeUtterance: AVSpeechUtterance?
    private var activeSpeechDidStart = false
    private var startVerificationTask: Task<Void, Never>?
    private var onFinish: ((Bool) -> Void)?

    init(speechSynthesizer: any PickyAVSpeechSynthesizing = AVSpeechSynthesizer()) {
        self.speechSynthesizer = speechSynthesizer
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider speak requested chars=\(utterance.count) trimmedChars=\(trimmedUtterance.count) existingSpeaking=\(isSpeaking) engineSpeaking=\(speechSynthesizer.isSpeaking)")
        stopSpeaking()
        guard !trimmedUtterance.isEmpty else {
            PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider refused empty utterance")
            return false
        }

        let speechID = UUID()
        let spokenUtterance = AVSpeechUtterance(string: trimmedUtterance)
        spokenUtterance.preUtteranceDelay = Double(PickySpeechPlaybackPreparation.prerollSilenceMilliseconds) / 1000.0

        let delegate = PickyAVSpeechSynthesizerDelegate { [weak self] event, delegateUtterance in
            self?.handleSynthesizerDelegateEvent(event, utterance: delegateUtterance)
        }
        speechSynthesizer.delegate = delegate
        speechSynthesizerDelegate = delegate
        activeSpeechID = speechID
        activeUtterance = spokenUtterance
        activeSpeechDidStart = false
        self.onFinish = onFinish
        isSpeaking = true

        speechSynthesizer.speak(spokenUtterance)
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider start requested speechID=\(speechID) chars=\(trimmedUtterance.count) preDelayMs=\(PickySpeechPlaybackPreparation.prerollSilenceMilliseconds) speakingAfterStart=\(isSpeaking) engineSpeakingAfterStart=\(speechSynthesizer.isSpeaking)")

        guard !speechSynthesizer.verifiesStartSynchronously || speechSynthesizer.isSpeaking else {
            PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider start verification failed speechID=\(speechID) engineSpeakingAfterStart=false")
            clearActiveSpeech()
            return false
        }

        scheduleStartVerification(speechID: speechID)
        return true
    }

    func stopSpeaking() {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider stop requested active=\(activeSpeechID?.uuidString ?? "none") speakingBefore=\(isSpeaking) engineSpeakingBefore=\(speechSynthesizer.isSpeaking) hasDelegate=\(speechSynthesizerDelegate != nil)")
        speechSynthesizer.delegate = nil
        let stopped = speechSynthesizer.stopSpeaking(at: .immediate)
        clearActiveSpeech()
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider stop completed stopped=\(stopped) speakingAfter=\(isSpeaking) engineSpeakingAfter=\(speechSynthesizer.isSpeaking)")
    }

    func handleSynthesizerDelegateEvent(_ event: PickyAVSpeechSynthesizerDelegateEvent, utterance: AVSpeechUtterance) {
        guard let activeSpeechID,
              let activeUtterance,
              activeUtterance === utterance else {
            PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider ignored stale delegate event=\(event) active=\(activeSpeechID?.uuidString ?? "none")")
            return
        }

        switch event {
        case .didStart, .willSpeak:
            PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider accepted delegate event=\(event) speechID=\(activeSpeechID)")
            activeSpeechDidStart = true
            isSpeaking = true
        case .didFinish:
            finishActiveSpeech(speechID: activeSpeechID, didFinish: true)
        case .didCancel:
            finishActiveSpeech(speechID: activeSpeechID, didFinish: false)
        }
    }

    private func finishActiveSpeech(speechID: UUID, didFinish: Bool) {
        guard activeSpeechID == speechID else { return }
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider finish closure didFinish=\(didFinish) speechID=\(speechID) currentSpeaking=\(isSpeaking) engineSpeaking=\(speechSynthesizer.isSpeaking)")
        let finish = onFinish
        clearActiveSpeech()
        finish?(didFinish)
    }

    private func scheduleStartVerification(speechID: UUID) {
        startVerificationTask?.cancel()
        startVerificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.activeSpeechID == speechID,
                      !self.activeSpeechDidStart,
                      !self.speechSynthesizer.isSpeaking else { return }
                PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delayed start verification failed speechID=\(speechID)")
                self.finishActiveSpeech(speechID: speechID, didFinish: false)
            }
        }
    }

    private func clearActiveSpeech() {
        startVerificationTask?.cancel()
        startVerificationTask = nil
        isSpeaking = false
        speechSynthesizer.delegate = nil
        speechSynthesizerDelegate = nil
        activeSpeechID = nil
        activeUtterance = nil
        activeSpeechDidStart = false
        onFinish = nil
    }
}
