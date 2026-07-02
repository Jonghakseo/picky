//
//  PickyRealtimeVoiceTurnPolicyTests.swift
//  PickyTests
//
//  Characterization coverage for deciding whether a PTT voice turn should use
//  the main-agent Realtime path or standard dictation/Pi routing.
//

import Testing
@testable import Picky

struct PickyRealtimeVoiceTurnPolicyTests {
    @Test func usesRealtimeOnlyForMainVoiceTurnsWhenRuntimeIsRealtime() {
        #expect(PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: nil,
            runtimeMode: .openAIRealtime
        ))
        #expect(PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: "   ",
            runtimeMode: .openAIRealtime
        ))
    }

    @Test func neverUsesRealtimeForPickleTargetEvenWhenRuntimeIsRealtime() {
        #expect(!PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: "pickle-session",
            runtimeMode: .openAIRealtime
        ))
        #expect(!PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: "  pickle-session  ",
            runtimeMode: .openAIRealtime
        ))
    }

    @Test func neverUsesRealtimeWhenRuntimeIsPi() {
        #expect(!PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: nil,
            runtimeMode: .pi
        ))
        #expect(!PickyRealtimeVoiceTurnPolicy.shouldUseRealtimeMainVoiceTurn(
            targetSessionID: "pickle-session",
            runtimeMode: .pi
        ))
    }

    @Test func resolvesVoiceInteractionModeFromRuntimeAndTarget() {
        #expect(PickyRealtimeVoiceTurnPolicy.mode(targetSessionID: nil, runtimeMode: .openAIRealtime) == .realtime)
        #expect(PickyRealtimeVoiceTurnPolicy.mode(targetSessionID: "pickle-session", runtimeMode: .openAIRealtime) == .standard)
        #expect(PickyRealtimeVoiceTurnPolicy.mode(targetSessionID: nil, runtimeMode: .pi) == .standard)
    }

    @Test func currentModeUsesRealtimeWhenRealtimeInputIsAlreadyActive() {
        #expect(PickyRealtimeVoiceTurnPolicy.currentMode(
            realtimeInputIsActive: true,
            targetSessionID: nil,
            runtimeMode: .pi
        ) == .realtime)
        #expect(PickyRealtimeVoiceTurnPolicy.currentMode(
            realtimeInputIsActive: true,
            targetSessionID: "pickle-session",
            runtimeMode: .openAIRealtime
        ) == .realtime)
    }

    @Test func currentModeKeepsTargetedPickleTurnsStandardUnderRealtimeRuntime() {
        #expect(PickyRealtimeVoiceTurnPolicy.currentMode(
            realtimeInputIsActive: false,
            targetSessionID: "pickle-session",
            runtimeMode: .openAIRealtime
        ) == .standard)
        #expect(PickyRealtimeVoiceTurnPolicy.currentMode(
            realtimeInputIsActive: false,
            targetSessionID: nil,
            runtimeMode: .openAIRealtime
        ) == .realtime)
    }

    @Test func realtimeRuntimePickleTargetsUseStandardModeAndPickleRouting() {
        #expect(PickyRealtimeVoiceTurnPolicy.mode(
            targetSessionID: "screen-pickle",
            runtimeMode: .openAIRealtime
        ) == .standard)
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "screen-pickle",
            screenContextTargetSessionID: "screen-pickle"
        ) == .followUpPickle(sessionID: "screen-pickle"))

        #expect(PickyRealtimeVoiceTurnPolicy.mode(
            targetSessionID: "hovered-pickle",
            runtimeMode: .openAIRealtime
        ) == .standard)
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "hovered-pickle",
            screenContextTargetSessionID: "screen-pickle"
        ) == .followUpPickle(sessionID: "hovered-pickle"))
    }
}
