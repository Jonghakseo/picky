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

    // A tall four-line answer, and a shorter two-line variant of it. TTS/narration state
    // races briefly hand the shorter variant back for one frame as speech starts.
    private let fourLineAnswer = "프로모션 준비를 마치고, 로컬 화면도 꽼꽼히 확인해요. 모든 변경은 안전하게 담아, 션하게 배포까지 갑시다."
    private let twoLineVariant = "프로모션 준비를 마치고, 로컬 화면도 꽼꽼히 확인해요."

    // Regression: when TTS starts, the bubble briefly rendered a shorter variant of the
    // fully streamed text and back, causing a one-frame flicker. Because the response is
    // append-only, a candidate that wraps to fewer lines than what is shown is a transient
    // regression and must not shrink the bubble.
    @Test func shorterRenderKeepsFullerLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        cache.update(for: fourLineAnswer)
        // Guard only makes sense if the variant genuinely renders fewer lines.
        #expect(
            PickyCursorResponseBubbleLayout(sourceText: twoLineVariant).lineCount
                < PickyCursorResponseBubbleLayout(sourceText: fourLineAnswer).lineCount
        )

        let regressed = cache.layout(for: twoLineVariant)

        #expect(regressed?.sourceText == fourLineAnswer)
    }

    @Test func shorterRenderDoesNotOverwriteCachedLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        cache.update(for: fourLineAnswer)

        cache.update(for: twoLineVariant)

        #expect(cache.layout(for: twoLineVariant)?.sourceText == fourLineAnswer)
    }

    @Test func emptyTextHasNoLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        #expect(cache.layout(for: "") == nil)
    }
}
