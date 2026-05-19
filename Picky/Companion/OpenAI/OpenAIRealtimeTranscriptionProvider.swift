//
//  OpenAIRealtimeTranscriptionProvider.swift
//  Picky
//
//  Streaming STT backed by the OpenAI Realtime *transcription* session, with
//  authentication handled by picky-agentd using the signed-in Codex/ChatGPT
//  OAuth token. Picky never holds a Platform API key for this path; the daemon
//  resolves the bearer at connect time and proxies the WebSocket back through
//  the existing PickyAgentClient command/event channel.
//
//  Protocol surface used here (defined in agentd/src/protocol.ts):
//    Commands  : beginTranscriptionStream, appendTranscriptionAudio,
//                endTranscriptionStream, cancelTranscriptionStream
//    Events    : transcriptionStreamStarted, transcriptionDelta,
//                transcriptionCompleted, transcriptionStreamFailed,
//                transcriptionStreamClosed
//

import AVFoundation
import Foundation

extension Notification.Name {
    static let pickyTranscriptionStreamStarted = Notification.Name("PickyTranscriptionStreamStarted")
    static let pickyTranscriptionDelta = Notification.Name("PickyTranscriptionDelta")
    static let pickyTranscriptionCompleted = Notification.Name("PickyTranscriptionCompleted")
    static let pickyTranscriptionStreamFailed = Notification.Name("PickyTranscriptionStreamFailed")
    static let pickyTranscriptionStreamClosed = Notification.Name("PickyTranscriptionStreamClosed")
}

final class OpenAIRealtimeTranscriptionProvider: BuddyTranscriptionProvider {
    static let defaultModelName = "gpt-4o-transcribe"
    static let defaultSampleRate: Double = 24_000

    let displayName = "OpenAI Realtime STT"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { agentClient != nil }
    var unavailableExplanation: String? {
        agentClient == nil ? "Realtime STT requires picky-agentd to be connected." : nil
    }

    nonisolated(unsafe) private weak var agentClient: PickyAgentClient?
    private let preferredLanguage: String?
    private let modelName: String

    init(
        agentClient: PickyAgentClient?,
        preferredLanguage: String? = nil,
        modelName: String = OpenAIRealtimeTranscriptionProvider.defaultModelName
    ) {
        self.agentClient = agentClient
        self.preferredLanguage = preferredLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyString
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = trimmed.isEmpty ? OpenAIRealtimeTranscriptionProvider.defaultModelName : trimmed
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let agentClient else {
            throw NSError(domain: "OpenAIRealtimeTranscriptionProvider", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "picky-agentd is not connected; cannot start realtime STT.",
            ])
        }

        let streamId = "stt-\(UUID().uuidString)"
        let command = PickyCommandEnvelope(
            type: .beginTranscriptionStream,
            streamId: streamId,
            language: preferredLanguage,
            model: modelName,
            keyterms: keyterms.isEmpty ? nil : keyterms
        )
        try await agentClient.send(command)

        // Hop to MainActor for the streaming session because the
        // notification-observer closures it installs need to dispatch back to
        // the main run loop. The factory itself stays non-isolated so the
        // existing synchronous test signatures keep compiling.
        return await MainActor.run {
            OpenAIRealtimeTranscriptionStreamingSession(
                streamId: streamId,
                agentClient: agentClient,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        }

    }
}

final class OpenAIRealtimeTranscriptionStreamingSession: NSObject, BuddyStreamingTranscriptionSession {
    // Realtime usually delivers `transcription.completed` within a couple of
    // hundred ms after `input_audio_buffer.commit`; we still keep the same
    // generous fallback the other providers use so a flaky network surfaces
    // a recoverable error instead of hanging the HUD.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 4.0

    private let streamId: String
    nonisolated(unsafe) private weak var agentClient: PickyAgentClient?
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: OpenAIRealtimeTranscriptionProvider.defaultSampleRate)
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private var aggregatedTranscript = ""
    private var observers: [NSObjectProtocol] = []
    private var didComplete = false

    init(
        streamId: String,
        agentClient: PickyAgentClient,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.streamId = streamId
        self.agentClient = agentClient
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        super.init()
        installNotificationObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !didComplete, let agentClient else { return }
        guard let data = converter.convertToPCM16Data(from: audioBuffer), !data.isEmpty else { return }
        let audioBase64 = data.base64EncodedString()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .appendTranscriptionAudio,
                    audioBase64: audioBase64,
                    streamId: self.streamId
                ))
            } catch {
                self.onError(error)
            }
        }
    }

    func requestFinalTranscript() {
        guard let agentClient else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .endTranscriptionStream,
                    streamId: self.streamId
                ))
            } catch {
                self.onError(error)
            }
        }
    }

    func cancel() {
        didComplete = true
        guard let agentClient else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await agentClient.send(PickyCommandEnvelope(
                type: .cancelTranscriptionStream,
                streamId: self.streamId
            ))
        }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .pickyTranscriptionDelta,
            .pickyTranscriptionCompleted,
            .pickyTranscriptionStreamFailed,
            .pickyTranscriptionStreamClosed,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                guard let info = note.userInfo, let id = info["streamId"] as? String, id == self.streamId else { return }
                Task { @MainActor in self.handleNotification(name: name, info: info) }
            }
            observers.append(token)
        }
    }

    private func handleNotification(name: Notification.Name, info: [AnyHashable: Any]) {
        switch name {
        case .pickyTranscriptionDelta:
            guard let delta = info["delta"] as? String, !delta.isEmpty else { return }
            aggregatedTranscript += delta
            onTranscriptUpdate(aggregatedTranscript)
        case .pickyTranscriptionCompleted:
            guard !didComplete else { return }
            didComplete = true
            let transcript = (info["transcript"] as? String) ?? aggregatedTranscript
            onFinalTranscriptReady(transcript)
        case .pickyTranscriptionStreamFailed:
            guard !didComplete else { return }
            didComplete = true
            let message = (info["message"] as? String) ?? "Transcription stream failed."
            onError(NSError(domain: "OpenAIRealtimeTranscriptionProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: message]))
        case .pickyTranscriptionStreamClosed:
            // Stream closure is observational only — the completed/failed
            // notification it always pairs with has already settled the
            // session above. Nothing extra to do here.
            break
        default:
            break
        }
    }
}

private extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}
