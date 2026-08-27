//
//  CompanionManager+VoiceContextCaptureEffect.swift
//  Picky
//

import Foundation

@MainActor
extension CompanionManager {
    /// Joins the PTT-release capture with the final transcript, then reports the
    /// result to the existing interaction reducer. The pipeline owns pending
    /// task state; CompanionManager remains the UI and routing state owner.
    func runCaptureVoiceContextEffect(inputID: UUID, transcript: String, targetSessionID: String?) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let captureResult = try await voiceContextCapturePipeline.captureContext(
                    inputID: inputID,
                    transcript: transcript,
                    voiceFollowUpSessionID: targetSessionID,
                    fallbackInkCapture: pendingInkCaptures.consume(for: inputID)
                )
                guard let captureResult else {
                    guard !Task.isCancelled else {
                        finishCancelledVoiceEffect(inputID: inputID)
                        return
                    }
                    let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
                    interactionCoordinator.effectCompleted(
                        .transcriptFailed(message: "Context capture returned no packet.", inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                    )
                    if completeVoiceInteractionIfCurrent(inputID: inputID) {
                        clearScreenContextTargetIfCurrent(targetSnapshot)
                        setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                    }
                    return
                }
                guard !Task.isCancelled, !invalidatedVoiceInputIDs.contains(inputID) else {
                    finishCancelledVoiceEffect(inputID: inputID)
                    return
                }
                interactionCoordinator.effectCompleted(
                    .voiceContextCaptured(
                        inputID: inputID,
                        transcript: transcript,
                        context: captureResult.contextPacket,
                        targetSessionID: targetSessionID
                    ),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: captureResult.contextPacket.id, source: .voice)
                )
            } catch is CancellationError {
                finishCancelledVoiceEffect(inputID: inputID)
                // User spoke again — response was interrupted.
            } catch {
                let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
                let message = error.localizedDescription
                PickyAnalytics.trackResponseError(error: message)
                print("⚠️ Picky context capture error: \(error)")
                interactionCoordinator.effectCompleted(
                    .transcriptFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                )
                if completeVoiceInteractionIfCurrent(inputID: inputID) {
                    finishAwaitingAgentResponse(
                        visibleText: "I captured that, but the local agent client is not ready yet.",
                        spokenText: "I captured that, but the local agent client is not ready yet."
                    )
                    clearScreenContextTargetIfCurrent(targetSnapshot)
                    setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                }
            }
        }
    }

    /// Releases the snapshot for a cancelled effect. Removal tombstones stay
    /// alive until that effect settles, then are consumed exactly once here.
    func finishCancelledVoiceEffect(inputID: UUID) {
        voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
        guard invalidatedVoiceInputIDs.contains(inputID) else { return }
        _ = completeVoiceInteractionIfCurrent(inputID: inputID)
    }


}
