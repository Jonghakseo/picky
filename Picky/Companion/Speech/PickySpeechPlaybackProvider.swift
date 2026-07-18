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
    /// Whether this provider can synthesize sentence-sized utterances quickly enough
    /// to start a streamed assistant response before its final reply arrives.
    var supportsIncrementalPlayback: Bool { get }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool
    func stopSpeaking()
}

extension PickySpeechPlaybackProvider {
    var supportsIncrementalPlayback: Bool { false }
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
                configuration: makeElevenLabsTTSConfiguration(settings: settings, environment: environment)
            )
            let fallback = PickyFallbackSpeechPlaybackProvider(
                primary: provider,
                fallback: PickySystemSpeechPlaybackProvider()
            )
            print("🔊 TTS: using provider \(fallback.displayName)")
            return fallback
        }

        if requestedProvider == "edge" {
            let provider = EdgeTTSSpeechPlaybackProvider(voice: settings.edgeTTSVoice)
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

    static func makeElevenLabsTTSConfiguration(
        settings: PickySettings,
        environment: [String: String]
    ) -> ElevenLabsSpeechConfiguration {
        let baseURLString = trimmedNonEmpty(settings.elevenLabsTTSBaseURL)
            ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_BASE_URL", environment: environment)
        let baseURL = baseURLString.flatMap(URL.init(string:)) ?? URL(string: "https://api.elevenlabs.io")!

        return ElevenLabsSpeechConfiguration(
            apiKey: trimmedNonEmpty(settings.elevenLabsTTSAPIKey)
                ?? trimmedNonEmpty(settings.elevenLabsSTTAPIKey)
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_API_KEY", environment: environment),
            voiceID: trimmedNonEmpty(settings.elevenLabsTTSVoiceID)
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_VOICE_ID", environment: environment),
            modelID: trimmedNonEmpty(settings.elevenLabsTTSModel)
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_MODEL_ID", environment: environment)
                ?? ElevenLabsSpeechConfiguration.defaultModelID,
            outputFormat: trimmedNonEmpty(settings.elevenLabsTTSOutputFormat)
                ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_OUTPUT_FORMAT", environment: environment)
                ?? "mp3_44100_128",
            baseURL: baseURL
        )
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
        case .edge:
            return "edge"
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

    // Internal (not private) so factory routing tests can assert the wiring.
    let primary: any PickySpeechPlaybackProvider
    let fallback: any PickySpeechPlaybackProvider
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
protocol PickyNSSpeechSynthesizing: AnyObject {
    var delegate: NSSpeechSynthesizerDelegate? { get set }
    var isSpeaking: Bool { get }

    @discardableResult
    func startSpeaking(_ string: String) -> Bool
    func stopSpeaking()
}

extension NSSpeechSynthesizer: PickyNSSpeechSynthesizing {}

@MainActor
private final class PickySilentNSSpeechSynthesizer: PickyNSSpeechSynthesizing {
    var delegate: NSSpeechSynthesizerDelegate?
    private(set) var isSpeaking = false

    @discardableResult
    func startSpeaking(_ string: String) -> Bool {
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        isSpeaking = false
    }
}

private final class PickyNSSpeechSynthesizerDelegate: NSObject, NSSpeechSynthesizerDelegate {
    private let onFinish: @MainActor (Bool) -> Void

    init(onFinish: @escaping @MainActor (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider delegate didFinish finished=\(finishedSpeaking) synthesizerSpeaking=\(sender.isSpeaking)")
        Task { @MainActor [onFinish] in
            onFinish(finishedSpeaking)
        }
    }
}

enum PickySpeechPlaybackPreparation {
    /// Short pre-roll for macOS system speech. Keep the pause outside the text
    /// stream: embedded commands such as `[[slnc N]]` create speech markers,
    /// and those markers can trigger invalid-range errors in Apple's TTS stack.
    static let prerollSilenceMilliseconds = 500
    static let prerollSilenceSeconds = TimeInterval(prerollSilenceMilliseconds) / 1_000

    static func prepareForPlayback(_ utterance: String) -> String {
        utterance
    }
}

@MainActor
final class PickySystemSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "macOS Speech"
    let supportsIncrementalPlayback = true

    private(set) var isSpeaking = false

    private let speechSynthesizer: any PickyNSSpeechSynthesizing
    private let prerollDelay: TimeInterval
    private let suppressAudioOutput: Bool
    private let suppressedPlaybackDuration: TimeInterval
    private var speechSynthesizerDelegate: PickyNSSpeechSynthesizerDelegate?
    private var activeSpeechID: UUID?
    private var onFinish: ((Bool) -> Void)?
    private var prerollTask: Task<Void, Never>?

    init(
        speechSynthesizer: (any PickyNSSpeechSynthesizing)? = nil,
        prerollDelay: TimeInterval = PickySpeechPlaybackPreparation.prerollSilenceSeconds,
        suppressAudioOutput: Bool? = nil,
        suppressedPlaybackDuration: TimeInterval = 0.01
    ) {
        let isRunningUnitTests = PickyRuntimeEnvironment.isRunningUnitTests
        let resolvedSpeechSynthesizer: any PickyNSSpeechSynthesizing = speechSynthesizer
            ?? (isRunningUnitTests ? PickySilentNSSpeechSynthesizer() : NSSpeechSynthesizer())

        self.speechSynthesizer = resolvedSpeechSynthesizer
        self.prerollDelay = max(0, prerollDelay)
        self.suppressAudioOutput = suppressAudioOutput
            ?? (isRunningUnitTests && (speechSynthesizer == nil || resolvedSpeechSynthesizer is NSSpeechSynthesizer))
        self.suppressedPlaybackDuration = max(0, suppressedPlaybackDuration)
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
        let preparedUtterance = PickySpeechPlaybackPreparation.prepareForPlayback(trimmedUtterance)

        let delegate = PickyNSSpeechSynthesizerDelegate { [weak self] didFinish in
            self?.handleDelegateFinish(speechID: speechID, didFinish: didFinish)
        }
        speechSynthesizer.delegate = delegate
        speechSynthesizerDelegate = delegate
        activeSpeechID = speechID
        self.onFinish = onFinish
        isSpeaking = true

        guard prerollDelay > 0 else {
            return startPreparedSpeech(speechID: speechID, utterance: preparedUtterance, originalCharacterCount: trimmedUtterance.count)
        }

        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider preroll scheduled speechID=\(speechID) delayMs=\(Int(prerollDelay * 1000)) chars=\(trimmedUtterance.count)")
        prerollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(prerollDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.activeSpeechID == speechID else { return }
                self.prerollTask = nil
                _ = self.startPreparedSpeech(speechID: speechID, utterance: preparedUtterance, originalCharacterCount: trimmedUtterance.count)
            }
        }
        return true
    }

    @discardableResult
    private func startPreparedSpeech(speechID: UUID, utterance: String, originalCharacterCount: Int) -> Bool {
        if suppressAudioOutput {
            PickyLog.notice(.speech, prefix: "🔇 Picky speech —", message: "system provider suppressed audio during unit tests speechID=\(speechID) chars=\(originalCharacterCount)")
            let duration = suppressedPlaybackDuration
            prerollTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.activeSpeechID == speechID else { return }
                    self.prerollTask = nil
                    self.handleDelegateFinish(speechID: speechID, didFinish: true)
                }
            }
            return true
        }

        let started = speechSynthesizer.startSpeaking(utterance)
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider start result=\(started) speechID=\(speechID) chars=\(originalCharacterCount) preparedChars=\(utterance.count) speakingAfterStart=\(speechSynthesizer.isSpeaking)")

        guard started else {
            let finish = onFinish
            clearActiveSpeech()
            finish?(false)
            return false
        }
        return true
    }

    func stopSpeaking() {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider stop requested active=\(activeSpeechID?.uuidString ?? "none") speakingBefore=\(isSpeaking) engineSpeakingBefore=\(speechSynthesizer.isSpeaking) hasDelegate=\(speechSynthesizerDelegate != nil)")
        prerollTask?.cancel()
        prerollTask = nil
        speechSynthesizer.delegate = nil
        speechSynthesizer.stopSpeaking()
        clearActiveSpeech()
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider stop completed speakingAfter=\(isSpeaking) engineSpeakingAfter=\(speechSynthesizer.isSpeaking)")
    }

    func handleDelegateFinish(speechID: UUID, didFinish: Bool) {
        guard activeSpeechID == speechID else {
            PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider ignored stale delegate finish=\(didFinish) staleSpeechID=\(speechID) active=\(activeSpeechID?.uuidString ?? "none")")
            return
        }
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: "system provider finish closure didFinish=\(didFinish) speechID=\(speechID) currentSpeaking=\(isSpeaking) engineSpeaking=\(speechSynthesizer.isSpeaking)")
        let finish = onFinish
        clearActiveSpeech()
        finish?(didFinish)
    }

    private func clearActiveSpeech() {
        isSpeaking = false
        prerollTask?.cancel()
        prerollTask = nil
        speechSynthesizer.delegate = nil
        speechSynthesizerDelegate = nil
        activeSpeechID = nil
        onFinish = nil
    }
}
