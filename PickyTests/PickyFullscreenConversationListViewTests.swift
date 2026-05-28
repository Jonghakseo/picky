//
//  PickyFullscreenConversationListViewTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@Suite("PickyFullscreenConversationListView")
struct PickyFullscreenConversationListViewTests {
    @Test func scrollAnimationRespectsReducedMotion() {
        #expect(!PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: false, reduceMotion: false))
        #expect(PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: true, reduceMotion: false))
        #expect(!PickyFullscreenConversationListView.shouldAnimateScroll(hasAppeared: true, reduceMotion: true))
    }
}
