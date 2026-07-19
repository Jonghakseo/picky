//
//  ElevenLabsTranscriptionProvider.swift
//  Picky
//
//  ElevenLabs speech-to-text provider (api.elevenlabs.io/v1/speech-to-text).
//

import AVFoundation
import Foundation

struct ElevenLabsTranscriptionConfiguration: Equatable {
    static let defaultBaseURL: URL = URL(string: "https://api.elevenlabs.io")!

    var apiKey: String?
    var baseURL: URL
    var requestTimeout: TimeInterval

    init(
        apiKey: String?,
        baseURL: URL = ElevenLabsTranscriptionConfiguration.defaultBaseURL,
        requestTimeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    var isConfigured: Bool { apiKey != nil }

    var missingConfigurationExplanation: String? {
        guard !isConfigured else { return nil }
        return "ElevenLabs transcription provider is missing: api key."
    }

    static func fromEnvironment(
        apiKeyOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ElevenLabsTranscriptionConfiguration {
        let apiKey = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? AzureOpenAIKeychainStore.value(for: "ELEVENLABS_API_KEY", environment: environment)
        let baseURLString = AzureOpenAIKeychainStore.value(for: "ELEVENLABS_BASE_URL", environment: environment)
        let baseURL = baseURLString.flatMap(URL.init(string:)) ?? defaultBaseURL
        return ElevenLabsTranscriptionConfiguration(apiKey: apiKey, baseURL: baseURL)
    }

    func transcriptionURL() -> URL {
        baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("speech-to-text")
    }

    func configuredAPIKey() throws -> String {
        guard let apiKey else {
            throw ElevenLabsTranscriptionProviderError.notConfigured(
                missingConfigurationExplanation ?? "ElevenLabs API key is missing."
            )
        }
        return apiKey
    }
}

enum ElevenLabsTranscriptionProviderError: LocalizedError {
    case notConfigured(String)
    case noAudioCaptured
    case emptyResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .noAudioCaptured:
            return "No audio was captured for ElevenLabs transcription."
        case .emptyResponse:
            return "ElevenLabs returned an empty transcription response."
        case .httpError(let statusCode, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else {
                return "ElevenLabs request failed with HTTP \(statusCode)."
            }
            let redactedBody = PickyDiagnosticTextRedactor.redact(trimmedBody)
            let truncatedBody = redactedBody.count > 200
                ? String(redactedBody.prefix(200)) + "…"
                : redactedBody
            return "ElevenLabs request failed with HTTP \(statusCode): \(truncatedBody)"
        }
    }
}

final class ElevenLabsTranscriptionProvider: BuddyTranscriptionProvider {
    /// 2026-05 기준 ElevenLabs 권장 batch transcription 모델. 레거시 `scribe_v1`은
    /// 공식 문서에서 "outclassed by v2 models"로 deprecated 표시되어 있어 v2를 default로 둔다.
    static let defaultModelID = "scribe_v2"
    private static let targetSampleRate = 16_000

    let displayName = "ElevenLabs Speech to Text"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { configuration.isConfigured }
    var unavailableExplanation: String? { configuration.missingConfigurationExplanation }

    private let configuration: ElevenLabsTranscriptionConfiguration
    private let modelID: String
    private let preferredLanguage: String?
    private let urlSession: URLSession

