//
//  PickyCaptureContextControlHitTestPolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyCaptureContextControlHitTestPolicyTests {
    private let hostingViewSize = CGSize(width: 420, height: 48)
    /// SwiftUI coordinates have a top-left origin; this is the measured
    /// capsule/control frame before the policy converts it for AppKit.
    private let visibleContentFrame = CGRect(x: 52, y: 6, width: 316, height: 28)

    @Test
    func appKitBoundsConvertTheMeasuredSwiftUICapsuleFrame() {
        #expect(PickyCaptureContextControlHitTestPolicy.appKitVisibleBounds(
            visibleContentFrame: visibleContentFrame,
            hostingViewSize: hostingViewSize
        ) == CGRect(x: 52, y: 14, width: 316, height: 28))
    }

    @Test
    func measuredCapsuleInteriorIsInteractive() {
        #expect(PickyCaptureContextControlHitTestPolicy.contains(
            CGPoint(x: 210, y: 28),
            visibleContentFrame: visibleContentFrame,
            hostingViewSize: hostingViewSize
        ))
    }

    @Test
    func transparentPanelMarginsPassThrough() {
        #expect(!PickyCaptureContextControlHitTestPolicy.contains(
            CGPoint(x: 20, y: 28),
            visibleContentFrame: visibleContentFrame,
            hostingViewSize: hostingViewSize
        ))
        #expect(!PickyCaptureContextControlHitTestPolicy.contains(
            CGPoint(x: 210, y: 6),
            visibleContentFrame: visibleContentFrame,
            hostingViewSize: hostingViewSize
        ))
    }

    @Test
    func missingMeasuredBoundsAreNotInteractive() {
        #expect(!PickyCaptureContextControlHitTestPolicy.contains(
            CGPoint(x: 210, y: 28),
            visibleContentFrame: .null,
            hostingViewSize: hostingViewSize
        ))
    }
}
