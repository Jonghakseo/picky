//
//  CompanionManager+TextContextCaptureEffect.swift
//  Picky
//

import Foundation

@MainActor
extension CompanionManager {
    func runCaptureTextContextEffect(inputID: UUID, text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let displayOverrides = screenContextDisplayOverridesByTextInputID
                .removeValue(forKey: inputID) ?? [:]
            do {
                let inkCapture = pendingInkCaptures.consume(for: inputID)
                guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                    transcript: text,
                    source: "text",
                    inkCapture: inkCapture,
                    displayOverrides: displayOverrides
                ) else {
                    interactionCoordinator.effectCompleted(
                        .textSubmissionFailed(
                            message: "Context capture returned no packet.",
                            inputID: inputID
                        ),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .text)
                    )
                    failDirectMessage(inputID: inputID, message: "Context capture returned no packet.")
                    return
                }
                interactionCoordinator.effectCompleted(
                    .textContextCaptured(inputID: inputID, context: captureResult.contextPacket),
                    correlation: PickyInteractionCorrelation(
                        inputID: inputID,
                        contextID: captureResult.contextPacket.id,
                        source: .text
                    )
                )
            } catch {
                let message = error.localizedDescription
                interactionCoordinator.effectCompleted(
                    .textSubmissionFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .text)
                )
                failDirectMessage(inputID: inputID, message: message)
            }
        }
    }
}
