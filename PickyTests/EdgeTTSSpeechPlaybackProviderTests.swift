//
//  EdgeTTSSpeechPlaybackProviderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private enum EdgeTTSTestError: Error {
    case connectionUnavailable
}

private struct EdgeTTSFakeConnectionStore: PickyAgentdConnectionInfoReading {
    let connection: PickyAgentdConnectionInfo

    func readConnectionInfo() throws -> PickyAgentdConnectionInfo { connection }
}

private struct EdgeTTSUnavailableConnectionStore: PickyAgentdConnectionInfoReading {
    func readConnectionInfo() throws -> PickyAgentdConnectionInfo {
        throw EdgeTTSTestError.connectionUnavailable
    }
}

private final class EdgeTTSURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class EdgeTTSSuspendedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static weak var pending: EdgeTTSSuspendedURLProtocol?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.pending = self
    }

    override func stopLoading() {}

    static func finishWithEmptySuccess() {
        guard let pending, let url = pending.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        pending.client?.urlProtocol(pending, didReceive: response, cacheStoragePolicy: .notAllowed)
        pending.client?.urlProtocol(pending, didLoad: Data())
        pending.client?.urlProtocolDidFinishLoading(pending)
        self.pending = nil
    }
}

@MainActor
private final class EdgeTTSFallbackProvider: PickySpeechPlaybackProvider {
    let displayName = "Fallback"
    private(set) var speakCount = 0
    private(set) var isSpeaking = false
    private var finish: ((Bool) -> Void)?

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        speakCount += 1
        isSpeaking = true
        finish = onFinish
        return true
    }

    func stopSpeaking() {
        isSpeaking = false
        finish = nil
    }

    func complete(_ didFinish: Bool) {
        isSpeaking = false
        let callback = finish
        finish = nil
        callback?(didFinish)
    }
}

@MainActor
private func edgeTTSTestSession(protocolClass: URLProtocol.Type) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

@MainActor
private func waitForEdgeTTSCondition(
    timeout: TimeInterval = 1,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw EdgeTTSTestError.connectionUnavailable
}

@Suite("Edge TTS provider", .serialized)
struct EdgeTTSSpeechPlaybackProviderTests {
    @Test func connectionInfoConvertsLoopbackWebSocketURLToHTTP() throws {
        let connection = PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631/?token=old", token: "secret")
        #expect(try connection.httpURL(path: "/v1/edge-tts/voices").absoluteString == "http://127.0.0.1:17631/v1/edge-tts/voices")
    }

