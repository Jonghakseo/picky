//
//  EdgeTTSSpeechPlaybackProvider.swift
//  Picky
//
//  Explicit opt-in playback through the authenticated local primary agentd.
//  agentd, rather than the app, owns the unofficial Edge Read Aloud adapter.
//

import AVFoundation
import Combine
import Foundation

struct PickyAgentdConnectionInfo: Decodable, Equatable {
    let url: String
    let token: String

    func httpURL(path: String) throws -> URL {
        guard var components = URLComponents(string: url),
              let host = components.host,
              ["127.0.0.1", "::1"].contains(host.lowercased()) else {
            throw EdgeTTSError.invalidConnectionInfo
        }
        switch components.scheme?.lowercased() {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: throw EdgeTTSError.invalidConnectionInfo
        }
        components.path = path
        components.query = nil
        guard let endpoint = components.url else { throw EdgeTTSError.invalidConnectionInfo }
        return endpoint
    }
}

protocol PickyAgentdConnectionInfoReading {
    func readConnectionInfo() throws -> PickyAgentdConnectionInfo
}

struct PickyAgentdConnectionInfoStore: PickyAgentdConnectionInfoReading {
    let appSupportRoot: URL
    let fileManager: FileManager

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.appSupportRoot = appSupportRoot
        self.fileManager = fileManager
    }

    func readConnectionInfo() throws -> PickyAgentdConnectionInfo {
        let fileURL = appSupportRoot.appendingPathComponent("agentd-connection.json", isDirectory: false)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw EdgeTTSError.insecureConnectionInfo
        }
        return try JSONDecoder().decode(PickyAgentdConnectionInfo.self, from: Data(contentsOf: fileURL))
    }
}

enum EdgeTTSError: LocalizedError {
    case invalidConnectionInfo
    case insecureConnectionInfo
    case emptyResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConnectionInfo:
            return L10n.t("speech.edge.error.connectionUnavailable")
        case .insecureConnectionInfo:
            return L10n.t("speech.edge.error.insecureConnection")
        case .emptyResponse:
            return L10n.t("speech.edge.error.emptyResponse")
        case .httpError(let status):
            return L10n.t("speech.edge.error.http", status)
        }
    }
}

struct EdgeTTSVoice: Codable, Equatable, Identifiable {
    let shortName: String
    let locale: String
    let gender: String
    let friendlyName: String

    var id: String { shortName }
}

/// Pure Settings projection. A voice saved by an earlier Edge catalog remains
/// selected even if Edge later removes it; never silently substitute a different
/// locale or voice just to satisfy a menu's selection binding.
enum EdgeTTSVoiceCatalogProjection {
    static let unavailableLocale = "__unavailable__"

    static func selectedLocale(voice: String, voices: [EdgeTTSVoice]) -> String? {
        if let catalogVoice = voices.first(where: { $0.shortName == voice }) {
            return catalogVoice.locale
        }
        return locale(inVoiceIdentifier: voice)
    }

    static func locales(voices: [EdgeTTSVoice], selectedVoice: String) -> [String] {
        var result = Set(voices.map(\.locale))
        if let selectedLocale = selectedLocale(voice: selectedVoice, voices: voices) {
            result.insert(selectedLocale)
        } else if !isSelectedVoiceAvailable(selectedVoice, voices: voices) {
            result.insert(unavailableLocale)
        }
        return result.sorted()
    }

    static func isSelectedVoiceAvailable(_ voice: String, voices: [EdgeTTSVoice]) -> Bool {
        voices.contains { $0.shortName == voice }
    }

    static func genderLocalizationKey(_ gender: String) -> String? {
        switch gender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male": return "settings.voice.edge.gender.male"
        case "female": return "settings.voice.edge.gender.female"
        default: return nil
        }
    }

    private static func locale(inVoiceIdentifier voice: String) -> String? {
        let parts = voice.split(separator: "-", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              (2...3).contains(parts[0].count),
              parts[0].allSatisfy(\.isLetter) else {
            return nil
        }

        let language = parts[0]
        let second = parts[1]
        if second.count == 4,
           second.allSatisfy(\.isLetter) {
            if parts.count >= 4,
               (2...3).contains(parts[2].count),
               parts[2].allSatisfy({ $0.isLetter || $0.isNumber }) {
                return "\(language)-\(second)-\(parts[2])"
            }
            return "\(language)-\(second)"
        }
        guard (2...3).contains(second.count),
              second.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return "\(language)-\(second)"
    }
}

struct EdgeTTSVoiceCatalogClient {
    let connectionInfoStore: any PickyAgentdConnectionInfoReading
    let urlSession: URLSession

    init(
        connectionInfoStore: any PickyAgentdConnectionInfoReading = PickyAgentdConnectionInfoStore(),
        urlSession: URLSession = .shared
    ) {
        self.connectionInfoStore = connectionInfoStore
        self.urlSession = urlSession
    }

    func listVoices() async throws -> [EdgeTTSVoice] {
        let connection = try connectionInfoStore.readConnectionInfo()
        var request = URLRequest(url: try connection.httpURL(path: "/v1/edge-tts/voices"), timeoutInterval: 15)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(VoiceResponse.self, from: data).voices
            .sorted { $0.locale == $1.locale ? $0.friendlyName < $1.friendlyName : $0.locale < $1.locale }
    }

    private struct VoiceResponse: Decodable {
        let voices: [EdgeTTSVoice]
    }
}

