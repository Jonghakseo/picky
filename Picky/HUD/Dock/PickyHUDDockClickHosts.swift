//
//  PickyHUDDockClickHosts.swift
//  Picky
//
//  AppKit event owners for the dock: Pickle rows (click, long-press archive,
//  context menu, reorder handoff), the move handle, and resize handles.
//

import AppKit
import SwiftUI

// MARK: - Hit-test holes for SwiftUI buttons drawn above a host

/// Regions a click host declines so the SwiftUI buttons drawn above it can be
/// clicked. An `NSView` child always wins AppKit hit testing over a SwiftUI
/// view in the same hosting view, no matter which one is on top visually, so
/// the host has to opt out of those rects explicitly.
///
/// Each hole is one button's frame, not a full-height strip: a row is taller
/// than its 18pt action, and the band above and below the button still has to
/// open, long-press, and right-click like the rest of the row.
///
/// Holes change hit testing only. The host keeps its full bounds and tracking
/// area, so hover (which decides whether those buttons are shown at all) never
/// flickers as the holes appear and disappear.
struct PickyHUDDockClickHostHoles: Equatable {
    /// One button-sized region, measured inward from the host's leading or
    /// trailing edge and centered on its cross axis.
    struct Hole: Equatable {
        /// Distance from that edge to the button's near side.
        var inset: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    var leading: Hole?
    var trailing: Hole?

    static let none = PickyHUDDockClickHostHoles()

    func excludes(_ point: CGPoint, in bounds: CGRect) -> Bool {
        if let leading, leading.contains(point, in: bounds, minX: bounds.minX + leading.inset) { return true }
        if let trailing,
           trailing.contains(point, in: bounds, minX: bounds.maxX - trailing.inset - trailing.width) {
            return true
        }
        return false
    }
}

extension PickyHUDDockClickHostHoles.Hole {
    func contains(_ point: CGPoint, in bounds: CGRect, minX: CGFloat) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard point.x >= minX, point.x <= minX + width else { return false }
        return abs(point.y - bounds.midY) <= height / 2
    }
}

// MARK: - Dock icon clicks (AppKit-backed for immediate single-click open)

struct PickyHUDDockIconClickHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onOpen: () -> Void
    /// Trailing slot of the hovered row action, left to its SwiftUI button.
    var holes: PickyHUDDockClickHostHoles = .none
    var isScreenContextArmed: Bool
    var isScreenContextSticky: Bool
    var canCompact: Bool
    var canStop: Bool
    var onToggleScreenContextTarget: () -> Void
    var onToggleStickyScreenContextTarget: () -> Void
    var onCompact: () -> Void
    var onArchivePressing: (Bool) -> Void
    var onArchive: () -> Void
    var onStop: () -> Void
    /// Optional group-list actions appended to the shared Dock Pickle menu.
    var moveTargetGroups: [PickyDockGroup] = []
    var onMoveToGroup: (String) -> Void = { _ in }
    var onUngroup: (() -> Void)?
    /// Fired once when the cursor leaves the archive hold's stationary
    /// tolerance, signalling "this drag is now a reorder, not a long-press
    /// archive". Argument is the mouse-down point in screen coordinates,
    /// which the rail uses as the anchor for its rail-level drag tracker. All
    /// subsequent drag/up handling happens there, not on this NSView, so the
    /// drag survives this view being recreated when the preview reparents the
    /// icon across a group boundary.
    var onReorderHandoff: (NSPoint) -> Void = { _ in }

    final class Coordinator: NSObject {
        var onHoverChanged: ((Bool) -> Void)?
        var onOpen: (() -> Void)?
        var isScreenContextArmed = false
        var isScreenContextSticky = false
        var canCompact = false
        var canStop = false
        var onToggleScreenContextTarget: (() -> Void)?
        var onToggleStickyScreenContextTarget: (() -> Void)?
        var onCompact: (() -> Void)?
        var onArchivePressing: ((Bool) -> Void)?
        var onArchive: (() -> Void)?
        var onStop: (() -> Void)?
        var moveTargetGroups: [PickyDockGroup] = []
        var onMoveToGroup: ((String) -> Void)?
        var onUngroup: (() -> Void)?
        var onReorderHandoff: ((NSPoint) -> Void)?

        func clearCallbacks() {
            onHoverChanged = nil
            onOpen = nil
            onToggleScreenContextTarget = nil
            onToggleStickyScreenContextTarget = nil
            onCompact = nil
            onArchivePressing = nil
            onArchive = nil
            onStop = nil
            moveTargetGroups = []
            onMoveToGroup = nil
            onUngroup = nil
            onReorderHandoff = nil
        }

        @objc func toggleScreenContextTarget(_ sender: NSMenuItem) {
            onToggleScreenContextTarget?()
        }

        @objc func toggleStickyScreenContextTarget(_ sender: NSMenuItem) {
            onToggleStickyScreenContextTarget?()
        }

        @objc func compact(_ sender: NSMenuItem) {
            guard canCompact else { return }
            onCompact?()
        }

        @objc func archive(_ sender: NSMenuItem) {
            onArchive?()
        }

        @objc func stop(_ sender: NSMenuItem) {
            guard canStop else { return }
            onStop?()
        }

        @objc func moveToGroup(_ sender: NSMenuItem) {
            guard let groupID = sender.representedObject as? String else { return }
            onMoveToGroup?(groupID)
        }

        @objc func ungroup(_ sender: NSMenuItem) {
            onUngroup?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        applyCallbacks(to: context.coordinator)
        let view = PickyHUDDockIconClickNSView()
        view.coordinator = context.coordinator
        view.holes = holes
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyCallbacks(to: context.coordinator)
        if let view = nsView as? PickyHUDDockIconClickNSView, view.holes != holes {
            view.holes = holes
        }
    }

    private func applyCallbacks(to coordinator: Coordinator) {
        coordinator.onHoverChanged = onHoverChanged
        coordinator.onOpen = onOpen
        coordinator.isScreenContextArmed = isScreenContextArmed
        coordinator.isScreenContextSticky = isScreenContextSticky
        coordinator.canCompact = canCompact
        coordinator.canStop = canStop
        coordinator.onToggleScreenContextTarget = onToggleScreenContextTarget
        coordinator.onToggleStickyScreenContextTarget = onToggleStickyScreenContextTarget
        coordinator.onCompact = onCompact
        coordinator.onArchivePressing = onArchivePressing
        coordinator.onArchive = onArchive
        coordinator.onStop = onStop
        coordinator.moveTargetGroups = moveTargetGroups
        coordinator.onMoveToGroup = onMoveToGroup
        coordinator.onUngroup = onUngroup
        coordinator.onReorderHandoff = onReorderHandoff
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockIconClickNSView {
            view.cancelTransientInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.clearCallbacks()
    }
}

final class PickyHUDDockIconClickNSView: NSView {
    weak var coordinator: PickyHUDDockIconClickHost.Coordinator?
    var holes: PickyHUDDockClickHostHoles = .none
    private var trackingArea: NSTrackingArea?
    private var archiveWorkItem: DispatchWorkItem?
    /// Captured at mouseDown in **screen coordinates** (`NSEvent.mouseLocation`).
    /// Screen-space is essential because the moment a reorder lands, this
    /// NSView itself moves to a new slot — any local- or window-space anchor
    /// would become stale and produce wildly wrong deltas, which manifests as
    /// jitter and the icon falling behind the cursor.
    private var mouseDownScreenPoint: NSPoint?
    private var didCompleteArchiveHold = false
    /// True once the drag crossed the reorder threshold and was handed off to
    /// the rail-level drag controller. From that point this view does nothing
    /// for the drag — an app-level event monitor owns it — so the drag is
    /// unaffected when SwiftUI recreates this view.
    private var handedOffReorder = false

    override var isFlipped: Bool { false }

    deinit {
        cancelTransientInteraction(notifyingCallbacks: false)
    }

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
        let local = convert(point, from: superview)
        guard bounds.contains(local), !holes.excludes(local, in: bounds) else { return nil }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        mouseDownScreenPoint = NSEvent.mouseLocation
        didCompleteArchiveHold = false
        handedOffReorder = false
        guard event.clickCount == 1 else { return }
        coordinator?.onArchivePressing?(true)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.didCompleteArchiveHold = true
            self.coordinator?.onArchive?()
        }
        archiveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PickyHUDArchiveHoldPolicy.duration, execute: item)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        cancelArchiveHoldFeedback()
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        handedOffReorder = false
        coordinator?.onHoverChanged?(true)
        guard let coordinator else { return }

        let menu = NSMenu()
        let stickyConversationItem = menuItem(
            title: L10n.t(
                coordinator.isScreenContextSticky
                    ? "dock.contextMenu.unpinInput"
                    : "dock.contextMenu.pinInput"
            ),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleStickyScreenContextTarget(_:)),
            target: coordinator
        )
        stickyConversationItem.state = coordinator.isScreenContextSticky ? .on : .off
        menu.addItem(stickyConversationItem)

        // A sticky conversation target already owns the screen-context route,
        // so its explicit stop action above replaces the otherwise duplicate
        // one-shot context toggle.
        if !coordinator.isScreenContextSticky {
            menu.addItem(menuItem(
                title: L10n.t(
                    coordinator.isScreenContextArmed
                        ? "dock.contextMenu.cancelNextInput"
                        : "dock.contextMenu.sendNextInput"
                ),
                action: #selector(PickyHUDDockIconClickHost.Coordinator.toggleScreenContextTarget(_:)),
                target: coordinator
            ))
        }
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.compact"),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.compact(_:)),
            target: coordinator,
            isEnabled: coordinator.canCompact
        ))
        if !coordinator.moveTargetGroups.isEmpty || coordinator.onUngroup != nil {
            menu.addItem(.separator())
            if !coordinator.moveTargetGroups.isEmpty {
                let moveItem = NSMenuItem(title: L10n.t("group.list.menu.move"), action: nil, keyEquivalent: "")
                let moveMenu = NSMenu(title: L10n.t("group.list.menu.move"))
                for group in coordinator.moveTargetGroups {
                    let item = menuItem(
                        title: group.displayName,
                        action: #selector(PickyHUDDockIconClickHost.Coordinator.moveToGroup(_:)),
                        target: coordinator
                    )
                    item.representedObject = group.id
                    moveMenu.addItem(item)
                }
                moveItem.submenu = moveMenu
                menu.addItem(moveItem)
            }
            if coordinator.onUngroup != nil {
                menu.addItem(menuItem(
                    title: L10n.t("group.list.menu.ungroup"),
                    action: #selector(PickyHUDDockIconClickHost.Coordinator.ungroup(_:)),
                    target: coordinator
                ))
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.archive"),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.archive(_:)),
            target: coordinator
        ))
        menu.addItem(menuItem(
            title: L10n.t("dock.contextMenu.stop"),
            action: #selector(PickyHUDDockIconClickHost.Coordinator.stop(_:)),
            target: coordinator,
            isEnabled: coordinator.canStop
        ))

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(title: String, action: Selector, target: AnyObject, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        return item
    }

    override func mouseDragged(with event: NSEvent) {
        guard !handedOffReorder, let anchor = mouseDownScreenPoint else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // Same threshold as archive cancel — so the moment the user clearly
        // commits to moving the cursor, archive intent gives way to reorder.
        // Hand the drag off to the rail-level controller and stop tracking it
        // here; the controller's app-level monitor takes over from the next
        // event onward (and swallows it so we don't double-handle).
        if distance > PickyHUDArchiveHoldPolicy.maximumDistance {
            cancelArchiveHoldFeedback()
            handedOffReorder = true
            coordinator?.onReorderHandoff?(anchor)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedArchive = didCompleteArchiveHold
        let wasHandedOff = handedOffReorder
        cancelArchiveHoldFeedback()
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        handedOffReorder = false
        // When the drag was handed off the rail controller owns its end; the
        // app-level monitor normally swallows this mouseUp before it reaches
        // us, but guard anyway so a click isn't synthesized.
        if wasHandedOff { return }
        guard !completedArchive else { return }
        coordinator?.onOpen?()
    }

    private func cancelArchiveHoldFeedback() {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        coordinator?.onArchivePressing?(false)
    }

    func cancelTransientInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        archiveWorkItem?.cancel()
        archiveWorkItem = nil
        mouseDownScreenPoint = nil
        didCompleteArchiveHold = false
        // Note: a handed-off reorder is owned by the rail-level controller, so
        // tearing this view down does NOT cancel the drag. That is the whole
        // point — the drag must survive the icon being recreated.
        handedOffReorder = false
        guard shouldNotify else { return }
        coordinator?.onArchivePressing?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // If SwiftUI removes the icon while a gesture is active, clear only the
        // AppKit-side state here. The SwiftUI state is reset by the icon's
        // onDisappear path, avoiding synchronous @State writes from teardown.
        if window == nil {
            cancelTransientInteraction(notifyingCallbacks: false)
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Dock anchor handle (AppKit-backed for reliable hit testing)

/// AppKit-backed handle for dragging the HUD dock's vertical anchor. Wrapping an
/// `NSView` directly avoids SwiftUI's transparent-view hit-testing quirks: AppKit's
/// `hitTest`, `NSTrackingArea`, and `addCursorRect` all key off the same NSView
/// bounds, so click + hover + cursor reliably react to the entire frame instead of
/// just the visible 22×4 capsule that SwiftUI's gesture system kept latching onto.
struct PickyHUDDockAnchorHandleHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onDragChanged: (CGPoint) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void
    var onClick: (() -> Void)? = nil

    final class Coordinator {
        var onHoverChanged: ((Bool) -> Void)?
        var onDragChanged: ((CGPoint) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onClick: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onClick = onClick
        let view = PickyHUDDockAnchorHandleNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onClick = onClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let view = nsView as? PickyHUDDockAnchorHandleNSView {
            view.cancelInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.onHoverChanged = nil
        coordinator.onDragChanged = nil
        coordinator.onDragEnded = nil
        coordinator.onDoubleClick = nil
        coordinator.onClick = nil
    }
}

struct PickyHUDCardResizeHandleHost: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void
    var onDragChanged: (CGPoint) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void
    var cursor: NSCursor = .resizeLeftRight

    final class Coordinator {
        var onHoverChanged: ((Bool) -> Void)?
        var onDragChanged: ((CGPoint) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        let view = PickyHUDCardResizeHandleNSView()
        view.coordinator = context.coordinator
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        context.coordinator.onDoubleClick = onDoubleClick
        if let view = nsView as? PickyHUDCardResizeHandleNSView, view.cursor != cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // SwiftUI may dismantle the representable while it is already reading the
        // body that owns these closures. Calling back into `@State` from this
        // teardown path can trip Swift's exclusivity checker, so only clear the
        // AppKit-side interaction state here. The SwiftUI state is reset by the
        // card's `onDisappear` handler.
        if let view = nsView as? PickyHUDCardResizeHandleNSView {
            view.cancelInteraction(notifyingCallbacks: false)
            view.coordinator = nil
        }
        coordinator.onHoverChanged = nil
        coordinator.onDragChanged = nil
        coordinator.onDragEnded = nil
        coordinator.onDoubleClick = nil
    }
}

final class PickyHUDCardResizeHandleNSView: NSView {
    weak var coordinator: PickyHUDCardResizeHandleHost.Coordinator?
    var cursor: NSCursor = .resizeLeftRight
    private var dragStartScreenPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    deinit {
        cancelInteraction(notifyingCallbacks: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelInteraction(notifyingCallbacks: false)
        } else {
            reconcileHoverState()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        reconcileHoverState()
    }

    func cancelInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        let wasDragging = dragStartScreenPoint != nil
        dragStartScreenPoint = nil
        guard shouldNotify else { return }
        coordinator?.onHoverChanged?(false)
        if wasDragging {
            coordinator?.onDragEnded?()
        }
    }

    private func reconcileHoverState() {
        guard let window else {
            coordinator?.onHoverChanged?(false)
            return
        }
        let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        coordinator?.onHoverChanged?(bounds.contains(pointInView))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragStartScreenPoint = nil
            coordinator?.onDoubleClick?()
            return
        }
        dragStartScreenPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartScreenPoint else { return }
        coordinator?.onDragChanged?(
            CGPoint(
                x: NSEvent.mouseLocation.x - startPoint.x,
                y: NSEvent.mouseLocation.y - startPoint.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragStartScreenPoint != nil
        dragStartScreenPoint = nil
        if wasDragging {
            coordinator?.onDragEnded?()
        }
        reconcileHoverState()
    }

    override var acceptsFirstResponder: Bool { false }
}

final class PickyHUDDockAnchorHandleNSView: NSView {
    weak var coordinator: PickyHUDDockAnchorHandleHost.Coordinator?
    private var dragStartScreenPoint: CGPoint?
    private var hasDragged = false
    private weak var capturedPanel: PickyHUDPanel?
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var trackingArea: NSTrackingArea?
    private var hasClosedHandPushed = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit {
        cancelInteraction(notifyingCallbacks: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelInteraction(notifyingCallbacks: false)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
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
        // Capture all hits inside our bounds. Without this, AppKit could fall
        // through to a sibling/parent view if some subview opts out.
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 && coordinator?.onClick == nil {
            dragStartScreenPoint = nil
            coordinator?.onDoubleClick?()
            return
        }
        dragStartScreenPoint = pointerLocation()
        hasDragged = false
        if let panel = window as? PickyHUDPanel, panel.isDockMinimized {
            capturedPanel = panel
            panel.setMinimizedPointerCapture(true)
        }
        if !hasClosedHandPushed {
            NSCursor.closedHand.push()
            hasClosedHandPushed = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartScreenPoint else { return }
        let point = pointerLocation()
        let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
        if coordinator?.onClick != nil && !hasDragged && hypot(delta.x, delta.y) < 4 { return }
        hasDragged = true
        coordinator?.onDragChanged?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        let hadPress = dragStartScreenPoint != nil
        let wasDragging = hadPress && (hasDragged || coordinator?.onClick == nil)
        if hasClosedHandPushed {
            NSCursor.pop()
            hasClosedHandPushed = false
        }
        dragStartScreenPoint = nil
        hasDragged = false
        capturedPanel?.setMinimizedPointerCapture(false)
        capturedPanel = nil
        if wasDragging { coordinator?.onDragEnded?() }
        else if hadPress { coordinator?.onClick?() }
    }

    func cancelInteraction(notifyingCallbacks shouldNotify: Bool = true) {
        let wasDragging = dragStartScreenPoint != nil && (hasDragged || coordinator?.onClick == nil)
        if hasClosedHandPushed {
            NSCursor.pop()
            hasClosedHandPushed = false
        }
        dragStartScreenPoint = nil
        hasDragged = false
        capturedPanel?.setMinimizedPointerCapture(false)
        capturedPanel = nil
        guard shouldNotify else { return }
        coordinator?.onHoverChanged?(false)
        if wasDragging {
            coordinator?.onDragEnded?()
        }
    }

    override var acceptsFirstResponder: Bool { false }
}
