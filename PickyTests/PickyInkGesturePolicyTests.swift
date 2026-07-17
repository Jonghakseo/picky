//
//  PickyInkGesturePolicyTests.swift
//  PickyTests
//
//  Locks in the mouse-gesture ownership rules for Picky ink capture: ownership
//  is decided at mouse-down and held to mouse-up so a click-drag is never split
//  between Picky ink and the app underneath, and a drag that arrives with no
//  owning mouse-down (capture armed a beat late) is suppressed instead of
//  leaking a text selection or drawing a stray stroke.
//

import Testing
@testable import Picky

struct PickyInkGesturePolicyTests {
    private func decide(
        _ phase: PickyInkGesturePhase,
        _ input: PickyInkGestureInput,
        overPassThrough: Bool = false
    ) -> PickyInkGestureDecision {
        PickyInkGesturePolicy.decide(phase: phase, input: input, isOverPassThroughRegion: overPassThrough)
    }

    // MARK: - Mouse-down decides ownership

    @Test func mouseDownOverScreenStartsInkAndSuppresses() {
        let decision = decide(.idle, .leftDown, overPassThrough: false)
        #expect(decision == PickyInkGestureDecision(phase: .ink, action: .suppress, strokeCommand: .begin))
    }

    @Test func mouseDownOverPassThroughRegionYieldsToTheApp() {
        let decision = decide(.idle, .leftDown, overPassThrough: true)
        #expect(decision == PickyInkGestureDecision(phase: .passthrough, action: .passThrough, strokeCommand: nil))
    }

    // MARK: - Ownership is held across region changes

    @Test func inkGestureStaysInkEvenWhenDraggedOverPassThroughRegion() {
        // Started on the screen, then the cursor slides over the HUD/pill.
        let decision = decide(.ink, .leftDragged, overPassThrough: true)
        #expect(decision == PickyInkGestureDecision(phase: .ink, action: .suppress, strokeCommand: .update))
    }

    @Test func passThroughGestureStaysPassThroughEvenWhenDraggedOffRegion() {
        // Started on the pill, then the cursor slides onto the page.
        let decision = decide(.passthrough, .leftDragged, overPassThrough: false)
        #expect(decision == PickyInkGestureDecision(phase: .passthrough, action: .passThrough, strokeCommand: nil))
    }

    // MARK: - Missed mouse-down recovery

    @Test func dragWithoutOwningDownBecomesInvalidAndSuppressed() {
        let decision = decide(.idle, .leftDragged, overPassThrough: false)
        #expect(decision == PickyInkGestureDecision(phase: .invalid, action: .suppress, strokeCommand: nil))
    }

    @Test func invalidGestureKeepsSuppressingUntilRelease() {
        let dragged = decide(.invalid, .leftDragged, overPassThrough: true)
        #expect(dragged == PickyInkGestureDecision(phase: .invalid, action: .suppress, strokeCommand: nil))

        let released = decide(.invalid, .leftUp, overPassThrough: false)
        #expect(released == PickyInkGestureDecision(phase: .idle, action: .suppress, strokeCommand: nil))
    }

    // MARK: - Release resets ownership

    @Test func inkReleaseFinishesStrokeAndReturnsToIdle() {
        let decision = decide(.ink, .leftUp, overPassThrough: false)
        #expect(decision == PickyInkGestureDecision(phase: .idle, action: .suppress, strokeCommand: .finish))
    }

    @Test func passThroughReleaseReturnsToIdleWithoutStroke() {
        let decision = decide(.passthrough, .leftUp, overPassThrough: true)
        #expect(decision == PickyInkGestureDecision(phase: .idle, action: .passThrough, strokeCommand: nil))
    }

    // MARK: - Hover between gestures keeps Picky surfaces clickable

    @Test func hoverOverPassThroughRegionPassesThroughWithoutChangingPhase() {
        let decision = decide(.idle, .moved, overPassThrough: true)
        #expect(decision == PickyInkGestureDecision(phase: .idle, action: .passThrough, strokeCommand: nil))
    }

    @Test func hoverOverScreenIsSuppressed() {
        let decision = decide(.idle, .moved, overPassThrough: false)
        #expect(decision == PickyInkGestureDecision(phase: .idle, action: .suppress, strokeCommand: nil))
    }

    @Test func otherButtonActivityFollowsRegionAndKeepsPhase() {
        #expect(decide(.idle, .other, overPassThrough: true).action == .passThrough)
        #expect(decide(.idle, .other, overPassThrough: false).action == .suppress)
        #expect(decide(.idle, .other, overPassThrough: false).phase == .idle)
    }

    // MARK: - Full gesture sequences

    @Test func inkGestureCompletesAndResetsForTheNextDraw() {
        var phase = PickyInkGesturePhase.idle

        let down = decide(phase, .leftDown, overPassThrough: false)
        phase = down.phase
        #expect(phase == .ink)

        // Crosses onto the HUD partway through — must stay owned by Picky.
        let drag = decide(phase, .leftDragged, overPassThrough: true)
        phase = drag.phase
        #expect(drag.strokeCommand == .update)
        #expect(phase == .ink)

        let up = decide(phase, .leftUp, overPassThrough: true)
        phase = up.phase
        #expect(up.strokeCommand == .finish)
        #expect(phase == .idle)

        // A brand-new down after release starts clean, never inheriting ink.
        let nextDown = decide(phase, .leftDown, overPassThrough: true)
        #expect(nextDown.phase == .passthrough)
    }
}
