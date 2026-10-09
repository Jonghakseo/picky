//
//  PickyDebugAppSnapshot.swift
//  Picky
//
//  Read-only answer to `picky-debug app snapshot`. Field selection is an
//  allowlist: phases, counts, correlation identifiers, and capability flags.
//  No transcripts, reply text, window titles, file paths, or tokens.
//

import Foundation

struct PickyDebugAppSnapshot: Equatable {
    static let schemaVersion = 1

    /// Changes on every app launch, so a reader can tell a restart from a gap.
    var instanceId: String
    var capturedAt: Date
    var monotonicMs: Double

    // Interaction reducer phases.
    var inputPhase: String
    var outputPhase: String
    var overlayPhase: String
    var interactionSequence: UInt64
    var pendingTextInputCount: Int
    var pendingVoiceInputCount: Int
    var trackedContextCount: Int
    var queuedSpeechCount: Int

    // Correlation identifiers currently in play.
    var activeInputId: String?
    var activeContextId: String?
    var activeSpeechId: String?
    var armedSessionId: String?
    var selectedSessionId: String?

    // Voice / dictation surface.
    var voiceState: String
    var voicePhase: String
    var pushToTalkHeld: Bool
    var dictationInProgress: Bool
    var dictationFinalizing: Bool

    // Capability availability. These describe whether an input path can run at
    // all; they are not proof that a turn completed.
    var transcriptionProviderConfigured: Bool
    var ttsPlaybackEnabled: Bool
    /// True when the snapshot was produced by a live app connected to the
    /// daemon. It proves the request channel, not that a turn can complete.
    var daemonChannelAvailable: Bool
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
    var microphoneGranted: Bool
    var screenContentGranted: Bool

    // Composer / submission surface.
    var sendingDirectMessage: Bool
    var waitingForCursorResponse: Bool
    var quickInputPanelVisible: Bool

    // Trace buffer health. `droppedCount` counts records that never reached the
    // daemon, from queue eviction and from refused publishes alike; a refused
    // publish leaves no daemon sequence gap to notice it by.
    var tracePendingCount: Int
    var tracePendingCapacity: Int
    var traceRecordedCount: Int
    var traceDroppedCount: Int
    var traceTransportFailureCount: Int

    var jsonValue: JSONValue {
        var fields: [String: JSONValue] = [
            "schemaVersion": .number(Double(Self.schemaVersion)),
            "instanceId": .string(instanceId),
            "capturedAt": .string(PickyDebugTraceClock.iso8601.string(from: capturedAt)),
            "monotonicMs": .number(monotonicMs.isFinite ? max(0, monotonicMs) : 0),
            "interaction": .object([
                "inputPhase": .string(inputPhase),
                "outputPhase": .string(outputPhase),
                "overlayPhase": .string(overlayPhase),
                "sequence": .number(Double(interactionSequence)),
                "pendingTextInputCount": .number(Double(pendingTextInputCount)),
                "pendingVoiceInputCount": .number(Double(pendingVoiceInputCount)),
                "trackedContextCount": .number(Double(trackedContextCount)),
                "queuedSpeechCount": .number(Double(queuedSpeechCount)),
            ]),
            "voice": .object([
                "state": .string(voiceState),
                "phase": .string(voicePhase),
                "pushToTalkHeld": .bool(pushToTalkHeld),
                "dictationInProgress": .bool(dictationInProgress),
                "dictationFinalizing": .bool(dictationFinalizing),
            ]),
            "submission": .object([
                "sendingDirectMessage": .bool(sendingDirectMessage),
                "waitingForCursorResponse": .bool(waitingForCursorResponse),
                "quickInputPanelVisible": .bool(quickInputPanelVisible),
            ]),
            "availability": .object([
                "transcriptionProviderConfigured": .bool(transcriptionProviderConfigured),
                "ttsPlaybackEnabled": .bool(ttsPlaybackEnabled),
                "daemonChannelAvailable": .bool(daemonChannelAvailable),
                "accessibilityGranted": .bool(accessibilityGranted),
                "screenRecordingGranted": .bool(screenRecordingGranted),
                "microphoneGranted": .bool(microphoneGranted),
                "screenContentGranted": .bool(screenContentGranted),
            ]),
            "trace": .object([
                "pendingCount": .number(Double(tracePendingCount)),
                "pendingCapacity": .number(Double(tracePendingCapacity)),
                "recordedCount": .number(Double(traceRecordedCount)),
                "droppedCount": .number(Double(traceDroppedCount)),
                "transportFailureCount": .number(Double(traceTransportFailureCount)),
            ]),
        ]
        fields["identifiers"] = .object([
            "activeInputId": activeInputId.map(JSONValue.string) ?? .null,
            "activeContextId": activeContextId.map(JSONValue.string) ?? .null,
            "activeSpeechId": activeSpeechId.map(JSONValue.string) ?? .null,
            "armedSessionId": armedSessionId.map(JSONValue.string) ?? .null,
            "selectedSessionId": selectedSessionId.map(JSONValue.string) ?? .null,
        ])
        return .object(fields)
    }