@MainActor
final class EdgeTTSVoiceCatalog: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var voices: [EdgeTTSVoice] = []
    @Published private(set) var state: State = .idle

    private let client: EdgeTTSVoiceCatalogClient
    private var refreshTask: Task<Void, Never>?

    init(client: EdgeTTSVoiceCatalogClient = EdgeTTSVoiceCatalogClient()) {
        self.client = client
    }

    deinit { refreshTask?.cancel() }

    func refresh() {
        refreshTask?.cancel()
        state = .loading
        refreshTask = Task { [client] in
            do {
                let voices = try await client.listVoices()
                guard !Task.isCancelled else { return }
                self.voices = voices
                self.state = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    var locales: [String] {
        Array(Set(voices.map(\.locale))).sorted()
    }

    func locales(selectedVoice: String) -> [String] {
        EdgeTTSVoiceCatalogProjection.locales(voices: voices, selectedVoice: selectedVoice)
    }

    func voices(in locale: String) -> [EdgeTTSVoice] {
        voices.filter { $0.locale == locale }
    }
}

@MainActor
final class EdgeTTSSpeechPlaybackProvider: NSObject, PickySpeechPlaybackProvider {
    var displayName: String { L10n.t("settings.voice.edge.provider") }
    var isSpeaking: Bool { isPlaybackInProgress }
    // Each narration sentence is a separate Edge request, so the buddy can speak
    // sentence-by-sentence as they stream instead of waiting for the whole reply.
    let supportsIncrementalPlayback = true

    private let connectionInfoStore: any PickyAgentdConnectionInfoReading
    private let urlSession: URLSession
    private let voice: String
    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var activeSpeechID: UUID?
    private var onFinish: ((Bool) -> Void)?
    private var isPlaybackInProgress = false
    // Warmed audio for upcoming sentences, keyed by normalized text. Prefetching
    // the next sentence during the current one hides its ~synth+network latency.
    private var prefetchTasks: [String: Task<Data, Error>] = [:]
    private static let maxPrefetchEntries = 3

    init(
        voice: String,
        connectionInfoStore: any PickyAgentdConnectionInfoReading = PickyAgentdConnectionInfoStore(),
        urlSession: URLSession = .shared
    ) {
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ko-KR-SunHiNeural" : voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectionInfoStore = connectionInfoStore
        self.urlSession = urlSession
        super.init()
    }

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        let input = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { stopSpeaking(); return false }
        // Reclaim this sentence's warmed audio before stopSpeaking() clears the
        // cache, so a prefetch in flight is consumed rather than discarded.
        let prefetched = prefetchTasks.removeValue(forKey: input)
        stopSpeaking()

        let speechID = UUID()
        activeSpeechID = speechID
        isPlaybackInProgress = true
        self.onFinish = onFinish
        speechTask = Task { [connectionInfoStore, urlSession, voice] in
            do {
                let audio: Data
                if let prefetched {
                    audio = try await prefetched.value
                } else {
                    let connection = try connectionInfoStore.readConnectionInfo()
                    audio = try await Self.generateSpeechAudio(input: input, voice: voice, connection: connection, urlSession: urlSession)
                }
                guard !Task.isCancelled else { return }
                self.playAudioData(audio, speechID: speechID)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishPlaybackIfActive(speechID: speechID, didFinish: false)
            }
        }
        return true
    }

    func prefetch(_ utterance: String) {
        let input = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, prefetchTasks[input] == nil else { return }
        // Bound memory: drop the oldest warmed entry once the cache is full.
        if prefetchTasks.count >= Self.maxPrefetchEntries, let stale = prefetchTasks.keys.first {
            prefetchTasks.removeValue(forKey: stale)?.cancel()
        }
        prefetchTasks[input] = Task { [connectionInfoStore, urlSession, voice] in
            let connection = try connectionInfoStore.readConnectionInfo()
            return try await Self.generateSpeechAudio(input: input, voice: voice, connection: connection, urlSession: urlSession)
        }
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeSpeechID = nil
        onFinish = nil
        isPlaybackInProgress = false
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
    }

    static func makeSpeechRequest(input: String, voice: String, connection: PickyAgentdConnectionInfo) throws -> URLRequest {
        var request = URLRequest(url: try connection.httpURL(path: "/v1/edge-tts/speech"), timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SpeechRequest(input: input, voice: voice))
        return request
    }

    private static func generateSpeechAudio(input: String, voice: String, connection: PickyAgentdConnectionInfo, urlSession: URLSession) async throws -> Data {
        let request = try makeSpeechRequest(input: input, voice: voice, connection: connection)
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response, data: data)
        guard !data.isEmpty else { throw EdgeTTSError.emptyResponse }
        return data
    }

    private func playAudioData(_ data: Data, speechID: UUID) {
        guard activeSpeechID == speechID else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                finishPlaybackIfActive(speechID: speechID, didFinish: false)
                return
            }
            audioPlayer = player
        } catch {
            finishPlaybackIfActive(speechID: speechID, didFinish: false)
        }
    }

    private func finishPlaybackIfActive(speechID: UUID, didFinish: Bool) {
        guard activeSpeechID == speechID else { return }
        speechTask?.cancel()
        speechTask = nil
        audioPlayer?.delegate = nil
        audioPlayer = nil
        activeSpeechID = nil
        isPlaybackInProgress = false
        let callback = onFinish
        onFinish = nil
        callback?(didFinish)
    }

    private struct SpeechRequest: Encodable {
        let input: String
        let voice: String
    }
}

extension EdgeTTSSpeechPlaybackProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let active = self.audioPlayer, ObjectIdentifier(active) == ObjectIdentifier(player), let speechID = self.activeSpeechID else { return }
            self.finishPlaybackIfActive(speechID: speechID, didFinish: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, let active = self.audioPlayer, ObjectIdentifier(active) == ObjectIdentifier(player), let speechID = self.activeSpeechID else { return }
            self.finishPlaybackIfActive(speechID: speechID, didFinish: false)
        }
    }
}

private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw EdgeTTSError.httpError(status)
    }
}
