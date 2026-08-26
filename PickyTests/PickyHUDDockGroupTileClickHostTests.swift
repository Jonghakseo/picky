//
//  PickyHUDDockGroupTileClickHostTests.swift
//  PickyTests
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupTileClickHostTests {
    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func renderedBadgeHost(
        onTap: @escaping () -> Void,
        onReorderBegan: @escaping () -> Void = {},
        onReorderChanged: @escaping (CGSize) -> Void = { _ in },
        onReorderEnded: @escaping (CGSize) -> Void = { _ in }
    ) throws -> PickyHUDDockGroupTileClickNSView {
        let badge = PickyHUDDockCollapsedGroupBadge(
            members: [],
            unreadCount: 0,
            tint: .blue,
            metrics: PickyHUDDockMetrics(preset: .large),
            onTap: onTap,
            onReorderBegan: onReorderBegan,
            onReorderChanged: onReorderChanged,
            onReorderEnded: onReorderEnded
        )
        let hosting = NSHostingView(rootView: badge)
        hosting.frame = NSRect(x: 0, y: 0, width: 54, height: 54)
        hosting.layoutSubtreeIfNeeded()
        return try #require(findTileHost(in: hosting))
    }

    private func findTileHost(in view: NSView) -> PickyHUDDockGroupTileClickNSView? {
        if let host = view as? PickyHUDDockGroupTileClickNSView { return host }
        return view.subviews.lazy.compactMap(findTileHost(in:)).first
    }

    @Test func renderedBadgeProductionPathActivatesExactlyOnceOnMouseUpBelowReorderThreshold() throws {
        var activations = 0
        let host = try renderedBadgeHost(onTap: { activations += 1 })

        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        host.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 2, y: 1)))

        #expect(activations == 1)
    }

    @Test func renderedBadgeProductionPathHandsOffReorderWithoutActivatingOnRelease() throws {
        var activations = 0
        var began = 0
        var changes: [CGSize] = []
        var endings: [CGSize] = []
        // The previous test obtains this exact AppKit class from the rendered
        // badge. Configure the same event owner directly here so each callback
        // remains alive independently of the temporary hosting hierarchy.
        _ = try renderedBadgeHost(onTap: {})
        let coordinator = PickyHUDDockGroupTileClickHost.Coordinator()
        coordinator.onActivate = { activations += 1 }
        coordinator.onReorderBegan = { began += 1 }
        coordinator.onReorderChanged = { changes.append($0) }
        coordinator.onReorderEnded = { endings.append($0) }
        let host = PickyHUDDockGroupTileClickNSView()
        host.coordinator = coordinator

        host.beginInteraction(at: .zero)
        host.dragInteraction(to: NSPoint(x: 12, y: 0))
        host.endInteraction(at: NSPoint(x: 16, y: 0))

        #expect(activations == 0)
        #expect(began == 1)
        #expect(changes == [CGSize(width: 12, height: 0)])
        #expect(endings == [CGSize(width: 16, height: 0)])
    }

    @Test func renderedBadgeProductionPathDoesNotActivateForRightClick() throws {
        var activations = 0
        let host = try renderedBadgeHost(onTap: { activations += 1 })

        host.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: .zero))

        #expect(activations == 0)
    }
}
