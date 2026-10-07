//
//  PickyHUDDockListChromeTests.swift
//  PickyTests
//
//  Resize-tab snapping and list scroll fades of the list dock.
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockListChromeTests {
    @Test func resizingARightDockTakesAFullStepOfPointerTravelPerPreset() {
        func preset(_ dx: CGFloat, from start: PickyHUDDockSizePreset = .medium) -> PickyHUDDockSizePreset {
            PickyHUDDockResizePolicy.preset(
                start: start, current: start, screenDelta: CGPoint(x: dx, y: 0), dockSide: .right)
        }
        // A right dock grows toward the screen interior, so leftward.
        #expect(preset(-2) == .medium)
        #expect(preset(2) == .medium)
        #expect(preset(-7) == .medium)
        #expect(preset(7) == .medium)
        #expect(preset(-39) == .medium)
        #expect(preset(-40) == .large)
        #expect(preset(40) == .small)
        #expect(preset(-80, from: .small) == .large)
        #expect(preset(80, from: .large) == .small)
        // The ends clamp instead of wrapping.
        #expect(preset(-400) == .large)
        #expect(preset(400) == .small)
    }

    /// Without hysteresis a pointer resting on a step boundary flips the dock
    /// between two presets, because the applied preset feeds straight back
    /// into the next drag update.
    @Test func aPresetKeepsTheDockUntilThePointerClearsItByHalfAStep() {
        func preset(_ dx: CGFloat, current: PickyHUDDockSizePreset) -> PickyHUDDockSizePreset {
            PickyHUDDockResizePolicy.preset(
                start: .medium, current: current, screenDelta: CGPoint(x: dx, y: 0), dockSide: .right)
        }
        // A right dock grows leftward, so -40 buys the first step.
        #expect(preset(-40, current: .medium) == .large)
        #expect(preset(-39.5, current: .large) == .large)
        #expect(preset(-21, current: .large) == .large)
        #expect(preset(-19, current: .large) == .medium)
        // The same margin applies on the way back toward the small end.
        #expect(preset(41, current: .medium) == .small)
        #expect(preset(39, current: .small) == .small)
        #expect(preset(19, current: .small) == .medium)
    }

    @Test func everyDockSideGrowsTowardTheScreenInterior() {
        func preset(_ dockSide: PickyHUDDockSide, _ delta: CGPoint) -> PickyHUDDockSizePreset {
            PickyHUDDockResizePolicy.preset(
                start: .medium, current: .medium, screenDelta: delta, dockSide: dockSide)
        }
        #expect(preset(.left, CGPoint(x: 40, y: 0)) == .large)
        #expect(preset(.left, CGPoint(x: -40, y: 0)) == .small)
        // Screen coordinates grow upward: a bottom dock thickens when dragged up.
        #expect(preset(.bottom, CGPoint(x: 0, y: 40)) == .large)
        #expect(preset(.top, CGPoint(x: 0, y: 40)) == .small)
        #expect(preset(.top, CGPoint(x: 0, y: -40)) == .large)
        // Movement along the dock's own axis does not resize it.
        #expect(preset(.bottom, CGPoint(x: 400, y: 0)) == .medium)
        #expect(preset(.right, CGPoint(x: 0, y: 400)) == .medium)
    }

    @Test func scrollFadesMarkOnlyTheEdgesThatHideRows() {
        #expect(PickyHUDDockScrollFadePolicy.fades(offset: 0, contentLength: 300, viewportLength: 300)
            == .init(leading: false, trailing: false))
        #expect(PickyHUDDockScrollFadePolicy.fades(offset: 0, contentLength: 900, viewportLength: 300)
            == .init(leading: false, trailing: true))
        #expect(PickyHUDDockScrollFadePolicy.fades(offset: 200, contentLength: 900, viewportLength: 300)
            == .init(leading: true, trailing: true))
        #expect(PickyHUDDockScrollFadePolicy.fades(offset: 600, contentLength: 900, viewportLength: 300)
            == .init(leading: true, trailing: false))
    }
}
