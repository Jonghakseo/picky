//
//  PickyPiOAuthLoginControllerTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyPiOAuthLoginControllerTests {
    @Test func providersUsePiOAuthProviderIDs() {
        #expect(PickyPiOAuthLoginProvider.openAICodex.rawValue == "openai-codex")
        #expect(PickyPiOAuthLoginProvider.anthropic.rawValue == "anthropic")
    }

    @Test func parsesHelperResultFromLastMarkedLine() throws {
        let output = """
        noisy line
        PICKY_PI_OAUTH_RESULT {"configured":false,"source":null,"label":null}
        PICKY_PI_OAUTH_RESULT {"configured":true,"source":"stored","label":null}
        """

        let status = try PickyPiOAuthLoginProcessRunner.parseResult(output)

        #expect(status.configured)
        #expect(status.source == "stored")
        #expect(status.label == nil)
    }

    @Test func missingHelperResultThrows() {
        #expect(throws: PickyPiOAuthLoginError.missingResult("hello")) {
            _ = try PickyPiOAuthLoginProcessRunner.parseResult("hello")
        }
    }
}
