//
//  OpenAIRealtimeVoiceInputManager.swift
//  Picky
//
//  Main-agent-only microphone streaming for OpenAI/Azure OpenAI Realtime.
//  This class is intentionally separate from BuddyDictationManager so the
//  existing Pi STT -> Pi main/side flow remains untouched unless the user opts
//  into the Realtime main runtime and the utterance is not a side-hover follow-up.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAIRealtimeVoiceInputManager {
    private let audioEngine = AVAudioEngine()
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 24_000)
    private var onAudioChunk: ((Data) -> Void)?
    private(set) var activeInputID: UUID?

    private(set) var isRecording = false

    func start(inputID: UUID, onAudioChunk: @escaping (Data) -> Void) throws {
        stop()
        activeInputID = inputID
        self.onAudioChunk = onAudioChunk

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let data = self.converter.convertToPCM16Data(from: buffer), !data.isEmpty else { return }
            self.onAudioChunk?(data)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording || audioEngine.isRunning || activeInputID != nil else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        onAudioChunk = nil
        activeInputID = nil
        isRecording = false
    }
}
