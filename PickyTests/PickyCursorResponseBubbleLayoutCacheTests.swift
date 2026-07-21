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

    // Regression: when TTS starts, `latestAgentSessionSummary` briefly reverts to the
    // leading sentences (a prefix of the fully streamed text) for one frame before
    // returning to the full text. Since the response is append-only, a prefix regression
    // must not shrink the bubble; the fuller layout stays put so it does not flicker.
    @Test func prefixRegressionKeepsFullerLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        let full = "첫 문장. 둘째 문장. 셋째 문장. 넷째 문장."
        cache.update(for: full)

        let regressed = cache.layout(for: "첫 문장. 둘째 문장.")

        #expect(regressed?.sourceText == full)
    }

    @Test func prefixRegressionDoesNotOverwriteCachedLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        let full = "첫 문장. 둘째 문장. 셋째 문장. 넷째 문장."
        cache.update(for: full)

        cache.update(for: "첫 문장.")

        #expect(cache.layout(for: "첫 문장.")?.sourceText == full)
    }

    @Test func emptyTextHasNoLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        #expect(cache.layout(for: "") == nil)
    }
}
