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
protocol PickyRealtimeAudioPlaybacking: AnyObject {
    var isPlaying: Bool { get }
    var playedAudioMs: Double { get }
    var onPlaybackDrained: (() -> Void)? { get set }

    func enqueuePCM16Base64(_ audioBase64: String)
    func stopAndReturnPlayedAudioMs() -> Double
    func stop()
}

enum PickyRealtimePCM16Audio {
    static let sampleRate: Double = 24_000
    static let channelCount: AVAudioChannelCount = 1
    static let bytesPerSample = MemoryLayout<Int16>.size

    static let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channelCount
    )!

    static func makePlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / bytesPerSample
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destination = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<frameCount {
                let byteOffset = index * bytesPerSample
                let low = UInt16(bytes[byteOffset])
                let high = UInt16(bytes[byteOffset + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                destination[index] = Float(sample) / 32_768.0
            }
        }
        return buffer
    }
}

@MainActor
final class OpenAIRealtimeAudioPlaybackEngine: PickyRealtimeAudioPlaybacking {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format = PickyRealtimePCM16Audio.playbackFormat
    private var isAttached = false
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    // playerTime.sampleTime is cumulative since the AVAudioPlayerNode was
    // first attached, NOT the playback offset of the current response. We
    // capture the sampleTime at the moment a fresh assistant audio item
    // starts streaming so playedAudioMs reflects "ms played within this
    // item". Without this, the value reported "ms the engine has been
    // alive" (we observed ~19 minutes during idle time between turns),
    // which then got sent to OpenAI Realtime as a hugely-inflated
    // conversation.item.truncate.audio_end_ms on cancel.
    private var sampleTimeBaseline: AVAudioFramePosition = 0

    private(set) var isPlaying = false
    var onPlaybackDrained: (() -> Void)?

    func enqueuePCM16Base64(_ audioBase64: String) {
        guard let data = Data(base64Encoded: audioBase64), !data.isEmpty else { return }
        enqueuePCM16Data(data)
    }

    func enqueuePCM16Data(_ data: Data) {
        guard let buffer = PickyRealtimePCM16Audio.makePlaybackBuffer(from: data) else { return }
        do {
            try ensureStarted()
        } catch {
            print("⚠️ Realtime playback start failed: \(error.localizedDescription)")
            markPlaybackDrained()
            return
        }
        // First buffer of a fresh assistant audio item. Capture where the
        // player's sampleTime is right now so subsequent playedAudioMs
        // readings are relative to THIS item.
        if !isPlaying {
            captureSampleTimeBaseline()
        }
        let generation = playbackGeneration
        pendingBuffers += 1
        isPlaying = true
        // Use `.dataPlayedBack` so the completion fires only after the audio
        // has actually been rendered through the output device. The default
        // single-argument `scheduleBuffer(_:completionHandler:)` uses
        // `.dataConsumed`, which fires as soon as the player has accepted
        // the buffer for processing - well before the user hears the
        // samples. With the default callback the last buffer reported
        // "drained" several hundred milliseconds early, which let
        // handleRealtimePlaybackDrained run while audio was still playing
        // and the assistant bubble disappeared mid-speech.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish(generation: generation)
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    func stopAndReturnPlayedAudioMs() -> Double {
        let played = playedAudioMs
        stop()
        return played
    }

    func stop() {
        playbackGeneration += 1
        pendingBuffers = 0
        guard isPlaying || playerNode.isPlaying || audioEngine.isRunning else {
            isPlaying = false
            return
        }
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
        // playerTime.sampleTime is cumulative across the player's lifetime;
        // subtract the baseline captured when this assistant audio item
        // began so we return only the time spent playing THIS item.
        let elapsedSamples = max(0, playerTime.sampleTime - sampleTimeBaseline)
        return Double(elapsedSamples) / playerTime.sampleRate * 1_000
    }

    private func ensureStarted() throws {
        if !isAttached {
            audioEngine.attach(playerNode)
            // Feed AVAudioPlayerNode a standard Float32 playback format. Connecting
            // the Realtime API's raw PCM16 format directly to the main mixer throws
            // AVAudioEngine error -10868 on macOS, which surfaces as an Obj-C
            // exception and terminates Picky before any audio can be heard.
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            isAttached = true
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func captureSampleTimeBaseline() {
        guard isAttached, audioEngine.isRunning,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            // Either the engine just started (no lastRenderTime yet) or the
            // node isn't attached. Reset to 0 so the first samples played by
            // this item are counted from the very beginning.
            sampleTimeBaseline = 0
            return
        }
        sampleTimeBaseline = playerTime.sampleTime
    }

    private func bufferDidFinish(generation: Int) {
        guard generation == playbackGeneration else { return }
        if pendingBuffers > 0 { pendingBuffers -= 1 }
        if pendingBuffers == 0 {
            markPlaybackDrained()
        }
    }

    private func markPlaybackDrained() {
        guard isPlaying || pendingBuffers == 0 else { return }
        isPlaying = false
        onPlaybackDrained?()
    }
}
