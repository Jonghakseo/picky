//
//  PickyHUDDockGroupTileClickHost.swift
//  Picky
//
//  A group header has one native event owner. It decides primary click
//  (collapse/expand) versus group reordering before SwiftUI modifiers can
//  compete for mouse-up.
//

import AppKit
import SwiftUI

struct PickyHUDDockGroupTileClickHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onActivate: () -> Void
    /// Color dot and hovered `+`, left to their SwiftUI buttons.
    var holes: PickyHUDDockClickHostHoles = .none
    var onReorderBegan: () -> Void
    var onReorderChanged: (CGSize) -> Void
    var onReorderEnded: (CGSize) -> Void

    final class Coordinator: NSObject {
        var onHoverChanged: ((Bool) -> Void)?
        var onActivate: (() -> Void)?
        var onReorderBegan: (() -> Void)?
        var onReorderChanged: ((CGSize) -> Void)?
        var onReorderEnded: ((CGSize) -> Void)?

        func clearCallbacks() {
            onHoverChanged = nil
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
        view.holes = holes
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyCallbacks(to: context.coordinator)
        if let view = nsView as? PickyHUDDockGroupTileClickNSView, view.holes != holes {
            view.holes = holes
        }
    }

    private func applyCallbacks(to coordinator: Coordinator) {
        coordinator.onHoverChanged = onHoverChanged
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
    var holes: PickyHUDDockClickHostHoles = .none
    private var hoverTracker: PickyHoverTracker!
    private var mouseDownPoint: NSPoint?
    private var isReordering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverTracker = PickyHoverTracker(view: self)
        hoverTracker.onChange = { [weak self] in self?.coordinator?.onHoverChanged?($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverTracker.viewGeometryDidChange()
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTracker.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverTracker.mouseExited(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTracker.resetWithoutNotifying()
        } else {
            hoverTracker.viewDidMoveToWindow()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !holes.excludes(local, in: bounds) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            forwardContextMenu(with: event)
            return
        }
        guard event.clickCount == 1 else {
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
    /// overrides so tests drive the rendered header's real event owner.
    func beginInteraction(at point: NSPoint) {
        mouseDownPoint = point
        isReordering = false
    }

    func dragInteraction(to point: NSPoint) {
        guard let translation = swiftUITranslation(to: point) else { return }
        if !isReordering {
            let distance = hypot(translation.width, translation.height)
            guard distance > PickyHUDArchiveHoldPolicy.maximumDistance else { return }
            isReordering = true
            coordinator?.onReorderBegan?()
        }
        coordinator?.onReorderChanged?(translation)
    }

    func endInteraction(at point: NSPoint) {
        guard let translation = swiftUITranslation(to: point) else { return }
        let wasReordering = isReordering
        cancelInteraction()
        if wasReordering {
            coordinator?.onReorderEnded?(translation)
        } else {
            coordinator?.onActivate?()
        }
    }

    /// `locationInWindow` uses AppKit's bottom-up window coordinates, while
    /// SwiftUI drag translations use a top-down Y axis. Normalize the native
    /// path so it matches the SwiftUI `DragGesture` translation contract.
    private func swiftUITranslation(to point: NSPoint) -> CGSize? {
        guard let mouseDownPoint else { return nil }
        return CGSize(
            width: point.x - mouseDownPoint.x,
            height: mouseDownPoint.y - point.y
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelInteraction()
        forwardContextMenu(with: event)
    }

    /// The header is the hit-test owner, while the production menu modifier is
    /// attached to a SwiftUI ancestor. Forward secondary and Control-clicks to
    /// that ancestor's native menu owner instead of duplicating the menu in
    /// AppKit or treating the click as activation.
    func forwardContextMenu(with event: NSEvent) {
        guard let target = contextMenuForwardingTarget() else {
            super.rightMouseDown(with: event)
            return
        }
        target.rightMouseDown(with: event)
    }

    func contextMenuForwardingTarget() -> NSView? {
        var candidate = superview
        while let view = candidate {
            if view.menu != nil { return view }
            candidate = view.superview
        }
        return superview
    }

    func cancelInteraction() {
        mouseDownPoint = nil
        isReordering = false
    }
}
