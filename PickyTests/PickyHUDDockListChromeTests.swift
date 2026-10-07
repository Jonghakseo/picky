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
    @Test func draggingTheInnerEdgeOfARightDockSnapsToTheNearestWidth() {
        func preset(_ dx: CGFloat) -> PickyHUDDockSizePreset {
            PickyHUDDockResizePolicy.preset(start: .medium, screenDelta: CGPoint(x: dx, y: 0), dockSide: .right, fontScale: 1)
        }
        // Medium is 168pt: 200 (L) and 112 (S) are the neighbors.
        #expect(preset(-10) == .medium)
        #expect(preset(-20) == .large)
        #expect(preset(-200) == .large)
        #expect(preset(25) == .medium)
        #expect(preset(30) == .small)
    }

    @Test func aLeftDockGrowsWhenDraggedRight() {
        #expect(PickyHUDDockResizePolicy.preset(
            start: .small, screenDelta: CGPoint(x: 60, y: 0), dockSide: .left, fontScale: 1
        ) == .medium)
        #expect(PickyHUDDockResizePolicy.preset(
            start: .small, screenDelta: CGPoint(x: -60, y: 0), dockSide: .left, fontScale: 1
        ) == .small)
    }

    @Test func horizontalDocksResizeTheirThicknessTowardTheScreenInterior() {
        // Screen coordinates grow upward: a bottom dock thickens when dragged up.
        #expect(PickyHUDDockResizePolicy.preset(
            start: .medium, screenDelta: CGPoint(x: 0, y: 8), dockSide: .bottom, fontScale: 1
        ) == .large)
        #expect(PickyHUDDockResizePolicy.preset(
            start: .medium, screenDelta: CGPoint(x: 0, y: 8), dockSide: .top, fontScale: 1
        ) == .small)
        // Movement along the dock's own axis does not resize it.
        #expect(PickyHUDDockResizePolicy.preset(
            start: .medium, screenDelta: CGPoint(x: 400, y: 0), dockSide: .bottom, fontScale: 1
        ) == .medium)
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
