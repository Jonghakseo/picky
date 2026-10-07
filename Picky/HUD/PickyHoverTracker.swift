//
//  PickyHoverTracker.swift
//  Picky
//
//  Pointer hover for AppKit views that live inside scrolling content.
//

import AppKit

/// Owns one view's hover state and keeps it truthful when the content scrolls
/// under a stationary pointer.
///
/// The old per-view pattern rebuilt the tracking area in every
/// `updateTrackingAreas()`. Scrolling calls that, and removing an area the
/// pointer is inside never delivers `mouseExited`; the replacement starts
/// "outside" because the pointer already is, so the view stayed hovered.
/// Every row the pointer crossed while scrolling ended up stuck that way.
///
/// This tracker installs a single `.inVisibleRect` area for the view's
/// lifetime (AppKit keeps it in sync with the visible rect, so it never needs
/// rebuilding). While hovered, and only then, it re-checks the pointer when
/// the enclosing clip view scrolls or the view's geometry changes. Usually one
/// view is hovered, so a scroll frame costs one point-in-rect check.
@MainActor
final class PickyHoverTracker: NSObject {
    private(set) var isHovered = false
    var onChange: ((Bool) -> Void)?

    /// Pointer in the view's window base coordinates, or `nil` when it cannot
    /// be over the view (no window). Injected by tests.
    var pointerLocation: (NSView) -> NSPoint? = { view in
        view.window?.mouseLocationOutsideOfEventStream
    }

    private weak var view: NSView?
    private var trackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?

    init(view: NSView) {
        self.view = view
        super.init()
        installTrackingArea()
    }

    /// Call from the owner's `updateTrackingAreas()`. Geometry changed; a
    /// hovered view may have moved out from under the pointer.
    func viewGeometryDidChange() {
        reconcileIfHovered()
    }

    /// Call from the owner's `viewDidMoveToWindow()` when it has a window.
    func viewDidMoveToWindow() {
        reconcileIfHovered()
    }

    /// Drops hover without calling `onChange`. For teardown paths where the
    /// owner must not write SwiftUI state synchronously.
    func resetWithoutNotifying() {
        isHovered = false
        stopObservingClipView()
    }

    /// For hover the owner asserts outside tracking, such as a context menu
    /// opening or an interaction being cancelled.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if hovered { observeEnclosingClipView() } else { stopObservingClipView() }
        onChange?(hovered)
    }

    /// Re-checks a hovered view against the live pointer and clears it when the
    /// pointer is no longer over the visible part of the view.
    func reconcileIfHovered() {
        guard isHovered else { return }
        guard let view, let point = pointerLocation(view) else {
            clearStaleHover()
            return
        }
        let local = view.convert(point, from: nil)
        // `visibleRect` alone can exceed `bounds` (seen before the window has
        // drawn), so require both.
        if !view.bounds.intersection(view.visibleRect).contains(local) {
            clearStaleHover()
        }
    }

    // MARK: Tracking area owner messages
    // The tracking area targets the tracker directly. Owner views also forward
    // their own `mouseEntered`/`mouseExited` here so direct calls keep working.

    @objc(mouseEntered:)
    func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    @objc(mouseExited:)
    func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    // MARK: Private

    private func installTrackingArea() {
        guard let view else { return }
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }

    /// The pointer is outside, but AppKit may still consider it inside this
    /// area and would then skip the next `mouseEntered`. Re-adding the area
    /// while the pointer is outside resets AppKit to "outside" too. This runs
    /// only on a stale clear, never per scroll frame.
    private func clearStaleHover() {
        installTrackingArea()
        setHovered(false)
    }

    private func observeEnclosingClipView() {
        guard let clipView = view?.enclosingScrollView?.contentView else { return }
        guard clipView !== observedClipView else { return }
        stopObservingClipView()
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        observedClipView = clipView
    }

    private func stopObservingClipView() {
        guard let clipView = observedClipView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
        observedClipView = nil
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        reconcileIfHovered()
    }
}
