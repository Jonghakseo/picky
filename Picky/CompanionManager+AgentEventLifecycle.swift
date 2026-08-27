//
//  CompanionManager+AgentEventLifecycle.swift
//  Picky
//
//  Agent event binding and authoritative projection target invalidation.
//

import Foundation

extension CompanionManager {
    func bindAgentEvents() {
        agentEventTask?.cancel()
        agentEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in agentClient.events {
                switch event {
                case .protocolEvent(let envelope):
                    await MainActor.run { self.applyAgentEvent(envelope.event) }
                case .recoverableError(let message):
                    await MainActor.run { self.finishAwaitingAgentResponse(visibleText: "Agent event error: \(message)", spokenText: nil) }
                case .disconnected:
                    await MainActor.run { self.handleAgentClientDisconnected() }
                case .connected:
                    await MainActor.run {
                        self.latestAgentSessionSummary = "picky-agentd connected"
                        self.syncDaemonSettings()
                    }
                    try? await self.agentClient.send(PickyCommandEnvelope(type: .listMainMessages))
                    try? await self.agentClient.send(PickyCommandEnvelope(type: .listMainAgentModels))
                case .sessionProjectionBootstrapCompletion:
                    await MainActor.run { self.applyAgentClientEvent(event) }
                }
            }
        }
    }

    /// Consumes router-validated client events owned by CompanionManager.
    /// The router has already correlated the v2 bootstrap completion, so the
    /// removed IDs are authoritative and safe to use for voice invalidation.
    func applyAgentClientEvent(_ event: PickyClientEvent) {
        guard case .sessionProjectionBootstrapCompletion(let removedSessionIDs, _) = event else { return }
        invalidateVoiceTargets(removedSessionIDs: removedSessionIDs)
    }

    private func invalidateVoiceTargets(removedSessionIDs: Set<String>) {
        guard !removedSessionIDs.isEmpty else { return }
        let invalidatedInputIDs = voiceInputTargetSnapshotsByInputID.compactMap { inputID, snapshot in
            removedSessionIDs.contains(snapshot.sessionID ?? "") ? inputID : nil
        }
        guard !invalidatedInputIDs.isEmpty else {
            clearRemovedVoiceTarget(removedSessionIDs)
            return
        }

        for inputID in invalidatedInputIDs {
            voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
            invalidatedVoiceInputIDs.insert(inputID)
            voiceContextCapturePipeline.cancel(inputID: inputID)
            interactionCoordinator.accept(
                .transcriptFailed(message: L10n.t("error.voice.targetRemoved"), inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .agent)
            )
        }

        clearRemovedVoiceTarget(removedSessionIDs)
        if let interactionVoiceInputID, invalidatedVoiceInputIDs.contains(interactionVoiceInputID) {
            currentResponseTask?.cancel()
            finishAwaitingAgentResponse(visibleText: L10n.t("error.voice.targetRemoved"), spokenText: nil)
        }
    }

    private func clearRemovedVoiceTarget(_ removedSessionIDs: Set<String>) {
        if let targetSessionID = voiceFollowUpSessionIDForCurrentUtterance,
           removedSessionIDs.contains(targetSessionID) {
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "projection-removal")
        }
        if let targetSessionID = selectionStore.screenContextTargetSessionID,
           removedSessionIDs.contains(targetSessionID) {
            applyScreenContextTarget(nil)
        }
    }
}
