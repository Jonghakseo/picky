//
//  PickyVoiceContextCapturePipeline.swift
//  Picky
//

import Foundation

/// Owns the PTT-scoped neutral context task lifecycle. It overlaps all
/// transcript-independent collection with transcription while keeping
/// cancellation and stale input protection keyed to the originating voice input.
@MainActor
final class PickyVoiceContextCapturePipeline {
    typealias ScreenShareableContentWarmup = @MainActor () async throws -> Void

    private let coordinator: PickyVoiceContextCaptureCoordinator
    private let isRunningUnitTests: () -> Bool
    private let screenShareableContentWarmup: ScreenShareableContentWarmup
    private var pendingTasks: [UUID: Task<PickyPreparedVoiceContextCapture?, Error>] = [:]
    private var pendingDisplayOverrides: [UUID: PickyScreenContextDisplayOverrides] = [:]
    private var inputStartedAt: Date?

    init(
        coordinator: PickyVoiceContextCaptureCoordinator,
        isRunningUnitTests: @escaping () -> Bool = { PickyRuntimeEnvironment.isRunningUnitTests },
        screenShareableContentWarmup: @escaping ScreenShareableContentWarmup = {
            _ = try await PickySystemPermissionGateway.shared.screenShareableContent()
        }
    ) {
        self.coordinator = coordinator
        self.isRunningUnitTests = isRunningUnitTests
        self.screenShareableContentWarmup = screenShareableContentWarmup
    }

    func beginInput() {
        cancelAll()
        inputStartedAt = Date()
        warmScreenShareableContent()
    }

    /// Starts transcript-independent capture only for a valid PTT recording.
    /// Returns ink to its caller when no prepared task was started so the
    /// synchronous fallback capture can preserve it if a transcript arrives.
    func finishInput(
        inputID: UUID,
        voiceFollowUpSessionID: String?,
        inkCapture: PickyInkCapture?,
        displayOverrides: PickyScreenContextDisplayOverrides = [:],
        stoppedAt: Date = Date()
    ) -> PickyInkCapture? {
        defer { inputStartedAt = nil }
        pendingTasks.removeValue(forKey: inputID)?.cancel()
        pendingDisplayOverrides[inputID] = displayOverrides
        guard let inputStartedAt,
              !BuddyDictationManager.shouldIgnoreRecording(startedAt: inputStartedAt, stoppedAt: stoppedAt) else {
            return inkCapture
        }
        let source = voiceFollowUpSessionID == nil ? "voice" : "voice-follow-up"
        let coordinator = coordinator
        pendingTasks[inputID] = Task { @MainActor in
            try await coordinator.prepareContext(
                source: source,
                inkCapture: inkCapture,
                displayOverrides: displayOverrides
            )
        }
        return nil
    }

    func clearInputTiming() {
        inputStartedAt = nil
    }

    func cancel(inputID: UUID) {
        pendingTasks.removeValue(forKey: inputID)?.cancel()
        pendingDisplayOverrides.removeValue(forKey: inputID)
    }

    func cancelAll() {
        for task in pendingTasks.values {
            task.cancel()
        }
        pendingTasks.removeAll()
        pendingDisplayOverrides.removeAll()
        inputStartedAt = nil
    }

    func captureContext(
        inputID: UUID,
        transcript: String,
        voiceFollowUpSessionID: String?,
        fallbackInkCapture: PickyInkCapture?
    ) async throws -> PickyVoiceContextCaptureResult? {
        let displayOverrides = pendingDisplayOverrides.removeValue(forKey: inputID) ?? [:]
        if let preparedTask = pendingTasks.removeValue(forKey: inputID) {
            let joinStartedAt = Date()
            guard let prepared = try await preparedTask.value else { return nil }
            let joinWaitMilliseconds = Int(Date().timeIntervalSince(joinStartedAt) * 1_000)
            PickyLog.notice(
                .latency,
                prefix: "⏱️ Picky latency —",
                message: "event=captureJoinWaitMs inputID=\(inputID) "
                    + "source=\(prepared.source) ms=\(joinWaitMilliseconds)"
            )
            return try await coordinator.assembleContext(prepared, transcript: transcript)
        }

        return try await coordinator.captureContext(
            transcript: transcript,
            voiceFollowUpSessionID: voiceFollowUpSessionID,
            inkCapture: fallbackInkCapture,
            displayOverrides: displayOverrides
        )
    }

    private func warmScreenShareableContent() {
        // ScreenCaptureKit's first content enumeration is noticeably slower.
        // Do not create a Task in unit tests: even content enumeration can
        // prompt for Screen Recording access on macOS.
        guard !isRunningUnitTests() else { return }

        let screenShareableContentWarmup = screenShareableContentWarmup
        Task {
            do {
                try await screenShareableContentWarmup()
            } catch {
                PickyLog.notice(
                    .permission,
                    prefix: "🔐 Picky permission —",
                    message: "capability=screenContent warmupFailed=true error=\(error.localizedDescription)"
                )
            }
        }
    }
}
