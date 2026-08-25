//
//  PickyQuickInputRecipientPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyQuickInputRecipientPolicyTests {
    @Test func resolvesMissingOrBlankTargetToMainRecipient() {
        #expect(PickyQuickInputRecipientPolicy.resolve(
            screenContextTargetSessionID: nil,
            targetLabel: nil
        ) == .main)
        #expect(PickyQuickInputRecipientPolicy.resolve(
            screenContextTargetSessionID: "  ",
            targetLabel: "Pickle"
        ) == .main)
    }

    @Test func preservesTargetIdentityAndUsesTrimmedLabel() {
        #expect(PickyQuickInputRecipientPolicy.resolve(
            screenContextTargetSessionID: "  pickle-session  ",
            targetLabel: "  Investigate logs  "
        ) == .pickle(sessionID: "pickle-session", label: "Investigate logs"))
    }

    @Test func preservesPickleFallbackLabelForMissingOrBlankLabel() {
        #expect(PickyQuickInputRecipientPolicy.resolve(
            screenContextTargetSessionID: "pickle-session",
            targetLabel: nil
        ) == .pickle(sessionID: "pickle-session", label: "Pickle"))
        #expect(PickyQuickInputRecipientPolicy.resolve(
            screenContextTargetSessionID: "pickle-session",
            targetLabel: " \n\t "
        ) == .pickle(sessionID: "pickle-session", label: "Pickle"))
    }
}
