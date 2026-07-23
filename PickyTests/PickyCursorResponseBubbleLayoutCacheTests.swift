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

    // Visual narration replaces the bubble at each annotation segment; it is not an
    // append-only stream. A shorter sentence in a new segment must therefore replace the
    // prior layout instead of being mistaken for a transient TTS regression.
    @Test func shorterVisualNarrationSegmentsReplacePreviousLayouts() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        let replacements = [
            (
                current: "삭제할 때는 연결 가격 행을 먼저 비활성화해 빈 옵션이 활성 상태로 남지 않게 합니다.",
                currentSegmentID: "segment-disable-row",
                next: "그 다음에 세부 옵션 자체를 삭제해요.",
                nextSegmentID: "segment-delete-option"
            ),
            (
                current: "저장할 때는 스팟을 잠그고 shell 행을 정리·동기화해 동시 저장으로 인한 중복을 막습니다.",
                currentSegmentID: "segment-sync-shell",
                next: "두 경로는 사용자 가격표를 조회하는 단계에서 합쳐집니다.",
                nextSegmentID: "segment-read-price-list"
            ),
        ]

        for replacement in replacements {
            cache.update(for: replacement.current, contentIdentity: replacement.currentSegmentID)
            #expect(
                PickyCursorResponseBubbleLayout(sourceText: replacement.next).lineCount
                    < PickyCursorResponseBubbleLayout(sourceText: replacement.current).lineCount
            )

            let layout = cache.layout(
                for: replacement.next,
                contentIdentity: replacement.nextSegmentID
            )

            #expect(layout?.sourceText == replacement.next)
        }
    }

    @Test func emptyTextHasNoLayout() {
        let cache = PickyCursorResponseBubbleLayoutCache()
        #expect(cache.layout(for: "") == nil)
    }
}
