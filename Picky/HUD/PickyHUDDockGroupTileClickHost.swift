//
//  PickyHUDDockGroupTileClickHost.swift
//  Picky
//
//  The folder badge has one native event owner. It decides primary click
//  versus group reordering before SwiftUI modifiers can compete for mouse-up.
//

import AppKit
import SwiftUI

struct PickyHUDDockGroupTileClickHost: NSViewRepresentable {
    var onHover: () -> Void
    var onActivate: () -> Void
    var onReorderBegan: () -> Void
    var onReorderChanged: (CGSize) -> Void
    var onReorderEnded: (CGSize) -> Void

    final class Coordinator: NSObject {
        var onHover: (() -> Void)?
        var onActivate: (() -> Void)?
        var onReorderBegan: (() -> Void)?
        var onReorderChanged: ((CGSize) -> Void)?
        var onReorderEnded: ((CGSize) -> Void)?

        func clearCallbacks() {
            onHover = nil
            onActivate = nil
            onReorderBegan = nil
            onReorderChanged = nil
            onReorderEnded = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        applyCallbacks(to: context.coordinator)
        let view = PickyHUDDockGroupTileClickNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyCallbacks(to: context.coordinator)
    }

    private func applyCallbacks(to coordinator: Coordinator) {
        coordinator.onHover = onHover
        coordinator.onActivate = onActivate
        coordinator.onReorderBegan = onReorderBegan
        coordinator.onReorderChanged = onReorderChanged
        coordinator.onReorderEnded = onReorderEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockGroupTileClickNSView {
            view.cancelInteraction()
            view.coordinator = nil
        }
        coordinator.clearCallbacks()
    }
}

final class PickyHUDDockGroupTileClickNSView: NSView {
    weak var coordinator: PickyHUDDockGroupTileClickHost.Coordinator?
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var isReordering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }
        beginInteraction(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        dragInteraction(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        endInteraction(at: event.locationInWindow)
    }

    /// These state-machine entries are deliberately shared with AppKit event
    /// overrides so tests drive the rendered badge's real event owner rather
    /// than an activation coordinator detached from pointer delivery.
    func beginInteraction(at point: NSPoint) {
        mouseDownPoint = point
        isReordering = false
    }

    func dragInteraction(to point: NSPoint) {
        guard let mouseDownPoint else { return }
        let translation = CGSize(width: point.x - mouseDownPoint.x, height: point.y - mouseDownPoint.y)
        if !isReordering {
            let distance = hypot(translation.width, translation.height)
            guard distance > PickyHUDArchiveHoldPolicy.maximumDistance else { return }
            isReordering = true
            coordinator?.onReorderBegan?()
        }
        coordinator?.onReorderChanged?(translation)
    }

    func endInteraction(at point: NSPoint) {
        guard let mouseDownPoint else { return }
        let translation = CGSize(width: point.x - mouseDownPoint.x, height: point.y - mouseDownPoint.y)
        let wasReordering = isReordering
        cancelInteraction()
        if wasReordering {
            coordinator?.onReorderEnded?(translation)
        } else {
            coordinator?.onActivate?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelInteraction()
        // Preserve the single SwiftUI context-menu modifier attached to the
        // badge's parent instead of constructing a second AppKit menu here.
        super.rightMouseDown(with: event)
    }

    func cancelInteraction() {
        mouseDownPoint = nil
        isReordering = false
    }
}
