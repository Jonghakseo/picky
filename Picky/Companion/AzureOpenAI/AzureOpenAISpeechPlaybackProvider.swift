//
//  AzureOpenAISpeechPlaybackProvider.swift
//  Picky
//
//  Azure OpenAI text-to-speech provider. This file only implements the
//  pluggable provider; it is intentionally not selected by the default factory.
//

import AVFoundation
import Foundation

@MainActor
final class AzureOpenAISpeechPlaybackProvider: NSObject, PickySpeechPlaybackProvider {
    nonisolated static let defaultAPIVersion = "2025-04-01-preview"

    let displayName = "Azure OpenAI Text to Speech"

    var isSpeaking: Bool {
        isPlaybackInProgress
    }

    private let configuration: AzureOpenAIAudioConfiguration
    private let urlSession: URLSession
    private let voice: String
    private let responseFormat: String
    private let instructions: String?
    private let modelName: String?

    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var onFinish: ((Bool) -> Void)?
    private var isPlaybackInProgress = false

    init(
        configuration: AzureOpenAIAudioConfiguration = .fromEnvironment(
            deploymentEnvironmentKey: "AZURE_OPENAI_TTS_DEPLOYMENT_NAME",
            defaultAPIVersion: AzureOpenAISpeechPlaybackProvider.defaultAPIVersion
        ),
        urlSession: URLSession = .shared,
        voice: String = "alloy",
        responseFormat: String = "wav",
        instructions: String? = nil,
        modelName: String? = nil
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.voice = voice
        self.responseFormat = responseFormat
        self.instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        super.init()
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        stopSpeaking()

        let trimmedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUtterance.isEmpty else { return false }
        guard configuration.isConfigured else {
            print("🔊 Azure TTS not configured: \(configuration.missingConfigurationExplanation ?? "unknown missing configuration")")
            return false
        }
        guard let speechURL = configuration.deploymentURL(forAudioPath: "audio/speech") else {
            print("🔊 Azure TTS invalid endpoint for deployment: \(configuration.deploymentName ?? "<nil>")")
            return false
        }

        isPlaybackInProgress = true
        self.onFinish = onFinish

        let requestPayload = SpeechRequest(
            model: modelName ?? configuration.deploymentName ?? "tts-1",
            input: trimmedUtterance,
            voice: voice,
            responseFormat: responseFormat,
            instructions: instructions
        )

        print("🔊 Azure TTS request — deployment: \(configuration.deploymentName ?? "<nil>"), model: \(requestPayload.model), voice: \(voice), format: \(responseFormat), chars: \(trimmedUtterance.count)")

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
                print("🔊 Azure TTS failed: \(error.localizedDescription)")
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
        configuration: AzureOpenAIAudioConfiguration,
        speechURL: URL,
        urlSession: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: speechURL, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(try configuration.configuredAPIKey(), forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard !data.isEmpty else {
            throw AzureOpenAIAudioProviderError.emptyResponse
        }

        return data
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AzureOpenAIAudioProviderError.httpError(
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
                print("🔊 Azure TTS playback failed: AVAudioPlayer refused to start")
                finishPlayback(didFinish: false)
                return
            }
            audioPlayer = player
        } catch {
            print("🔊 Azure TTS playback failed: \(error.localizedDescription)")
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

extension AzureOpenAISpeechPlaybackProvider: AVAudioPlayerDelegate {
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
