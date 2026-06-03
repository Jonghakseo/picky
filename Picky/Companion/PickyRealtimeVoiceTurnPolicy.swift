//
//  PickyRealtimeVoiceTurnPolicy.swift
//  Picky
//
//  Pure decision policy for when PTT should use the main-agent Realtime path.
//

enum PickyRealtimeVoiceTurnPolicy {
    static func shouldUseRealtimeMainVoiceTurn(
        targetSessionID: String?,
        runtimeMode: PickyMainAgentRuntimeMode
    ) -> Bool {
        guard normalizedTargetSessionID(targetSessionID) == nil else { return false }
        return runtimeMode == .openAIRealtime
    }

    static func mode(
        targetSessionID: String?,
        runtimeMode: PickyMainAgentRuntimeMode
    ) -> PickyVoiceInteractionMode {
        currentMode(
            realtimeInputIsActive: false,
            targetSessionID: targetSessionID,
            runtimeMode: runtimeMode
        )
    }

    static func currentMode(
        realtimeInputIsActive: Bool,
        targetSessionID: String?,
        runtimeMode: PickyMainAgentRuntimeMode
    ) -> PickyVoiceInteractionMode {
        if realtimeInputIsActive { return .realtime }
        return shouldUseRealtimeMainVoiceTurn(targetSessionID: targetSessionID, runtimeMode: runtimeMode)
            ? .realtime
            : .standard
    }

    private static func normalizedTargetSessionID(_ sessionID: String?) -> String? {
        PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(sessionID)
    }
}
