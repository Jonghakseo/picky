//
//  GroqTranscriptionSettingsTests.swift
//  PickyTests
//
//  Groq STT routing, frequent-word hints and the Settings connection check.
//

import AVFoundation
import Foundation
import Testing
@testable import Picky

@Suite("Groq STT and transcription hints", .serialized)
struct GroqTranscriptionSettingsTests {
    private func defaults() -> PickySettings {
        PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory, seedDefaultWorkspace: false)
    }

    @Test func existingSettingsFileGainsDefaultFrequentWords() throws {
        let legacyJSON = #"{"defaultCwd": "/tmp", "sttProvider": "openai"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(PickySettings.self, from: legacyJSON)

        #expect(settings.sttVocabulary == "Picky, Pickle")
        #expect(settings.sttIncludesContextTerms == true)
        #expect(GroqTranscriptionDefaults.modelName(from: settings) == "whisper-large-v3")
    }

    @Test func groqSettingsSurviveSaveAndLoad() throws {
        var settings = defaults()
        settings.sttProvider = .groq
        settings.groqSTTModel = "whisper-large-v3-turbo"
        settings.groqSTTLanguage = "ko"
        settings.sttVocabulary = "Picky, 크리에이트립"
        settings.sttIncludesContextTerms = false

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PickySettings.self, from: encoded)

        #expect(decoded.sttProvider == .groq)
        // The Groq key is a Keychain secret and never part of settings.json.
        #expect(!String(decoding: encoded, as: UTF8.self).lowercased().contains("groqsttapikey"))
        #expect(decoded.groqSTTModel == "whisper-large-v3-turbo")
        #expect(decoded.groqSTTLanguage == "ko")
        #expect(decoded.sttVocabulary == "Picky, 크리에이트립")
        #expect(decoded.sttIncludesContextTerms == false)
    }

    @Test func groqSelectionUsesGroqEndpointAndStoredKey() throws {
        var settings = defaults()
        settings.sttProvider = .groq
        settings.openAISTTAPIKey = "sk-should-not-be-used"
        let secrets = PickyInMemorySecretStore()
        secrets.setSecret(" gsk_test ", for: .groqSTTAPIKey)

        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings, environment: [:], secretStore: secrets
        )
        let groq = try #require(provider as? GroqTranscriptionProvider)

        #expect(groq.displayName == GroqTranscriptionDefaults.displayName)
        #expect(groq.isConfigured)
        #expect(groq.configuration.apiKey == "gsk_test")
        #expect(groq.configuration.audioURL(forPath: "audio/transcriptions").absoluteString
            == "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    @Test func keySavedAfterProviderCreationAppliesWithoutRebuild() {
        var settings = defaults()
        settings.sttProvider = .groq
        let secrets = PickyInMemorySecretStore()
        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider(
            settings: settings, environment: [:], secretStore: secrets
        )
        #expect(provider.isConfigured == false)
        #expect(provider.unavailableExplanation != nil)

        secrets.setSecret("gsk_new", for: .groqSTTAPIKey)
        #expect(provider.isConfigured)

        secrets.setSecret("  ", for: .groqSTTAPIKey)
        #expect(provider.isConfigured == false)
    }

    @Test func frequentWordsAreParsedFromCommasAndNewlines() {
        let vocabulary = PickyTranscriptionVocabulary(termsText: " Picky,Pickle，크리에이트립\npicky\n\n", includesContextTerms: true)
        #expect(vocabulary.userTerms == ["Picky", "Pickle", "크리에이트립"])
    }

    @Test func requestPromptPutsFrequentWordsFirstAndCanOmitScreenTerms() async throws {
        let withContext = try await sentPrompt(
            vocabulary: PickyTranscriptionVocabulary(termsText: "Pickle, 크리에이트립", includesContextTerms: true),
            sessionKeyterms: ["Xcode", "Slack"]
        )
        let pickleIndex = try #require(withContext.range(of: "Pickle, 크리에이트립"))
        let xcodeIndex = try #require(withContext.range(of: "Xcode"))
        #expect(pickleIndex.lowerBound < xcodeIndex.lowerBound)

        let withoutContext = try await sentPrompt(
            vocabulary: PickyTranscriptionVocabulary(termsText: "Pickle, 크리에이트립", includesContextTerms: false),
            sessionKeyterms: ["Xcode", "Slack"]
        )
        #expect(withoutContext.contains("Pickle, 크리에이트립"))
        #expect(!withoutContext.contains("Xcode"))
        #expect(!withoutContext.contains("Slack"))
    }

    @Test(arguments: [
        (200, PickySTTConnectionCheckResult?.none),
        (401, .some(.invalidKey)),
        (429, .some(.rateLimited)),
        (500, .some(.failed(statusCode: 500))),
    ])
    func connectionCheckReportsProviderResponse(statusCode: Int, expected: PickySTTConnectionCheckResult?) async {
        GroqStubURLProtocol.reset(statusCode: statusCode)
        let configuration = OpenAIAudioConfiguration(apiKey: "gsk_test", baseURL: GroqTranscriptionDefaults.baseURL)

        let result = await OpenAITranscriptionProvider.checkConnection(
            configuration: configuration,
            modelName: "whisper-large-v3",
            urlSession: GroqStubURLProtocol.session()
        )

        if let expected {
            #expect(result == expected)
        } else if case .connected = result {
        } else {
            Issue.record("Expected connected, got \(result)")
        }
        let request = try? #require(GroqStubURLProtocol.lastRequest)
        #expect(request?.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer gsk_test")
        #expect(GroqStubURLProtocol.lastBodyText.contains("whisper-large-v3"))
    }

    @Test func connectionCheckWithoutKeyDoesNotSendRequest() async {
        GroqStubURLProtocol.reset(statusCode: 200)
        let result = await OpenAITranscriptionProvider.checkConnection(
            configuration: OpenAIAudioConfiguration(apiKey: "  ", baseURL: GroqTranscriptionDefaults.baseURL),
            modelName: "whisper-large-v3",
            urlSession: GroqStubURLProtocol.session()
        )
        #expect(result == .invalidKey)
        #expect(GroqStubURLProtocol.lastRequest == nil)
    }

    @Test func keyGuideStaysUntilKeyExistsAndIsNotRejected() {
        let rejected = PickySTTConnectionCheck(provider: .groq, apiKey: "gsk_bad", phase: .finished(.invalidKey))
        let accepted = PickySTTConnectionCheck(provider: .groq, apiKey: "gsk_ok", phase: .finished(.connected(milliseconds: 600)))

        #expect(PickySTTConnectionCheck.showsKeyGuide(apiKey: "", check: nil))
        #expect(PickySTTConnectionCheck.showsKeyGuide(apiKey: "gsk_bad", check: rejected))
        #expect(!PickySTTConnectionCheck.showsKeyGuide(apiKey: "gsk_ok", check: accepted))
        #expect(!PickySTTConnectionCheck.showsKeyGuide(apiKey: "gsk_new", check: nil))
        // A result for an older key must not be shown for the edited key.
        #expect(!rejected.applies(to: .groq, apiKey: "gsk_new"))
        #expect(!rejected.applies(to: .openai, apiKey: "gsk_bad"))
    }

    // MARK: Helpers

    private func sentPrompt(vocabulary: PickyTranscriptionVocabulary, sessionKeyterms: [String]) async throws -> String {
        GroqStubURLProtocol.reset(statusCode: 200)
        let provider = OpenAITranscriptionProvider(
            configuration: OpenAIAudioConfiguration(apiKey: "gsk_test", baseURL: GroqTranscriptionDefaults.baseURL),
            modelName: "whisper-large-v3",
            vocabulary: vocabulary,
            urlSession: GroqStubURLProtocol.session()
        )
        let finished = AsyncStream<Void>.makeStream()
        let session = try await provider.startStreamingSession(
            keyterms: sessionKeyterms,
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { _ in finished.continuation.finish() },
            onError: { _ in finished.continuation.finish() }
        )
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        session.appendAudioBuffer(buffer)
        session.requestFinalTranscript()
        for await _ in finished.stream {}
        return GroqStubURLProtocol.lastBodyText
    }
}

private final class GroqStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBodyText = ""

    static func reset(statusCode: Int) {
        self.statusCode = statusCode
        lastRequest = nil
        lastBodyText = ""
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBodyText = String(decoding: Self.bodyData(of: request), as: UTF8.self)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
