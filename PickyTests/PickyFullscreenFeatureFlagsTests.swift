//
//  PickyFullscreenFeatureFlagsTests.swift
//  PickyTests
//

import Testing

@testable import Picky

struct PickyFullscreenFeatureFlagsTests {
    @Test func enabledForOne() {
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "1"]))
    }

    @Test func enabledForTrue() {
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "true"]))
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "TRUE"]))
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "yes"]))
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "on"]))
    }

    @Test func disabledForZero() {
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "0"]))
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "false"]))
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": ""]))
    }

    @Test func disabledForMissingVariable() {
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: [:]))
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: ["OTHER": "1"]))
    }

    @Test func trimsWhitespace() {
        #expect(PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "  1  "]))
        #expect(!PickyFullscreenFeatureFlags.evaluate(env: ["PICKY_FULLSCREEN_ENABLED": "  2  "]))
    }
}
