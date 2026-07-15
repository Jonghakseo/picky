//
//  PickySecureSurfaceOverlayPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickySecureSurfaceOverlayPolicyTests {
    @Test func suppressesWhileAppStoreIsFrontmost() {
        #expect(PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(frontmostBundleID: "com.apple.AppStore"))
    }

    @Test func doesNotSuppressForOtherApps() {
        #expect(!PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(frontmostBundleID: "com.apple.Safari"))
        #expect(!PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(frontmostBundleID: "com.jonghakseo.picky"))
    }

    @Test func doesNotSuppressWhenBundleIDIsUnknown() {
        #expect(!PickySecureSurfaceOverlayPolicy.shouldSuppressOverlay(frontmostBundleID: nil))
    }
}
