//
//  PickyHUDDockExternalDragPreviewTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockExternalDragPreviewTests {
    @Test func previewFrameKeepsTheFrozenTileCenteredOnThePointer() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let frame = PickyHUDDockExternalDragPreviewPresentationPolicy.frame(
            pointerScreenPoint: CGPoint(x: -120, y: 420),
            metrics: metrics
        )

        #expect(frame.midX == -120)
        #expect(frame.midY == 420)
        #expect(frame.size == CGSize(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight))
    }

    @Test func cancellationReturnsOnlyToAUsableSourceWhenMotionIsAllowed() {
        let sourceFrame = CGRect(x: -40, y: 80, width: 60, height: 48)

        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: true
        ) == .returnToSource(CGPoint(x: -10, y: 104)))
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: sourceFrame,
            reduceMotion: true,
            sourceIsUsable: true
        ) == .dismiss)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: false
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: CGRect(x: -40, y: 80, width: 0, height: 48),
            reduceMotion: false,
            sourceIsUsable: true
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: CGRect(x: -40, y: 80, width: 60, height: 0),
            reduceMotion: false,
            sourceIsUsable: true
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: false,
            sourceFrame: CGRect(x: -40, y: 80, width: 0, height: 48),
            reduceMotion: true,
            sourceIsUsable: true
        ) == .dismiss)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            committed: true,
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: true
        ) == .dismiss)
    }
}
