//
//  ElevenLabsSpeechPlaybackProvider.swift
//  Picky
//
//  ElevenLabs text-to-speech provider. It is selected only when the
//  TTS provider factory is configured with PICKY_TTS_PROVIDER=elevenlabs.
//

import AVFoundation
import Foundation

struct ElevenLabsSpeechConfiguration: Equatable {
    static let defaultModelID = "eleven_multilingual_v2"
    private static let legacyPickyDefaultModelIDs: Set<String> = ["eleven_turbo_v2"]

    var apiKey: String?
    var voiceID: String?
    var modelID: String
    var outputFormat: String
    var baseURL: URL
    var requestTimeout: TimeInterval

    init(
        apiKey: String?,
        voiceID: String?,
        modelID: String = ElevenLabsSpeechConfiguration.defaultModelID,
        outputFormat: String = "mp3_44100_128",
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.voiceID = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modelID = Self.normalizedModelID(modelID)
        self.outputFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "mp3_44100_128"
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    private static func normalizedModelID(_ rawModelID: String) -> String {
        guard let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return defaultModelID
        }

        if legacyPickyDefaultModelIDs.contains(modelID.lowercased()) {
            return defaultModelID
        }

        return modelID
    }

    var isConfigured: Bool {
        apiKey != nil && voiceID != nil
    }

    var missingConfigurationExplanation: String? {
        guard !isConfigured else { return nil }

        var missing = [String]()
        if apiKey == nil { missing.append("API key") }
        if voiceID == nil { missing.append("voice ID") }
        return "ElevenLabs TTS provider is missing: \(missing.joined(separator: ", "))."
    }

    static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ElevenLabsSpeechConfiguration {
        let baseURLString = AzureOpenAIKeychainStore.value(for: "ELEVENLABS_BASE_URL", environment: environment)
        let baseURL = baseURLString.flatMap(URL.init(string:)) ?? URL(string: "https://api.elevenlabs.io")!

        return ElevenLabsSpeechConfiguration(
            apiKey: AzureOpenAIKeychainStore.value(for: "ELEVENLABS_API_KEY", environment: environment),
            voiceID: AzureOpenAIKeychainStore.value(for: "ELEVENLABS_VOICE_ID", environment: environment),
            modelID: AzureOpenAIKeychainStore.value(for: "ELEVENLABS_MODEL_ID", environment: environment) ?? defaultModelID,
            outputFormat: AzureOpenAIKeychainStore.value(for: "ELEVENLABS_OUTPUT_FORMAT", environment: environment) ?? "mp3_44100_128",
            baseURL: baseURL
        )
    }

    func speechURL() -> URL? {
        guard let voiceID else { return nil }

        let base = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("text-to-speech")
            .appendingPathComponent(voiceID)

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "output_format", value: outputFormat)
        ]
        return components.url
    }

    func configuredAPIKey() throws -> String {
        guard let apiKey else {
            throw ElevenLabsSpeechProviderError.notConfigured(missingConfigurationExplanation ?? "ElevenLabs API key is missing.")
        }
        return apiKey
    }
}

enum ElevenLabsSpeechProviderError: LocalizedError {
    case notConfigured(String)
    case invalidEndpoint
    case emptyResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .invalidEndpoint:
            return "Invalid ElevenLabs text-to-speech endpoint."
        case .emptyResponse:
            return "ElevenLabs returned an empty audio response."
        case .httpError(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "ElevenLabs request failed with HTTP \(statusCode)."
            }
            return "ElevenLabs request failed with HTTP \(statusCode): \(trimmedBody)"
        }
    }
}

@MainActor
final class ElevenLabsSpeechPlaybackProvider: NSObject, PickySpeechPlaybackProvider {
    let displayName = "ElevenLabs Text to Speech"

    var isSpeaking: Bool {
        isPlaybackInProgress
    }

    private let configuration: ElevenLabsSpeechConfiguration
    private let urlSession: URLSession

    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var onFinish: ((Bool) -> Void)?
    private var isPlaybackInProgress = false

    init(
        configuration: ElevenLabsSpeechConfiguration = .fromEnvironment(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        super.init()
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()

        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUtterance.isEmpty else { return false }
        guard configuration.isConfigured else {
            print("🔊 ElevenLabs TTS not configured: \(configuration.missingConfigurationExplanation ?? "unknown missing configuration")")
            return false
        }
        guard let speechURL = configuration.speechURL() else {
            print("🔊 ElevenLabs TTS invalid endpoint for voice: \(configuration.voiceID ?? "<nil>")")
            return false
        }

        isPlaybackInProgress = true
        self.onFinish = onFinish

        let requestPayload = SpeechRequest(
            text: trimmedUtterance,
            modelID: configuration.modelID
        )

        print("🔊 ElevenLabs TTS request — voice: \(configuration.voiceID ?? "<nil>"), model: \(configuration.modelID), format: \(configuration.outputFormat), chars: \(trimmedUtterance.count)")

        speechTask = Task { [configuration, urlSession] in
            do {
                let audioData = try await Self.generateSpeechAudio(
                    requestPayload: requestPayload,
                    configuration: configuration,
                    speechURL: speechURL,
                    urlSession: urlSession
                )
                guard !Task.isCancelled else { return }
                await self.playAudioData(audioData)
            } catch {
                guard !Task.isCancelled else { return }
                print("🔊 ElevenLabs TTS failed: \(error.localizedDescription)")
                await self.finishPlayback(didFinish: false)
            }
        }

        return true
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        onFinish = nil
        isPlaybackInProgress = false
    }

    private static func generateSpeechAudio(
        requestPayload: SpeechRequest,
        configuration: ElevenLabsSpeechConfiguration,
        speechURL: URL,
        urlSession: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: speechURL, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(try configuration.configuredAPIKey(), forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard !data.isEmpty else {
            throw ElevenLabsSpeechProviderError.emptyResponse
        }

        return data
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ElevenLabsSpeechProviderError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    private func playAudioData(_ audioData: Data) {
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                print("🔊 ElevenLabs TTS playback failed: AVAudioPlayer refused to start")
                finishPlayback(didFinish: false)
                return
            }
            audioPlayer = player
        } catch {
            print("🔊 ElevenLabs TTS playback failed: \(error.localizedDescription)")
            finishPlayback(didFinish: false)
        }
    }

    private func finishPlayback(didFinish: Bool) {
        speechTask?.cancel()
        speechTask = nil
        audioPlayer?.delegate = nil
        audioPlayer = nil
        isPlaybackInProgress = false

        let finishCallback = onFinish
        onFinish = nil
        finishCallback?(didFinish)
    }

    private struct SpeechRequest: Encodable {
        let text: String
        let modelID: String

        enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
        }
    }
}

extension ElevenLabsSpeechPlaybackProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finishPlayback(didFinish: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finishPlayback(didFinish: false)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
