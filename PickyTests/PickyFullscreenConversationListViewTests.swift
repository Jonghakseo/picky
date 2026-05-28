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

    @Test func fullscreenDetailWidthTracksAvailableColumnWithoutTouchingDivider() {
        for columnWidth in [CGFloat(1040), 1280, 1600] {
            let detailWidth = PickyFullscreenConversationPaneView.responsiveConversationDetailWidth(forColumnWidth: columnWidth)

            #expect(detailWidth <= columnWidth - PickyFullscreenConversationPaneView.conversationDividerClearance)
            #expect(detailWidth <= 760)
        }
    }

    @Test func fullscreenDetailWidthAccountsForNarrowCenterColumnInsets() {
        for columnWidth in [CGFloat(480), 498, 528] {
            let detailWidth = PickyFullscreenConversationPaneView.responsiveConversationDetailWidth(forColumnWidth: columnWidth)
            let occupiedWidth = detailWidth
                + PickyFullscreenConversationPaneView.conversationListInnerHorizontalPadding
                + PickyFullscreenConversationPaneView.conversationDividerClearance
                + PickyFullscreenConversationPaneView.conversationUserBubbleOppositeReserve

            #expect(occupiedWidth <= columnWidth)
        }
    }
}