    @Test func connectionInfoRejectsNonLoopbackDaemonURL() {
        let connection = PickyAgentdConnectionInfo(url: "ws://example.com:17631", token: "secret")
        #expect(throws: EdgeTTSError.self) {
            _ = try connection.httpURL(path: "/v1/edge-tts/voices")
        }
    }

    @Test func connectionInfoStoreRequiresOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("agentd-connection.json")
        try "{\"url\":\"ws://127.0.0.1:17631\",\"token\":\"secret\"}".data(using: .utf8)!.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let store = PickyAgentdConnectionInfoStore(appSupportRoot: root)
        #expect(throws: EdgeTTSError.self) { _ = try store.readConnectionInfo() }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try store.readConnectionInfo().token == "secret")
    }

    @MainActor
    @Test func speechRequestUsesLocalRouteBearerTokenAndJSONBody() throws {
        let request = try EdgeTTSSpeechPlaybackProvider.makeSpeechRequest(
            input: "안녕하세요",
            voice: "ko-KR-SunHiNeural",
            connection: PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631", token: "test-token")
        )
        #expect(request.url?.absoluteString == "http://127.0.0.1:17631/v1/edge-tts/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
        let body = try #require(request.httpBody)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(payload?["input"] == "안녕하세요")
        #expect(payload?["voice"] == "ko-KR-SunHiNeural")
    }

    @MainActor
    @Test func catalogClientSortsVoicesByLocaleAndName() async throws {
        EdgeTTSURLProtocol.statusCode = 200
        EdgeTTSURLProtocol.responseBody = """
        {"voices":[
          {"shortName":"ko-KR-SunHiNeural","locale":"ko-KR","gender":"Female","friendlyName":"SunHi"},
          {"shortName":"en-US-ZoeNeural","locale":"en-US","gender":"Female","friendlyName":"Zoe"},
          {"shortName":"en-US-AriaNeural","locale":"en-US","gender":"Female","friendlyName":"Aria"}
        ]}
        """.data(using: .utf8)!
        let client = EdgeTTSVoiceCatalogClient(
            connectionInfoStore: EdgeTTSFakeConnectionStore(connection: PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631", token: "test-token")),
            urlSession: edgeTTSTestSession(protocolClass: EdgeTTSURLProtocol.self)
        )

        let voices = try await client.listVoices()
        #expect(voices.map(\.shortName) == ["en-US-AriaNeural", "en-US-ZoeNeural", "ko-KR-SunHiNeural"])
    }

    @Test func missingSavedVoiceKeepsItsDerivedLocaleAndAddsUnavailableLocaleWhenUnknown() {
        let voices = [EdgeTTSVoice(shortName: "ko-KR-SunHiNeural", locale: "ko-KR", gender: "Female", friendlyName: "SunHi")]
        #expect(EdgeTTSVoiceCatalogProjection.selectedLocale(voice: "en-US-AriaNeural", voices: voices) == "en-US")
        #expect(EdgeTTSVoiceCatalogProjection.selectedLocale(voice: "sr-Latn-RS-NicholasNeural", voices: voices) == "sr-Latn-RS")
        #expect(EdgeTTSVoiceCatalogProjection.selectedLocale(voice: "zh-Hans-XiaoxiaoNeural", voices: voices) == "zh-Hans")
        #expect(EdgeTTSVoiceCatalogProjection.locales(voices: voices, selectedVoice: "en-US-AriaNeural") == ["en-US", "ko-KR"])
        #expect(EdgeTTSVoiceCatalogProjection.locales(voices: voices, selectedVoice: "unknown") == [EdgeTTSVoiceCatalogProjection.unavailableLocale, "ko-KR"])
        #expect(EdgeTTSVoiceCatalogProjection.isSelectedVoiceAvailable("en-US-AriaNeural", voices: voices) == false)
    }

    @Test func genderProjectionUsesLocalizedLabelsAndOmitsUnknownValues() {
        #expect(EdgeTTSVoiceCatalogProjection.genderLocalizationKey("Male") == "settings.voice.edge.gender.male")
        #expect(EdgeTTSVoiceCatalogProjection.genderLocalizationKey("female") == "settings.voice.edge.gender.female")
        #expect(EdgeTTSVoiceCatalogProjection.genderLocalizationKey("Nonbinary") == nil)
    }

    @MainActor
    @Test func HTTPErrorDescriptionDoesNotExposeDaemonResponseBody() async {
        let rawDaemonResponse = #"{"error":"unexpected upstream response"}"#
        EdgeTTSURLProtocol.statusCode = 502
        EdgeTTSURLProtocol.responseBody = Data(rawDaemonResponse.utf8)
        let client = EdgeTTSVoiceCatalogClient(
            connectionInfoStore: EdgeTTSFakeConnectionStore(connection: PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631", token: "test-token")),
            urlSession: edgeTTSTestSession(protocolClass: EdgeTTSURLProtocol.self)
        )

        do {
            _ = try await client.listVoices()
            Issue.record("Expected the Edge TTS daemon HTTP error.")
        } catch {
            #expect(error.localizedDescription.contains("502"))
            #expect(!error.localizedDescription.contains(rawDaemonResponse))
        }
    }

    @MainActor
    @Test func emptyInputIsRefusedWithoutStartingPlayback() {
        let provider = EdgeTTSSpeechPlaybackProvider(
            voice: "ko-KR-SunHiNeural",
            connectionInfoStore: EdgeTTSUnavailableConnectionStore()
        )
        var completionCount = 0
        #expect(provider.speak(" \n") { _ in completionCount += 1 } == false)
        #expect(provider.isSpeaking == false)
        #expect(completionCount == 0)
    }

    @MainActor
    @Test func unavailableConnectionFinishesOnceWithFailure() async throws {
        let provider = EdgeTTSSpeechPlaybackProvider(
            voice: "ko-KR-SunHiNeural",
            connectionInfoStore: EdgeTTSUnavailableConnectionStore()
        )
        var completions: [Bool] = []
        #expect(provider.speak("hello") { completions.append($0) })

        try await waitForEdgeTTSCondition { completions.count == 1 }
        #expect(completions == [false])
        #expect(provider.isSpeaking == false)
    }

    @MainActor
    @Test func HTTPFailureAndEmptyBodyFinishWithFailure() async throws {
        let connection = EdgeTTSFakeConnectionStore(connection: PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631", token: "test-token"))
        for (statusCode, body) in [(500, Data("error".utf8)), (200, Data())] {
            EdgeTTSURLProtocol.statusCode = statusCode
            EdgeTTSURLProtocol.responseBody = body
            let provider = EdgeTTSSpeechPlaybackProvider(
                voice: "ko-KR-SunHiNeural",
                connectionInfoStore: connection,
                urlSession: edgeTTSTestSession(protocolClass: EdgeTTSURLProtocol.self)
            )
            var completions: [Bool] = []
            #expect(provider.speak("hello") { completions.append($0) })
            try await waitForEdgeTTSCondition { completions.count == 1 }
            #expect(completions == [false])
            #expect(provider.isSpeaking == false)
        }
    }

    @MainActor
    @Test func cancellationSuppressesLateCompletionAndKeepsProviderIdle() async throws {
        EdgeTTSSuspendedURLProtocol.pending = nil
        let provider = EdgeTTSSpeechPlaybackProvider(
            voice: "ko-KR-SunHiNeural",
            connectionInfoStore: EdgeTTSFakeConnectionStore(connection: PickyAgentdConnectionInfo(url: "ws://127.0.0.1:17631", token: "test-token")),
            urlSession: edgeTTSTestSession(protocolClass: EdgeTTSSuspendedURLProtocol.self)
        )
        var completions: [Bool] = []
        #expect(provider.speak("hello") { completions.append($0) })
        try await waitForEdgeTTSCondition { EdgeTTSSuspendedURLProtocol.pending != nil }

        provider.stopSpeaking()
        EdgeTTSSuspendedURLProtocol.finishWithEmptySuccess()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(completions.isEmpty)
        #expect(provider.isSpeaking == false)
    }

    @MainActor
    @Test func primaryFailureStartsFallbackOnceAndCompletesOnce() async throws {
        let primary = EdgeTTSSpeechPlaybackProvider(
            voice: "ko-KR-SunHiNeural",
            connectionInfoStore: EdgeTTSUnavailableConnectionStore()
        )
        let fallback = EdgeTTSFallbackProvider()
        let provider = PickyFallbackSpeechPlaybackProvider(primary: primary, fallback: fallback)
        var completions: [Bool] = []

        #expect(provider.speak("hello") { completions.append($0) })
        try await waitForEdgeTTSCondition { fallback.speakCount == 1 }
        #expect(completions.isEmpty)
        fallback.complete(true)
        try await waitForEdgeTTSCondition { completions.count == 1 }
        #expect(completions == [true])
        #expect(fallback.speakCount == 1)
    }

    @MainActor
    @Test func factoryRoutesExplicitEdgeSelectionThroughMacOSFallback() throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.ttsProvider = .edge
        settings.edgeTTSVoice = "en-US-AriaNeural"

        let provider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(settings: settings, environment: [:])
        let wrapper = try #require(provider as? PickyFallbackSpeechPlaybackProvider)
        #expect(wrapper.primary is EdgeTTSSpeechPlaybackProvider)
        #expect(wrapper.fallback is PickySystemSpeechPlaybackProvider)
    }
}
