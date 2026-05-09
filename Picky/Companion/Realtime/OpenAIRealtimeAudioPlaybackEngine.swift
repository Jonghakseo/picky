//
//  OpenAIRealtimeAudioPlaybackEngine.swift
//  Picky
//
//  Streams PCM16 24kHz mono audio returned by the Realtime API. Kept separate
//  from PickySpeechPlaybackProvider so Realtime replies never trigger existing
//  local/Azure/ElevenLabs TTS side effects.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAIRealtimeAudioPlaybackEngine {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var isAttached = false

    private(set) var isPlaying = false

    func enqueuePCM16Base64(_ audioBase64: String) {
        guard let data = Data(base64Encoded: audioBase64), !data.isEmpty else { return }
        enqueuePCM16Data(data)
    }

    func enqueuePCM16Data(_ data: Data) {
        guard let buffer = makeBuffer(from: data) else { return }
        do {
            try ensureStarted()
        } catch {
            print("⚠️ Realtime playback start failed: \(error.localizedDescription)")
            return
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
        isPlaying = true
    }

    func stopAndReturnPlayedAudioMs() -> Double {
        let played = playedAudioMs
        stop()
        return played
    }

    func stop() {
        guard isPlaying || playerNode.isPlaying || audioEngine.isRunning else { return }
        playerNode.stop()
        audioEngine.stop()
        isPlaying = false
    }

    var playedAudioMs: Double {
        // AVAudioPlayerNode throws an Objective-C exception when `lastRenderTime`
        // is queried before the node has been attached to an engine. PTT can call
        // cancel/interrupt before any Realtime audio has ever been played, so guard
        // the attachment state first instead of relying on optional nil behavior.
        guard isAttached, audioEngine.isRunning else { return 0 }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate * 1_000)
    }

    private func ensureStarted() throws {
        if !isAttached {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            isAttached = true
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let destination = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
        data.withUnsafeBytes { rawBuffer in
            if let source = rawBuffer.baseAddress {
                destination.copyMemory(from: source, byteCount: frameCount * bytesPerFrame)
            }
        }
        return buffer
    }
}
