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
            terminal: .cancel(.escape),
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: true
        ) == .returnToSource(CGPoint(x: -10, y: 104)))
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.escape),
            sourceFrame: sourceFrame,
            reduceMotion: true,
            sourceIsUsable: true
        ) == .dismiss)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.invalidDrop),
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: false
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.invalidDrop),
            sourceFrame: CGRect(x: -40, y: 80, width: 0, height: 48),
            reduceMotion: false,
            sourceIsUsable: true
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.invalidDrop),
            sourceFrame: CGRect(x: -40, y: 80, width: 60, height: 0),
            reduceMotion: false,
            sourceIsUsable: true
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.invalidDrop),
            sourceFrame: CGRect(x: -40, y: 80, width: 0, height: 48),
            reduceMotion: true,
            sourceIsUsable: true
        ) == .dismiss)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .commit(.topLevel(index: 0)),
            sourceFrame: sourceFrame,
            reduceMotion: false,
            sourceIsUsable: true
        ) == .dismiss)
    }

    @Test func sourceFrameValidationRejectsNonFiniteOriginsAndNonPositiveDimensions() {
        #expect(!PickyHUDDockExternalDragPreviewPresentationPolicy.sourceFrameIsUsable(
            CGRect(x: CGFloat.nan, y: 10, width: 40, height: 40)
        ))
        #expect(!PickyHUDDockExternalDragPreviewPresentationPolicy.sourceFrameIsUsable(
            CGRect(x: 10, y: CGFloat.infinity, width: 40, height: 40)
        ))
        #expect(!PickyHUDDockExternalDragPreviewPresentationPolicy.sourceFrameIsUsable(
            CGRect(x: 10, y: 20, width: 0, height: 40)
        ))
    }

    @Test func teardownAndStaleGeometryNeverReturnToSource() {
        let frame = CGRect(x: 10, y: 20, width: 40, height: 40)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.teardown), sourceFrame: frame, reduceMotion: false, sourceIsUsable: true
        ) == .fadeOut)
        #expect(PickyHUDDockExternalDragPreviewPresentationPolicy.terminal(
            terminal: .cancel(.staleLayout), sourceFrame: frame, reduceMotion: true, sourceIsUsable: true
        ) == .dismiss)
    }

    @Test func oldPreviewCompletionCannotCloseANewerToken() {
        let old = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let new = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        #expect(!PickyHUDDockExternalDragPreviewGenerationPolicy.mayClose(activeToken: new, finishingToken: old))
        #expect(PickyHUDDockExternalDragPreviewGenerationPolicy.mayClose(activeToken: new, finishingToken: new))
    }
}
