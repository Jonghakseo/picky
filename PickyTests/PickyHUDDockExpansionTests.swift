import Combine
import Testing
@testable import Picky

struct PickyHUDDockExpansionTests {
    @MainActor @Test func hoverDeadlinePublishesAndReentryCancelsThePendingCollapse() async throws {
        let controller = PickyHUDDockExpansionController()
        defer { controller.stop() }
        controller.update(pointerInside: true, heldOpen: false)
        #expect(!controller.isExpanded)
        try await withPickyTestTimeout("dock hover expansion") {
            for await expanded in controller.$isExpanded.values {
                if expanded { return }
            }
        }
        controller.update(pointerInside: false, heldOpen: false)
        controller.update(pointerInside: true, heldOpen: false)
        // Cross the actual collapse deadline to catch a cancelled task that
        // still publishes its stale target after re-entry.
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.isExpanded)
        controller.update(pointerInside: false, heldOpen: false)
        try await withPickyTestTimeout("dock hover collapse") {
            for await expanded in controller.$isExpanded.values {
                if !expanded { return }
            }
        }
    }

    @MainActor @Test func conversationCloseRetainsCenteredControlsUntilCollapseThenHoverStaysAtEdge() async throws {
        let controller = PickyHUDDockExpansionController()
        defer { controller.stop() }
        controller.update(pointerInside: false, heldOpen: true, conversationOpen: true)
        #expect(controller.isExpanded)
        #expect(controller.centersControls)

        controller.update(pointerInside: false, heldOpen: false)
        // Closing the HUD must not reset alignment during the collapse grace period.
        #expect(controller.centersControls)
        controller.update(pointerInside: true, heldOpen: false)
        #expect(controller.centersControls)
        controller.update(pointerInside: false, heldOpen: false)
        try await withPickyTestTimeout("centered dock collapses") {
            for await expanded in controller.$isExpanded.values {
                if !expanded { return }
            }
        }
        #expect(!controller.centersControls)

        controller.update(pointerInside: true, heldOpen: false)
        try await withPickyTestTimeout("next hover keeps controls at edge") {
            for await expanded in controller.$isExpanded.values {
                if expanded { return }
            }
        }
        #expect(!controller.centersControls)
        controller.update(pointerInside: true, heldOpen: true, conversationOpen: true)
        #expect(controller.centersControls)
    }

    @Test func passingOverTheRailDoesNotExpandItLater() {
        var state = PickyHUDDockExpansionState()
        state.update(pointerInside: true, heldOpen: false, now: 0)
        state.advance(now: 0.19)
        #expect(!state.isExpanded)
        state.update(pointerInside: false, heldOpen: false, now: 0.19)
        state.advance(now: 1)
        #expect(!state.isExpanded)
        #expect(state.deadline == nil)
    }

    @Test func dwellOpensAndReentryCancelsCollapseWithoutAnotherDwell() {
        var state = PickyHUDDockExpansionState()
        state.update(pointerInside: true, heldOpen: false, now: 0)
        state.advance(now: 0.2)
        #expect(state.isExpanded)
        state.update(pointerInside: false, heldOpen: false, now: 1)
        state.advance(now: 1.29)
        #expect(state.isExpanded)
        state.update(pointerInside: true, heldOpen: false, now: 1.29)
        state.advance(now: 2)
        #expect(state.isExpanded)
        state.update(pointerInside: false, heldOpen: false, now: 3)
        state.advance(now: 3.3)
        #expect(!state.isExpanded)
    }

    @Test func interactionHoldOpensImmediatelyAndCancelsStaleCollapse() {
        var state = PickyHUDDockExpansionState()
        state.update(pointerInside: false, heldOpen: true, now: 0)
        #expect(state.isExpanded)
        state.update(pointerInside: false, heldOpen: false, now: 1)
        state.update(pointerInside: false, heldOpen: true, now: 1.1)
        state.advance(now: 2)
        #expect(state.isExpanded)
        #expect(state.deadline == nil)
        state.update(pointerInside: false, heldOpen: false, now: 3)
        state.advance(now: 3.3)
        #expect(!state.isExpanded)
    }
}
