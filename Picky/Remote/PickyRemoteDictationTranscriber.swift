//
//  PickyRemoteDictationTranscriber.swift
//  Picky
//
//  Runs a phone recording through the Mac's configured speech service.
//  The phone has no transcription of its own in the PWA, so the recording is
//  uploaded, transcribed here, and the file is deleted immediately after.
//
//  This path must never prompt for a macOS permission: a dialog nobody is
//  sitting in front of would hang the phone until it times out.
//

import AVFoundation
import Foundation
import Speech

/// Decision about whether the Mac can transcribe right now, shared by the
/// `hub.config` payload and the transcribe request itself so the phone never
/// offers a button that is guaranteed to fail.
enum PickyRemoteDictationReadiness: Equatable {
    case ready
    case needsPermission
    case serviceNotConfigured
    case unavailable

    var availability: PickyRemoteDictationAvailability {
        switch self {
        case .ready: .availableNow
        case .needsPermission: .unavailable(.macPermission)
        case .serviceNotConfigured: .unavailable(.macService)
        case .unavailable: .unavailable(.macUnavailable)
        }
    }

    var errorCode: String? {
        switch self {
        case .ready: nil
        case .needsPermission: PickyRemoteHubErrorCode.macPermission
        case .serviceNotConfigured: PickyRemoteHubErrorCode.macService
        case .unavailable: PickyRemoteHubErrorCode.macUnavailable
        }
    }

    /// Pure policy so the availability rules stay testable without a provider.
    static func evaluate(
        isConfigured: Bool,
        requiresSpeechRecognitionPermission: Bool,
        speechAuthorizationStatus: SFSpeechRecognizerAuthorizationStatus
    ) -> PickyRemoteDictationReadiness {
        guard isConfigured else { return .serviceNotConfigured }
        guard requiresSpeechRecognitionPermission else { return .ready }
        switch speechAuthorizationStatus {
        case .authorized: return .ready
        // `.notDetermined` is a permission problem from the phone's point of
        // view: granting it needs someone at the Mac, and asking from here
        // would raise a dialog on an unattended desktop.
        case .notDetermined, .denied, .restricted: return .needsPermission
        @unknown default: return .needsPermission
        }
    }
}

@MainActor
final class PickyRemoteDictationTranscriber: PickyRemoteDictationTranscribing {
    /// Generous enough for a long voice memo, short enough that a stuck
    /// recognizer does not pin the phone's composer forever.
    private static let finalTranscriptTimeout: TimeInterval = 120
    private static let bufferFrames: AVAudioFrameCount = 8192

    private let settingsProvider: () -> PickySettings
    private let providerFactory: (PickySettings) -> any BuddyTranscriptionProvider
    private let authorizationStatusProvider: () -> SFSpeechRecognizerAuthorizationStatus
    private let fileManager: FileManager

    init(
        settingsProvider: @escaping () -> PickySettings = { PickySettingsStore().load() },
        providerFactory: @escaping (PickySettings) -> any BuddyTranscriptionProvider = {
            BuddyTranscriptionProviderFactory.makeDefaultProvider(settings: $0)
        },
        authorizationStatusProvider: @escaping () -> SFSpeechRecognizerAuthorizationStatus = {
            SFSpeechRecognizer.authorizationStatus()
        },
        fileManager: FileManager = .default
    ) {
        self.settingsProvider = settingsProvider
        self.providerFactory = providerFactory
        self.authorizationStatusProvider = authorizationStatusProvider
        self.fileManager = fileManager
    }

    /// Availability reported to the phone through `hub.config`.
    func readiness() -> PickyRemoteDictationReadiness {
        let provider = providerFactory(settingsProvider())
        return PickyRemoteDictationReadiness.evaluate(
            isConfigured: provider.isConfigured,
            requiresSpeechRecognitionPermission: provider.requiresSpeechRecognitionPermission,
            speechAuthorizationStatus: authorizationStatusProvider()
        )
    }

    func transcribe(filePath: String, mime: String) async throws -> String {
        let url = URL(fileURLWithPath: filePath)
        defer { try? fileManager.removeItem(at: url) }

        let provider = providerFactory(settingsProvider())
        let readiness = PickyRemoteDictationReadiness.evaluate(
            isConfigured: provider.isConfigured,
            requiresSpeechRecognitionPermission: provider.requiresSpeechRecognitionPermission,
            speechAuthorizationStatus: authorizationStatusProvider()
        )
        if let code = readiness.errorCode {
            throw PickyRemoteHubError(code: code, message: provider.unavailableExplanation ?? L10n.t("settings.remote.error.dictationUnavailable"))
        }

        let buffers = try readBuffers(at: url)
        guard !buffers.isEmpty else {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.noSpeech,
                message: L10n.t("settings.remote.error.dictationNoSpeech")
            )
        }

        let transcript = try await runSession(provider: provider, buffers: buffers)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.noSpeech,
                message: L10n.t("settings.remote.error.dictationNoSpeech")
            )
        }
        return trimmed
    }

    private func readBuffers(at url: URL) throws -> [AVAudioPCMBuffer] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.failed,
                message: L10n.t("settings.remote.error.dictationUnreadable")
            )
        }
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.bufferFrames) else { break }
            do {
                try file.read(into: buffer)
            } catch {
                throw PickyRemoteHubError(
                    code: PickyRemoteHubErrorCode.failed,
                    message: L10n.t("settings.remote.error.dictationUnreadable")
                )
            }
            guard buffer.frameLength > 0 else { break }
            buffers.append(buffer)
        }
        return buffers
    }

    private func runSession(provider: any BuddyTranscriptionProvider, buffers: [AVAudioPCMBuffer]) async throws -> String {
        let mailbox = PickyRemoteTranscriptMailbox()
        let session = try await provider.startStreamingSession(
            keyterms: [],
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { text in
                Task { @MainActor in mailbox.deliver(.text(text)) }
            },
            onError: { error in
                let message = error.localizedDescription
                Task { @MainActor in mailbox.deliver(.failure(message)) }
            }
        )
        for buffer in buffers {
            session.appendAudioBuffer(buffer)
        }
        session.requestFinalTranscript()

        let result = await mailbox.wait(timeout: Self.finalTranscriptTimeout)
        switch result {
        case .text(let text):
            return text
        case .failure(let message):
            session.cancel()
            throw PickyRemoteHubError(code: PickyRemoteHubErrorCode.failed, message: message)
        case .none:
            session.cancel()
            throw PickyRemoteHubError(
                code: PickyRemoteHubErrorCode.failed,
                message: L10n.t("settings.remote.error.dictationTimedOut")
            )
        }
    }
}

/// One-shot delivery box. Provider callbacks can fire on any thread and may
/// fire more than once; only the first result is kept.
@MainActor
private final class PickyRemoteTranscriptMailbox {
    enum Outcome: Equatable {
        case text(String)
        case failure(String)
    }

    private var result: Outcome?
    private var waiter: CheckedContinuation<Void, Never>?

    func deliver(_ value: Outcome) {
        guard result == nil else { return }
        result = value
        waiter?.resume()
        waiter = nil
    }

    func wait(timeout: TimeInterval) async -> Outcome? {
        if let result { return result }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timedOut()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if result != nil {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
        timeoutTask.cancel()
        return result
    }

    private func timedOut() {
        guard result == nil else { return }
        waiter?.resume()
        waiter = nil
    }
}
