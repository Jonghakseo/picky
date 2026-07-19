//
//  PickyVoiceContextCapturePipeline.swift
//  Picky
//

import Foundation
import ScreenCaptureKit

/// Owns the PTT-scoped screen capture task lifecycle. It overlaps neutral
/// screen capture with transcription while keeping cancellation and stale input
/// protection keyed to the originating voice input.
@MainActor
final class PickyVoiceContextCapturePipeline {
    private let coordinator: PickyVoiceContextCaptureCoordinator
    private var pendingTasks: [UUID: Task<PickyPreparedVoiceContextCapture?, Error>] = [:]
    private var inputStartedAt: Date?

    init(coordinator: PickyVoiceContextCaptureCoordinator) {
        self.coordinator = coordinator
    }

    func beginInput() {
        cancelAll()
        inputStartedAt = Date()
        warmScreenShareableContent()
    }

    /// Starts the screen portion of capture only for a valid PTT recording.
    /// Returns ink to its caller when no prepared task was started so the
    /// synchronous fallback capture can preserve it if a transcript arrives.
    func finishInput(
        inputID: UUID,
        voiceFollowUpSessionID: String?,
        inkCapture: PickyInkCapture?,
        stoppedAt: Date = Date()
    ) -> PickyInkCapture? {
        defer { inputStartedAt = nil }
        guard let inputStartedAt,
              !BuddyDictationManager.shouldIgnoreRecording(startedAt: inputStartedAt, stoppedAt: stoppedAt) else {
            cancel(inputID: inputID)
            return inkCapture
        }

        cancel(inputID: inputID)
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        let coordinator = coordinator
        pendingTasks[inputID] = Task { @MainActor in
            try await coordinator.prepareContext(source: source, inkCapture: inkCapture)
        }
        return nil
    }

    func clearInputTiming() {
        inputStartedAt = nil
    }

    func cancel(inputID: UUID) {
        pendingTasks.removeValue(forKey: inputID)?.cancel()
    }

    func cancelAll() {
        for task in pendingTasks.values {
            task.cancel()
        }
        pendingTasks.removeAll()
        inputStartedAt = nil
    }

    func captureContext(
        inputID: UUID,
        transcript: String,
        voiceFollowUpSessionID: String?,
        fallbackInkCapture: PickyInkCapture?
    ) async throws -> PickyVoiceContextCaptureResult? {
        if let preparedTask = pendingTasks.removeValue(forKey: inputID) {
            let joinStartedAt = Date()
            guard let prepared = try await preparedTask.value else { return nil }
            let joinWaitMilliseconds = Int(Date().timeIntervalSince(joinStartedAt) * 1_000)
            PickyLog.notice(
                .latency,
                prefix: "⏱️ Picky latency —",
                message: "event=captureJoinWaitMs inputID=\(inputID) source=\(prepared.source) ms=\(joinWaitMilliseconds)"
            )
            return try await coordinator.assembleContext(prepared, transcript: transcript)
        }

        return try await coordinator.captureContext(
            transcript: transcript,
            voiceFollowUpSessionID: voiceFollowUpSessionID,
            inkCapture: fallbackInkCapture
        )
    }

    private func warmScreenShareableContent() {
        // ScreenCaptureKit's first content enumeration is noticeably slower.
        // The result is intentionally discarded while PTT is held, and
        // permission failures remain non-fatal.
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }
}
