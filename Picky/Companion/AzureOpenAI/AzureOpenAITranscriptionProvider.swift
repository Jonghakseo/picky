//
//  AzureOpenAITranscriptionProvider.swift
//  Picky
//
//  Azure OpenAI speech-to-text provider. This file only implements the
//  pluggable provider; it is intentionally not selected by the default factory.
//

import AVFoundation
import Foundation

final class AzureOpenAITranscriptionProvider: BuddyTranscriptionProvider {
    static let defaultAPIVersion = "2024-02-01"
    private static let targetSampleRate = 16_000

    let displayName = "Azure OpenAI Speech to Text"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { configuration.isConfigured }
    var unavailableExplanation: String? { configuration.missingConfigurationExplanation }

    private let configuration: AzureOpenAIAudioConfiguration
    private let urlSession: URLSession

    init(
        configuration: AzureOpenAIAudioConfiguration = .fromEnvironment(
            deploymentEnvironmentKey: "AZURE_OPENAI_STT_DEPLOYMENT_NAME",
            defaultAPIVersion: AzureOpenAITranscriptionProvider.defaultAPIVersion
        ),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard configuration.isConfigured else {
            throw AzureOpenAIAudioProviderError.notConfigured(
                configuration.missingConfigurationExplanation ?? "Azure OpenAI transcription provider is not configured."
            )
        }

        guard let transcriptionURL = configuration.deploymentURL(forAudioPath: "audio/transcriptions") else {
            throw AzureOpenAIAudioProviderError.invalidEndpoint("audio/transcriptions")
        }

        return AzureOpenAITranscriptionSession(
            configuration: configuration,
            transcriptionURL: transcriptionURL,
            urlSession: urlSession,
            targetSampleRate: Self.targetSampleRate,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class AzureOpenAITranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 12

    private let configuration: AzureOpenAIAudioConfiguration
    private let transcriptionURL: URL
    private let urlSession: URLSession
    private let targetSampleRate: Int
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let lock = NSLock()
    private let audioConverter: BuddyPCM16AudioConverter
    private var pcm16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        configuration: AzureOpenAIAudioConfiguration,
        transcriptionURL: URL,
        urlSession: URLSession,
        targetSampleRate: Int,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.transcriptionURL = transcriptionURL
        self.urlSession = urlSession
        self.targetSampleRate = targetSampleRate
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.audioConverter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !hasRequestedFinalTranscript else { return }
        guard let convertedAudioData = audioConverter.convertToPCM16Data(from: audioBuffer) else { return }
        pcm16AudioData.append(convertedAudioData)
    }

    func requestFinalTranscript() {
        let audioData: Data

        lock.lock()
        guard !hasRequestedFinalTranscript else {
            lock.unlock()
            return
        }
        hasRequestedFinalTranscript = true
        audioData = pcm16AudioData
        lock.unlock()

        guard !audioData.isEmpty else {
            deliverErrorIfNeeded(AzureOpenAIAudioProviderError.noAudioCaptured)
            return
        }

        let wavData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: audioData,
            sampleRate: targetSampleRate
        )

        transcriptionTask = Task { [configuration, transcriptionURL, urlSession, onFinalTranscriptReady] in
            do {
                let transcript = try await Self.transcribe(
                    wavData: wavData,
                    configuration: configuration,
                    transcriptionURL: transcriptionURL,
                    urlSession: urlSession
                )
                guard !Task.isCancelled else { return }
                self.deliverFinalTranscriptIfNeeded(transcript, onFinalTranscriptReady: onFinalTranscriptReady)
            } catch {
                guard !Task.isCancelled else { return }
                self.deliverErrorIfNeeded(error)
            }
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private static func transcribe(
        wavData: Data,
        configuration: AzureOpenAIAudioConfiguration,
        transcriptionURL: URL,
        urlSession: URLSession
    ) async throws -> String {
        let boundary = "PickyAzureOpenAIBoundary-\(UUID().uuidString)"
        let multipartBody = AzureOpenAIMultipartFormData(boundary: boundary)
            .addingFile(
                fieldName: "file",
                filename: "picky-voice.wav",
                contentType: "audio/wav",
                data: wavData
            )
            .data

        var request = URLRequest(url: transcriptionURL, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(try configuration.configuredAPIKey(), forHTTPHeaderField: "api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decodedResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decodedResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func deliverFinalTranscriptIfNeeded(
        _ transcript: String,
        onFinalTranscriptReady: (String) -> Void
    ) {
        lock.lock()
        guard !hasDeliveredFinalTranscript else {
            lock.unlock()
            return
        }
        hasDeliveredFinalTranscript = true
        lock.unlock()

        onTranscriptUpdate(transcript)
        onFinalTranscriptReady(transcript)
    }

    private func deliverErrorIfNeeded(_ error: Error) {
        lock.lock()
        let shouldDeliver = !hasDeliveredFinalTranscript
        lock.unlock()

        guard shouldDeliver else { return }
        onError(error)
    }

    deinit {
        cancel()
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }
}

private struct AzureOpenAIMultipartFormData {
    let boundary: String
    private(set) var data = Data()

    func addingFile(fieldName: String, filename: String, contentType: String, data fileData: Data) -> AzureOpenAIMultipartFormData {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        copy.append("Content-Type: \(contentType)\r\n\r\n")
        copy.data.append(fileData)
        copy.append("\r\n")
        copy.append("--\(boundary)--\r\n")
        return copy
    }

    private mutating func append(_ string: String) {
        data.append(string.data(using: .utf8)!)
    }
}