    init(
        configuration: ElevenLabsTranscriptionConfiguration = .fromEnvironment(),
        modelID: String = ElevenLabsTranscriptionProvider.defaultModelID,
        preferredLanguage: String? = nil,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = trimmedModel.isEmpty ? ElevenLabsTranscriptionProvider.defaultModelID : trimmedModel
        self.preferredLanguage = preferredLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.urlSession = urlSession
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard configuration.isConfigured else {
            throw ElevenLabsTranscriptionProviderError.notConfigured(
                configuration.missingConfigurationExplanation ?? "ElevenLabs transcription provider is not configured."
            )
        }

        // ElevenLabs STT는 keyterms를 multipart 파라미터로 받지 않음 — 무시
        _ = keyterms

        return ElevenLabsTranscriptionSession(
            configuration: configuration,
            transcriptionURL: configuration.transcriptionURL(),
            modelID: modelID,
            preferredLanguage: preferredLanguage,
            urlSession: urlSession,
            targetSampleRate: Self.targetSampleRate,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class ElevenLabsTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 12

    private let configuration: ElevenLabsTranscriptionConfiguration
    private let transcriptionURL: URL
    private let modelID: String
    private let preferredLanguage: String?
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
        configuration: ElevenLabsTranscriptionConfiguration,
        transcriptionURL: URL,
        modelID: String,
        preferredLanguage: String?,
        urlSession: URLSession,
        targetSampleRate: Int,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.transcriptionURL = transcriptionURL
        self.modelID = modelID
        self.preferredLanguage = preferredLanguage
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
            deliverErrorIfNeeded(ElevenLabsTranscriptionProviderError.noAudioCaptured)
            return
        }

        let wavData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: audioData,
            sampleRate: targetSampleRate
        )
        let requestStartedAt = Date()
        let audioByteCount = wavData.count
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=sttRequestStarted provider=elevenlabs audioBytes=\(audioByteCount)"
        )

        transcriptionTask = Task { [configuration, transcriptionURL, modelID, preferredLanguage, urlSession, onFinalTranscriptReady, requestStartedAt, audioByteCount] in
            do {
                let transcript = try await Self.transcribe(
                    wavData: wavData,
                    configuration: configuration,
                    transcriptionURL: transcriptionURL,
                    modelID: modelID,
                    preferredLanguage: preferredLanguage,
                    urlSession: urlSession
                )
                let requestMilliseconds = Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
                PickyLog.notice(
                    .latency,
                    prefix: "⏱️ Picky latency —",
                    message: "event=sttRequestFinished provider=elevenlabs ms=\(requestMilliseconds) audioBytes=\(audioByteCount) chars=\(transcript.count)"
                )
                guard !Task.isCancelled else { return }
                self.deliverFinalTranscriptIfNeeded(transcript, onFinalTranscriptReady: onFinalTranscriptReady)
            } catch {
                let requestMilliseconds = Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
                PickyLog.notice(
                    .latency,
                    prefix: "⏱️ Picky latency —",
                    message: "event=sttRequestFailed provider=elevenlabs ms=\(requestMilliseconds) audioBytes=\(audioByteCount)"
                )
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
        configuration: ElevenLabsTranscriptionConfiguration,
        transcriptionURL: URL,
        modelID: String,
        preferredLanguage: String?,
        urlSession: URLSession
    ) async throws -> String {
        let boundary = "PickyElevenLabsBoundary-\(UUID().uuidString)"
        var multipartBody = ElevenLabsMultipartFormData(boundary: boundary)
        multipartBody = multipartBody.addingField(name: "model_id", value: modelID)
        if let preferredLanguage = preferredLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            multipartBody = multipartBody.addingField(name: "language_code", value: preferredLanguage)
        }
        let bodyData = multipartBody
            .addingFile(
                fieldName: "file",
                filename: "picky-voice.wav",
                contentType: "audio/wav",
                data: wavData
            )
            .data

        var request = URLRequest(url: transcriptionURL, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(try configuration.configuredAPIKey(), forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTPResponse(response, data: data)

        let decodedResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decodedResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ElevenLabsTranscriptionProviderError.httpError(
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

private struct ElevenLabsMultipartFormData {
    let boundary: String
    private(set) var data = Data()

    func addingField(name: String, value: String) -> ElevenLabsMultipartFormData {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.append(value)
        copy.append("\r\n")
        return copy
    }

    func addingFile(fieldName: String, filename: String, contentType: String, data fileData: Data) -> ElevenLabsMultipartFormData {
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
