//
//  PickyHUDCardResizeInteractionStateTests.swift
//  PickyTests
//
//  Characterization coverage for card resize handle hover/drag state before
//  moving it out of PickyHUDView.
//

import Testing
@testable import Picky

struct PickyHUDCardResizeInteractionStateTests {
    @Test func resetClearsStickyHoverAndDragState() {
        var state = PickyHUDCardResizeInteractionState()

        state.setHovered(true)
        #expect(state.isVisible)
        let hoverOnlyResetWasDragging = state.reset()
        #expect(!hoverOnlyResetWasDragging)
        #expect(!state.isVisible)
        #expect(!state.isHovered)
        #expect(!state.isDragging)

        state.setHovered(true)
        state.beginDragging()
        #expect(state.isVisible)
        let draggingResetWasDragging = state.reset()
        #expect(draggingResetWasDragging)
        #expect(!state.isVisible)
        #expect(!state.isHovered)
        #expect(!state.isDragging)
    }

    @Test func endDraggingKeepsLiveHoverVisible() {
        var state = PickyHUDCardResizeInteractionState()

        state.setHovered(true)
        state.beginDragging()
        let wasDragging = state.endDragging()

        #expect(wasDragging)
        #expect(state.isVisible)
        #expect(state.isHovered)
        #expect(!state.isDragging)
    }

    @Test func endDraggingIsNoOpWhenNotDragging() {
        var state = PickyHUDCardResizeInteractionState()

        let wasDragging = state.endDragging()

        #expect(!wasDragging)
        #expect(!state.isVisible)
        #expect(!state.isHovered)
        #expect(!state.isDragging)
    }
}
