//
//  PickyHUDInkPassThroughPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDInkPassThroughPolicyTests {
    // Panel on screen: origin (1000, 200), size 600x800.
    // SwiftUI space inside it is top-left based: y grows downward from 1000.
    private let panelFrame = CGRect(x: 1000, y: 200, width: 600, height: 800)

    @Test
    func convertsTopLeftSwiftUIFrameToBottomLeftScreenRect() {
        // Rail at SwiftUI (540, 20) 40x300: SwiftUI maxY 320 measured from the
        // panel top (screen y 1000) → AppKit y = 1000 - 320 = 680.
        let rects = PickyHUDInkPassThroughPolicy.screenRects(
            swiftUIFrames: [CGRect(x: 540, y: 20, width: 40, height: 300)],
            panelFrame: panelFrame
        )
        #expect(rects == [CGRect(x: 1540, y: 680, width: 40, height: 300)])
    }

    @Test
    func containsPointOverChromeButNotOverTransparentReserve() {
        // Vertical right-side dock: card column (0-540) transparent, rail at 540+.
        let railFrame = CGRect(x: 540, y: 20, width: 40, height: 300)

        #expect(PickyHUDInkPassThroughPolicy.contains(
            CGPoint(x: 1550, y: 800),
            swiftUIFrames: [railFrame],
            panelFrame: panelFrame
        ))
        // Same height, inside the panel frame, but over the reserve column.
        #expect(!PickyHUDInkPassThroughPolicy.contains(
            CGPoint(x: 1200, y: 800),
            swiftUIFrames: [railFrame],
            panelFrame: panelFrame
        ))
    }

    @Test
    func containsPointOverExpandedCardFrame() {
        let cardFrame = CGRect(x: 0, y: 20, width: 520, height: 700)
        #expect(PickyHUDInkPassThroughPolicy.contains(
            CGPoint(x: 1200, y: 500),
            swiftUIFrames: [cardFrame],
            panelFrame: panelFrame
        ))
    }

    @Test
    func noReportedFramesMeansNoPassThrough() {
        #expect(!PickyHUDInkPassThroughPolicy.contains(
            CGPoint(x: 1200, y: 500),
            swiftUIFrames: [],
            panelFrame: panelFrame
        ))
    }

    @Test
    func rejectsDegenerateFrames() {
        let degenerate: [CGRect] = [
            .null,
            .zero,
            CGRect(x: CGFloat.nan, y: 0, width: 40, height: 40),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40)
        ]
        #expect(PickyHUDInkPassThroughPolicy.screenRects(
            swiftUIFrames: degenerate,
            panelFrame: panelFrame
        ).isEmpty)
        #expect(PickyHUDInkPassThroughPolicy.screenRects(
            swiftUIFrames: [CGRect(x: 0, y: 0, width: 40, height: 40)],
            panelFrame: .null
        ).isEmpty)
    }

    @Test
    func rejectsNonFinitePoint() {
        #expect(!PickyHUDInkPassThroughPolicy.contains(
            CGPoint(x: CGFloat.nan, y: 500),
            swiftUIFrames: [CGRect(x: 0, y: 0, width: 600, height: 800)],
            panelFrame: panelFrame
        ))
    }
}
