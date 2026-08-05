//
//  PickyInkWindowContentHitTestTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

/// Content view that only claims points inside `hittableRect`, mimicking
/// `NSHostingView` returning nil over transparent SwiftUI regions.
private final class PartialHitContentView: NSView {
    var hittableRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return hittableRect.contains(localPoint) ? self : nil
    }
}

@MainActor
struct PickyInkWindowContentHitTestTests {
    private func makePanel() -> (NSPanel, PartialHitContentView) {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let contentView = PartialHitContentView()
        panel.contentView = contentView
        return (panel, contentView)
    }

    @Test
    func claimsPointOverHittableContent() {
        let (panel, contentView) = makePanel()
        defer { panel.orderOut(nil) }
        contentView.hittableRect = CGRect(x: 0, y: 0, width: 50, height: 100)
        panel.orderFrontRegardless()

        #expect(PickyInkWindowContentHitTest.windowClaimsGlobalPoint(
            panel,
            point: CGPoint(x: 110, y: 110)
        ))
    }

    @Test
    func rejectsPointOverTransparentRegionInsideFrame() {
        let (panel, contentView) = makePanel()
        defer { panel.orderOut(nil) }
        contentView.hittableRect = CGRect(x: 0, y: 0, width: 50, height: 100)
        panel.orderFrontRegardless()

        #expect(!PickyInkWindowContentHitTest.windowClaimsGlobalPoint(
            panel,
            point: CGPoint(x: 250, y: 150)
        ))
    }

    @Test
    func rejectsPointOutsideWindowFrame() {
        let (panel, contentView) = makePanel()
        defer { panel.orderOut(nil) }
        contentView.hittableRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        panel.orderFrontRegardless()

        #expect(!PickyInkWindowContentHitTest.windowClaimsGlobalPoint(
            panel,
            point: CGPoint(x: 50, y: 50)
        ))
    }

    @Test
    func rejectsHiddenWindow() {
        let (panel, contentView) = makePanel()
        contentView.hittableRect = CGRect(x: 0, y: 0, width: 200, height: 100)

        #expect(!PickyInkWindowContentHitTest.windowClaimsGlobalPoint(
            panel,
            point: CGPoint(x: 110, y: 110)
        ))
    }
}
