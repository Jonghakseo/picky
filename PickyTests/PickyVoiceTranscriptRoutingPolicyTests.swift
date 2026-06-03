//
//  PickyVoiceTranscriptRoutingPolicyTests.swift
//  PickyTests
//
//  Characterization coverage for voice transcript routing decisions before
//  moving them out of CompanionManager.
//

import Testing
@testable import Picky

struct PickyVoiceTranscriptRoutingPolicyTests {
    @Test func routesBlankOrMissingVoiceTargetToMainSubmit() {
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: nil,
            screenContextTargetSessionID: nil
        ) == .submitToMain)
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "   ",
            screenContextTargetSessionID: "pickle"
        ) == .submitToMain)
    }

    @Test func routesVoiceTargetToPickleFollowUpWhenNotScreenContextTarget() {
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "  pickle-session  ",
            screenContextTargetSessionID: nil
        ) == .followUpPickle(sessionID: "pickle-session"))
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "pickle-session",
            screenContextTargetSessionID: "other-session"
        ) == .followUpPickle(sessionID: "pickle-session"))
    }

    @Test func routesVoiceTargetToPickleSteerWhenItMatchesScreenContextTarget() {
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "pickle-session",
            screenContextTargetSessionID: "pickle-session"
        ) == .steerPickle(sessionID: "pickle-session"))
    }

    @Test func screenContextTargetComparisonPreservesExistingExactMatchSemantics() {
        #expect(PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: "pickle-session",
            screenContextTargetSessionID: "  pickle-session  "
        ) == .followUpPickle(sessionID: "pickle-session"))
    }

    @Test func normalizesVoiceFollowUpSessionIDs() {
        #expect(PickyVoiceTranscriptRoutingPolicy.normalizedSessionID("  pickle-session\n") == "pickle-session")
        #expect(PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(" \t ") == nil)
        #expect(PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(nil) == nil)
    }
}
