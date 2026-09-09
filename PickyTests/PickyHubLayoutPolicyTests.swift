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

    @Test func usageAxisKeepsDateRangeReadableForLongHistories() {
        #expect(PickyHubStatisticsPresentation.usageAxisIndices(dayCount: 0, availableWidth: 500, minimumSpacing: 64).isEmpty)
        #expect(PickyHubStatisticsPresentation.usageAxisIndices(dayCount: 1, availableWidth: 500, minimumSpacing: 64) == [0])
        #expect(PickyHubStatisticsPresentation.usageAxisIndices(dayCount: 7, availableWidth: 500, minimumSpacing: 64) == Array(0..<7))
        let wide = PickyHubStatisticsPresentation.usageAxisIndices(dayCount: 55, availableWidth: 700, minimumSpacing: 64)
        let narrow = PickyHubStatisticsPresentation.usageAxisIndices(dayCount: 55, availableWidth: 400, minimumSpacing: 84)
        for labels in [wide, narrow] {
            #expect(labels.first == 0)
            #expect(labels.last == 54)
            #expect(labels == labels.sorted())
            #expect(Set(labels).count == labels.count)
        }
        #expect(wide.count <= 11)
        #expect(narrow.count <= 5)
        #expect(narrow.count < wide.count)
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
