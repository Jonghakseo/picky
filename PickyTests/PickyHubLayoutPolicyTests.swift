import AppKit
import Testing
@testable import Picky

struct PickyHubLayoutPolicyTests {
    @Test func contentWidthSubtractsInsetsBeforeApplyingMaximumWidth() {
        let padding = PickyHubTheme.Layout.contentHorizontalPadding * 2
        #expect(PickyHubGridPolicy.contentWidth(forViewportWidth: 100) == max(0, 100 - padding))
        #expect(PickyHubGridPolicy.contentWidth(forViewportWidth: 0) == 0)
        #expect(PickyHubGridPolicy.contentWidth(forViewportWidth: 2000) == PickyHubTheme.Layout.contentMaxWidth)
    }

    @Test func narrowWindowsReduceTheNumberOfCardColumns() {
        #expect(PickyHubGridPolicy.columnCount(for: 459) == 1)
        #expect(PickyHubGridPolicy.columnCount(for: 460) == 2)
        #expect(PickyHubGridPolicy.columnCount(for: 639) == 2)
        #expect(PickyHubGridPolicy.columnCount(for: 640) == 3)
        #expect(PickyHubGridPolicy.columnCount(for: 780, maximum: 2) == 2)
    }

    @Test func minimumCardWidthNeverCreatesAnOverflowingQuickStartGrid() {
        let width = PickyHubGridPolicy.contentWidth(forViewportWidth: 760 - PickyHubTheme.Layout.sidebarWidth)
        #expect(PickyHubGridPolicy.columnCount(for: width, maximum: 2, minimumCardWidth: 280, spacing: 12) == 1)
        #expect(PickyHubGridPolicy.columnCount(for: 780, maximum: 2, minimumCardWidth: 280, spacing: 12) == 2)
    }

    @Test func returnSubmitsButShiftReturnKeepsMultilineInput() {
        #expect(PickyHubConversationPolicy.shouldSubmit(modifiers: []))
        #expect(!PickyHubConversationPolicy.shouldSubmit(modifiers: .shift))
        #expect(!PickyHubConversationPolicy.shouldSubmit(modifiers: .option))
    }

    @Test func readingHistoryDoesNotCountAsBeingAtTheBottom() {
        #expect(PickyHubConversationPolicy.isNearBottom(bottom: 400, viewportHeight: 400))
        #expect(PickyHubConversationPolicy.isNearBottom(bottom: 430, viewportHeight: 400))
        #expect(!PickyHubConversationPolicy.isNearBottom(bottom: 900, viewportHeight: 400))
    }
}
