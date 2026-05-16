//
//  OpenAISpeechPlaybackProvider.swift
//  Picky
//
//  OpenAI direct text-to-speech provider (api.openai.com/v1/audio/speech).
//

import AVFoundation
import Foundation

@MainActor
final class OpenAISpeechPlaybackProvider: NSObject, PickySpeechPlaybackProvider {
    static let defaultModelName = "gpt-4o-mini-tts"
    static let defaultVoice = "alloy"
    static let defaultResponseFormat = "wav"

    let displayName = "OpenAI Text to Speech"

    var isSpeaking: Bool {
        isPlaybackInProgress
    }

    private let configuration: OpenAIAudioConfiguration
    private let urlSession: URLSession
    private let voice: String
    private let responseFormat: String
    private let instructions: String?
    private let modelName: String

    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var onFinish: ((Bool) -> Void)?
    private var isPlaybackInProgress = false

    init(
        configuration: OpenAIAudioConfiguration = .fromEnvironment(),
        urlSession: URLSession = .shared,
        voice: String = OpenAISpeechPlaybackProvider.defaultVoice,
        responseFormat: String = OpenAISpeechPlaybackProvider.defaultResponseFormat,
        instructions: String? = nil,
        modelName: String = OpenAISpeechPlaybackProvider.defaultModelName
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = trimmedVoice.isEmpty ? OpenAISpeechPlaybackProvider.defaultVoice : trimmedVoice
        let trimmedFormat = responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        self.responseFormat = trimmedFormat.isEmpty ? OpenAISpeechPlaybackProvider.defaultResponseFormat : trimmedFormat
        self.instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = trimmedModel.isEmpty ? OpenAISpeechPlaybackProvider.defaultModelName : trimmedModel
        super.init()
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()

        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUtterance.isEmpty else { return false }
        guard configuration.isConfigured else {
            print("🔊 OpenAI TTS not configured: \(configuration.missingConfigurationExplanation ?? "unknown missing configuration")")
            return false
        }

        let speechURL = configuration.audioURL(forPath: "audio/speech")

        isPlaybackInProgress = true
        self.onFinish = onFinish

        let requestPayload = SpeechRequest(
            model: modelName,
            input: trimmedUtterance,
            voice: voice,
            responseFormat: responseFormat,
            instructions: instructions
        )

        print("🔊 OpenAI TTS request — model: \(modelName), voice: \(voice), format: \(responseFormat), chars: \(trimmedUtterance.count)")

        speechTask = Task { [configuration, urlSession] in
            do {
                let audioData = try await Self.generateSpeechAudio(
                    requestPayload: requestPayload,
                    configuration: configuration,
                    speechURL: speechURL,
                    urlSession: urlSession
                )
                guard !Task.isCancelled else { return }
                self.playAudioData(audioData)
            } catch {
                guard !Task.isCancelled else { return }
                print("🔊 OpenAI TTS failed: \(error.localizedDescription)")
                self.finishPlayback(didFinish: false)
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
        configuration: OpenAIAudioConfiguration,
        speechURL: URL,
        urlSession: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: speechURL, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try configuration.configuredAPIKey())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard !data.isEmpty else {
            throw OpenAIAudioProviderError.emptyResponse
        }

        return data
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIAudioProviderError.httpError(
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
                print("🔊 OpenAI TTS playback failed: AVAudioPlayer refused to start")
                finishPlayback(didFinish: false)
                return
            }
            audioPlayer = player
        } catch {
            print("🔊 OpenAI TTS playback failed: \(error.localizedDescription)")
            finishPlayback(didFinish: false)
        }
    }

    private func finishPlaybackIfActive(playerID: ObjectIdentifier, didFinish: Bool) {
        guard let active = audioPlayer, ObjectIdentifier(active) == playerID else { return }
        finishPlayback(didFinish: didFinish)
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
        let model: String
        let input: String
        let voice: String
        let responseFormat: String
        let instructions: String?

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case voice
            case responseFormat = "response_format"
            case instructions
        }
    }
}

extension OpenAISpeechPlaybackProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlaybackIfActive(playerID: playerID, didFinish: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.finishPlaybackIfActive(playerID: playerID, didFinish: false)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
