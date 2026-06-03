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
}
