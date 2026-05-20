//
//  OpenAIRealtimeVoiceInputManager.swift
//  Picky
//
//  Main-agent-only microphone streaming for OpenAI/Azure OpenAI Realtime.
//  This class is intentionally separate from BuddyDictationManager so the
//  existing Pi STT -> Picky/Pickle flow remains untouched unless the user opts
//  into the Realtime main runtime and the utterance is not a Pickle-hover follow-up.
//

import AVFoundation
import Foundation
import os

enum PickyRealtimeVoiceInputError: Error, LocalizedError {
    case installTapFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .installTapFailed(let reason): return reason
        }
    }
}

@MainActor
final class OpenAIRealtimeVoiceInputManager {
    private static let log = Logger(subsystem: "com.jonghakseo.picky", category: "realtime-voice-input")

    private let audioEngine = AVAudioEngine()
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)
    private var onAudioChunk: ((Data) -> Void)?
    private(set) var activeInputID: UUID?

    private(set) var isRecording = false

    /// Holds the NotificationCenter token for the engine-configuration-change
    /// observer so we can rebuild the input tap when CoreAudio swaps the input
    /// hardware out from under us (e.g. Bluetooth A2DP -> HFP, AirPods mic
    /// activation, USB device hot-swap). Without this, the engine auto-stops
    /// silently after a route change and audio chunks dry up.
    private var configurationChangeObserver: NSObjectProtocol?

    deinit {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(inputID: UUID, onAudioChunk: @escaping (Data) -> Void) throws {
        stop()
        activeInputID = inputID
        self.onAudioChunk = onAudioChunk

        try installInputTapAndStartEngine()
        observeEngineConfigurationChanges()
        isRecording = true
    }

    func stop() {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        guard isRecording || audioEngine.isRunning || activeInputID != nil else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        onAudioChunk = nil
        activeInputID = nil
        isRecording = false
    }

    /// Installs the input tap and starts the engine. Centralized so the
    /// configuration-change observer can rebuild the graph on route changes
    /// without duplicating logic.
    ///
    /// Three defensive layers protect against the AVFAudio crash where the
    /// input hardware (BT HFP @ 24 kHz) doesn't match the engine's cached
    /// client format (48 kHz):
    ///   1. Call `prepare()` BEFORE reading the format so AVAudioEngine has
    ///      negotiated with the HAL.
    ///   2. Snapshot `inputNode.outputFormat(forBus: 0)` after prepare; this
    ///      is what the tap must receive to avoid the "format mismatch"
    ///      NSException.
    ///   3. Wrap `installTap` in `PickyTrapObjCException` so any residual
    ///      Obj-C exception (race with a concurrent route change) surfaces
    ///      as a Swift error the caller can recover from instead of
    ///      terminating the app.
    private func installInputTapAndStartEngine() throws {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        audioEngine.prepare()
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PickyRealtimeVoiceInputError.installTapFailed(
                reason: "Input node reported an invalid format after prepare (sampleRate=\(format.sampleRate), channels=\(format.channelCount))."
            )
        }

        var trapError: NSError?
        let installed = PickyTrapObjCException({
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                guard let data = self.converter.convertToPCM16Data(from: buffer), !data.isEmpty else { return }
                self.onAudioChunk?(data)
            }
        }, &trapError)
        if !installed {
            let reason = trapError?.localizedDescription ?? "installTap raised an unknown NSException"
            Self.log.error("Realtime voice input installTap failed: \(reason, privacy: .public)")
            throw PickyRealtimeVoiceInputError.installTapFailed(reason: reason)
        }

        try audioEngine.start()
    }

    private func observeEngineConfigurationChanges() {
        if let existing = configurationChangeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            // Notification fires on .main per the queue argument; hop onto the
            // MainActor for any property access.
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        }
    }

    private func handleEngineConfigurationChange() {
        guard isRecording else { return }
        Self.log.notice("AVAudioEngine configuration changed; reinstalling realtime input tap.")
        // AVAudioEngine auto-stops on configuration change. Tear the tap down
        // and bring it back up so audio chunks keep flowing without surfacing
        // the route change to the user.
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        do {
            try installInputTapAndStartEngine()
        } catch {
            Self.log.error("Failed to rebuild realtime input tap after configuration change: \(error.localizedDescription, privacy: .public)")
            isRecording = false
            onAudioChunk = nil
            activeInputID = nil
        }
    }
}
