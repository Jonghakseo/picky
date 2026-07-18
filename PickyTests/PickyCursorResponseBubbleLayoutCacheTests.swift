//
//  PickyCursorResponseBubbleLayoutCacheTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickyCursorResponseBubbleLayoutCacheTests {
    // Regression: the blue cursor response bubble flickered because `layout(for:)`
    // returned nil for one frame after the narration text changed but before the
    // async `update(for:)` warmed the cache. A cache miss must now resolve inline.
    @Test func layoutResolvesOnCacheMissWithoutPriorUpdate() {
        let cache = PickyCursorResponseBubbleLayoutCache()

        let layout = cache.layout(for: "첫 문장.")

        #expect(layout?.sourceText == "첫 문장.")
    }

    @Test func layoutResolvesForNewTextEvenWhenCacheHoldsPreviousText() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        cache.update(for: "첫 문장.")

        let previous = cache.layout(for: "첫 문장.")
        let next = cache.layout(for: "첫 문장. 둘째 문장.")

        #expect(previous?.sourceText == "첫 문장.")
        #expect(next?.sourceText == "첫 문장. 둘째 문장.")
    }

    @Test func emptyTextHasNoLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        #expect(cache.layout(for: "") == nil)
    }
}
