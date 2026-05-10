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

    private static func defaultTranscriptionPrompt(keyterms: [String]) -> String {
        var seenKeyterms = Set<String>()
        let uniqueKeyterms = keyterms.compactMap { keyterm -> String? in
            let trimmed = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed.lowercased()
            guard !seenKeyterms.contains(normalized) else { return nil }
            seenKeyterms.insert(normalized)
            return trimmed
        }
        let vocabulary = uniqueKeyterms.prefix(40).joined(separator: ", ")
        let vocabularyLine = vocabulary.isEmpty ? "" : "\n주요 용어: \(vocabulary)."

        return """
        이 음성은 Picky macOS 앱을 조작하는 한국어/영어 혼합 명령입니다.
        "Picky"는 앱 이름이며 "피키" 또는 "Picky야"로 불릴 수 있습니다. "비키"나 "미키"처럼 들려도 문맥상 Picky일 수 있습니다.
        "Pickle"은 Picky 안의 작업 세션 이름이고, "Pi"는 로컬 코딩 에이전트 이름입니다.
        제품명과 개발 용어는 그대로 보존하고, 말한 내용을 요약하지 말고 그대로 전사하세요.\(vocabularyLine)
        """
    }

    let displayName = "Azure OpenAI Speech to Text"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { configuration.isConfigured }
    var unavailableExplanation: String? { configuration.missingConfigurationExplanation }

    private let configuration: AzureOpenAIAudioConfiguration
    private let preferredLanguage: String?
    private let urlSession: URLSession

    init(
        configuration: AzureOpenAIAudioConfiguration = .fromTranscriptionEndpointURL(nil, apiKey: nil),
        preferredLanguage: String? = nil,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
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
            preferredLanguage: preferredLanguage,
            transcriptionPrompt: Self.defaultTranscriptionPrompt(keyterms: keyterms),
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
    private let preferredLanguage: String?
    private let transcriptionPrompt: String?
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
        preferredLanguage: String?,
        transcriptionPrompt: String?,
        urlSession: URLSession,
        targetSampleRate: Int,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.transcriptionURL = transcriptionURL
        self.preferredLanguage = preferredLanguage
        self.transcriptionPrompt = transcriptionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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

        transcriptionTask = Task { [configuration, transcriptionURL, preferredLanguage, transcriptionPrompt, urlSession, onFinalTranscriptReady] in
            do {
                let transcript = try await Self.transcribe(
                    wavData: wavData,
                    configuration: configuration,
                    transcriptionURL: transcriptionURL,
                    preferredLanguage: preferredLanguage,
                    transcriptionPrompt: transcriptionPrompt,
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
        preferredLanguage: String?,
        transcriptionPrompt: String?,
        urlSession: URLSession
    ) async throws -> String {
        let boundary = "PickyAzureOpenAIBoundary-\(UUID().uuidString)"
        var multipartBody = AzureOpenAIMultipartFormData(boundary: boundary)
        if let preferredLanguage = preferredLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            multipartBody = multipartBody.addingField(name: "language", value: preferredLanguage)
        }
        if let transcriptionPrompt = transcriptionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            multipartBody = multipartBody.addingField(name: "prompt", value: transcriptionPrompt)
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
        request.setValue(try configuration.configuredAPIKey(), forHTTPHeaderField: "api-key")
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

    func addingField(name: String, value: String) -> AzureOpenAIMultipartFormData {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.append(value)
        copy.append("\r\n")
        return copy
    }

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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
