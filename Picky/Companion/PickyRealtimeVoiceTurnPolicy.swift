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
        shouldUseRealtimeMainVoiceTurn(targetSessionID: targetSessionID, runtimeMode: runtimeMode)
            ? .realtime
            : .standard
    }

    private static func normalizedTargetSessionID(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