    /// Returned when the app delegate has already been torn down. Keeping the
    /// schema intact is better than failing the read: the caller can still see
    /// that nothing is available.
    static let unavailable = PickyDebugAppSnapshot(
        instanceId: "unavailable",
        capturedAt: Date(timeIntervalSince1970: 0),
        monotonicMs: 0,
        inputPhase: "unavailable",
        outputPhase: "unavailable",
        overlayPhase: "unavailable",
        interactionSequence: 0,
        pendingTextInputCount: 0,
        pendingVoiceInputCount: 0,
        trackedContextCount: 0,
        queuedSpeechCount: 0,
        activeInputId: nil,
        activeContextId: nil,
        activeSpeechId: nil,
        armedSessionId: nil,
        selectedSessionId: nil,
        voiceState: "unavailable",
        voicePhase: "unavailable",
        pushToTalkHeld: false,
        dictationInProgress: false,
        dictationFinalizing: false,
        transcriptionProviderConfigured: false,
        ttsPlaybackEnabled: false,
        daemonChannelAvailable: false,
        accessibilityGranted: false,
        screenRecordingGranted: false,
        microphoneGranted: false,
        screenContentGranted: false,
        sendingDirectMessage: false,
        waitingForCursorResponse: false,
        quickInputPanelVisible: false,
        tracePendingCount: 0,
        tracePendingCapacity: 0,
        traceRecordedCount: 0,
        traceDroppedCount: 0,
        traceTransportFailureCount: 0
    )
}

extension CompanionVoiceState {
    var debugLabel: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .processing: "processing"
        case .responding: "responding"
        }
    }
}

extension PickyVoiceInteractionPhase {
    var debugLabel: String {
        switch self {
        case .idle: "idle"
        case .pttInput: "pttInput"
        case .loading: "loading"
        case .speaking: "speaking"
        }
    }
}

extension PickyInteractionState {
    /// Correlation identifiers the snapshot exposes. Reading them from the
    /// reducer state keeps the snapshot consistent with the trace.
    var debugActiveInputID: UUID? {
        switch input {
        case .idle:
            if case .waitingForAgent(let inputID, _, _) = output { return inputID }
            return nil
        case .voiceListening(let inputID, _),
             .voiceFinalizing(let inputID, _, _),
             .voiceSubmitting(let inputID, _, _),
             .textSubmitting(let inputID, _):
            return inputID
        }
    }

    var debugActiveContextID: String? {
        switch output {
        case .waitingForAgent(_, let contextID, _):
            return contextID
        case .showingTextReply(let contextID, _, _, _):
            return contextID
        case .speaking(let contextID, _, _, _, _, _):
            return contextID
        case .suppressedReply(let contextID, _, _, _, _):
            return contextID
        case .idle:
            return streamedResponseContextID
        }
    }

    var debugActiveSpeechID: UUID? {
        if case .speaking(_, let speechID, _, _, _, _) = output { return speechID }
        return nil
    }
}
