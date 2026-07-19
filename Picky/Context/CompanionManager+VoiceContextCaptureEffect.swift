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
                    guard !Task.isCancelled else { return }
                    screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
                    interactionCoordinator.effectCompleted(
                        .transcriptFailed(message: "Context capture returned no packet.", inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                    )
                    if completeVoiceInteractionIfCurrent(inputID: inputID) {
                        clearScreenContextTargetIfCurrent(targetSessionID)
                        setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                    }
                    return
                }
                guard !Task.isCancelled else { return }
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
                screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
                // User spoke again — response was interrupted.
            } catch {
                screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
                let message = error.localizedDescription
                PickyAnalytics.trackResponseError(error: message)
                print("⚠️ Picky context capture error: \(error)")
                interactionCoordinator.effectCompleted(
                    .transcriptFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                )
                finishAwaitingAgentResponse(
                    visibleText: "I captured that, but the local agent client is not ready yet.",
                    spokenText: "I captured that, but the local agent client is not ready yet."
                )
                completeVoiceInteractionIfCurrent(inputID: inputID)
            }
        }
    }
}
