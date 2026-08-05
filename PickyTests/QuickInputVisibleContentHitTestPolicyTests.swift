//
//  QuickInputVisibleContentHitTestPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct QuickInputVisibleContentHitTestPolicyTests {
    @Test
    func appKitBoundsConvertEveryMeasuredSwiftUIContentFrame() {
        let bounds = QuickInputVisibleContentHitTestPolicy.appKitVisibleBounds(
            swiftUIFrames: [
                CGRect(x: 12, y: 18, width: 100, height: 40),
                CGRect(x: 20, y: 72, width: 80, height: 24)
            ],
            hostingViewSize: CGSize(width: 160, height: 120)
        )

        #expect(bounds == [
            CGRect(x: 12, y: 62, width: 100, height: 40),
            CGRect(x: 20, y: 24, width: 80, height: 24)
        ])
    }

    @Test
    func lightweightHistoryExcludesItsFullyTransparentTopBand() {
        let visibleFrame = QuickInputVisibleContentHitTestPolicy.visibleHistoryFrame(
            CGRect(x: 12, y: 10, width: 100, height: 100),
            backgroundMode: .lightweight
        )

        #expect(visibleFrame == CGRect(x: 12, y: 30, width: 100, height: 80))
        #expect(!QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 20, y: 175),
            swiftUIFrames: [visibleFrame],
            hostingViewSize: CGSize(width: 200, height: 200)
        ))
        #expect(QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 20, y: 150),
            swiftUIFrames: [visibleFrame],
            hostingViewSize: CGSize(width: 200, height: 200)
        ))
    }

    @Test
    func solidHistoryKeepsItsEntireCardFrameInteractive() {
        let cardFrame = CGRect(x: 12, y: 10, width: 100, height: 100)

        #expect(QuickInputVisibleContentHitTestPolicy.visibleHistoryFrame(
            cardFrame,
            backgroundMode: .solid
        ) == cardFrame)
        #expect(QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 20, y: 175),
            swiftUIFrames: [cardFrame],
            hostingViewSize: CGSize(width: 200, height: 200)
        ))
    }

    @Test
    func emptyAndDegenerateFramesAreNotInteractive() {
        let invalidFrames: [CGRect] = [
            .null,
            .zero,
            .infinite,
            CGRect(x: 10, y: 10, width: 20, height: 0)
        ]

        #expect(QuickInputVisibleContentHitTestPolicy.appKitVisibleBounds(
            swiftUIFrames: invalidFrames,
            hostingViewSize: CGSize(width: 200, height: 200)
        ).isEmpty)
        #expect(!QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 10, y: 10),
            swiftUIFrames: [CGRect(x: 10, y: 10, width: 20, height: 20)],
            hostingViewSize: .zero
        ))
    }

    @Test
    func visibleContentIncludesItsLeadingBoundaryButExcludesPointsOutsideIt() {
        let frame = CGRect(x: 12, y: 18, width: 100, height: 40)
        let hostingViewSize = CGSize(width: 160, height: 120)

        #expect(QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 12, y: 62),
            swiftUIFrames: [frame],
            hostingViewSize: hostingViewSize
        ))
        #expect(!QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 11.99, y: 62),
            swiftUIFrames: [frame],
            hostingViewSize: hostingViewSize
        ))
        #expect(!QuickInputVisibleContentHitTestPolicy.contains(
            CGPoint(x: 112.01, y: 62),
            swiftUIFrames: [frame],
            hostingViewSize: hostingViewSize
        ))
    }
}
