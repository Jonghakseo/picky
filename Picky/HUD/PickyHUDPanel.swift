//
//  PickyHUDPanel.swift
//  Picky
//
//  AppKit panel adapters used by the HUD and its dock group list.
//

import AppKit

final class PickyHUDPanel: PickySecureSurfacePanel {
    override var canBecomeKey: Bool { !isDockMinimized }
    override var canBecomeMain: Bool { false }

    /// Retained layout space does not imply input ownership. Only reported
    /// visible chrome accepts pointer input, including while minimized.
    var isDockMinimized = false {
        didSet {
            guard oldValue != isDockMinimized else { return }
            if isDockMinimized {
                acceptsMouseMovedEventsBeforeMinimizing = acceptsMouseMovedEvents
                acceptsMouseMovedEvents = true
                resignFocusedControl()
                if isKeyWindow { resignKey() }
            } else {
                acceptsMouseMovedEvents = acceptsMouseMovedEventsBeforeMinimizing
            }
            synchronizeDockPointerMonitoring()
        }
    }
    var visibleChromeFrames: [CGRect] = [] {
        didSet { updateDockPointer(NSEvent.mouseLocation) }
    }
    /// Standalone surfaces (the archive undo toast) are opaque chrome edge to
    /// edge and never report `visibleChromeFrames`; they must not pass clicks
    /// through the way the dock's transparent layout reserve does.
    var ownsEntireFrameForPointer = false {
        didSet { updateDockPointer(NSEvent.mouseLocation) }
    }
    private var dockPointerMonitors: [Any] = []
    private var acceptsMouseMovedEventsBeforeMinimizing = false
    private var hasMinimizedPointerCapture = false
    private var hasExpandedPointerCapture = false

    deinit {
        for monitor in dockPointerMonitors { NSEvent.removeMonitor(monitor) }
    }

    func minimizeDockInput() {
        visibleChromeFrames = []
        isDockMinimized = true
    }

    func updateDockInput(isMinimized: Bool, visibleChromeFrames: [CGRect]) {
        isDockMinimized = isMinimized
        self.visibleChromeFrames = visibleChromeFrames
    }

    /// AppKit owns the entire press/drag sequence even if the pointer briefly
    /// leaves the restore control while the panel is repositioned or snaps edges.
    func setMinimizedPointerCapture(_ captured: Bool) {
        hasMinimizedPointerCapture = captured
        updateDockPointer(NSEvent.mouseLocation)
    }

    /// Keep the whole press/drag sequence with this panel, even when a drag
    /// moves outside the visible rail or card before mouse-up.
    func updateDockPointer(_ point: CGPoint) {
        ignoresMouseEvents = !ownsEntireFrameForPointer
            && !hasExpandedPointerCapture
            && !hasMinimizedPointerCapture
            && !PickyHUDInkPassThroughPolicy.contains(
                point, swiftUIFrames: visibleChromeFrames, panelFrame: frame
            )
    }

    func updateMinimizedDockPointer(_ point: CGPoint) {
        updateDockPointer(point)
    }

    private func synchronizeDockPointerMonitoring() {
        for monitor in dockPointerMonitors { NSEvent.removeMonitor(monitor) }
        dockPointerMonitors = []
        updateDockPointer(NSEvent.mouseLocation)
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard isVisible else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.updateDockPointer(NSEvent.mouseLocation)
        }) { dockPointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateDockPointer(NSEvent.mouseLocation)
            return event
        }) { dockPointerMonitors.append(local) }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        updateDockPointer(NSEvent.mouseLocation)
    }

    /// Bridges AppKit's window-close command into the display-local SwiftUI
    /// card state. The HUD panel itself stays alive because it also owns the dock.
    var onCloseRequested: (() -> Void)?

    override func performClose(_ sender: Any?) {
        guard !isDockMinimized else { return }
        guard let onCloseRequested else {
            super.performClose(sender)
            return
        }
        onCloseRequested()
    }

    /// Claim the key-equivalent path explicitly. Immediately after a
    /// nonactivating panel becomes key, AppKit may route the first Cmd+W here
    /// instead of through the SwiftUI-installed local keyDown monitor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isDockMinimized else { return false }
        if handlePickyCloseWindowShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Input intent is scoped to one panel. SwiftUI may briefly leave a panel
    /// as its own responder while preserving the mounted native input view;
    /// restore only this responder on the next key event, never when the panel
    /// becomes key, so a click can still choose a different control first.
    private weak var lastNativeInputResponder: NSView?

    /// Records native input only after AppKit accepted it as this panel's
    /// first responder. This also captures terminal focus because SwiftTerm's
    /// responder override is not open for subclassing.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if result,
           let responder = responder as? NSView,
           responder.window === self,
           responder is PickyIMENSTextView || responder is PickySwiftTermView {
            lastNativeInputResponder = responder
        }
        return result
    }

    /// Restores the panel's remembered native input only from an unintentional
    /// panel/window fallback. Any real current responder is user intent and
    /// must remain untouched.
    @discardableResult
    func restoreRememberedNativeInputResponderIfNeeded() -> Bool {
        guard isFirstResponderFallback else { return false }
        guard let responder = lastNativeInputResponder else { return false }
        guard responder.window === self, responder.acceptsFirstResponder else {
            if responder.window !== self {
                lastNativeInputResponder = nil
            }
            return false
        }
        return makeFirstResponder(responder)
    }

    override func sendEvent(_ event: NSEvent) {
        if !isDockMinimized && handlePickyCloseWindowShortcut(event) { return }
        if !isDockMinimized && (event.type == .leftMouseDown || event.type == .rightMouseDown) {
            hasExpandedPointerCapture = true
            PickyPerf.event("hud_panel_mouse_down")
            PickyPerf.interval("hud_panel_make_key") { makeKey() }
            if !clickHitsFocusedControl(event) {
                resignFocusedControl()
            }
        }
        if !isDockMinimized && event.type == .keyDown {
            restoreRememberedNativeInputResponderIfNeeded()
            if let terminal = focusedTerminalView,
               terminal.handleMacLineEditingShortcut(event) {
                return
            }
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            hasExpandedPointerCapture = false
            updateDockPointer(NSEvent.mouseLocation)
        }
    }

    var isFirstResponderFallback: Bool {
        PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(firstResponder, panel: self)
    }

    private var focusedTerminalView: PickySwiftTermView? {
        var currentView = firstResponder as? NSView
        while let view = currentView {
            if let terminal = view as? PickySwiftTermView { return terminal }
            currentView = view.superview
        }
        return nil
    }

    /// Re-clicking the already-focused control (e.g. the composer NSTextView)
    /// must not pre-emptively resign first responder. Doing so races with the
    /// composer's async SwiftUI focus binding: the resign queues an
    /// `isFocused = false` update, AppKit then re-focuses the text view via
    /// the click's natural hit-test, but the coordinator's guard suppresses
    /// the corrective `isFocused = true` dispatch (state still reads true),
    /// leaving the stale `false` to win and flip focus off on the second
    /// click. Outside-focused-control clicks still resign so the
    /// "clear focus before collapse" contract holds.
    func clickHitsFocusedControl(_ event: NSEvent) -> Bool {
        guard let focused = firstResponder as? NSView, focused.window === self else {
            return false
        }
        let pointInFocused = focused.convert(event.locationInWindow, from: nil)
        return focused.bounds.contains(pointInFocused)
    }

    @discardableResult
    func resignFocusedControl() -> Bool {
        guard firstResponder != nil else {
            lastNativeInputResponder = nil
            return false
        }
        let didResign = makeFirstResponder(nil)
        if didResign {
            lastNativeInputResponder = nil
        }
        return didResign
    }

    /// The overlay manager owns the observable projection; this panel only
    /// reports AppKit's post-ordering visibility so secure-surface suppression
    /// and restoration follow the real `NSPanel` state.
    var onActualVisibilityChanged: ((Bool) -> Void)?

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        reportActualVisibility()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        reportActualVisibility()
    }

    override func orderOutForSecureSurfaceSuppression() {
        super.orderOutForSecureSurfaceSuppression()
        reportActualVisibility()
    }

    private func reportActualVisibility() {
        synchronizeDockPointerMonitoring()
        onActualVisibilityChanged?(isVisible)
    }
}

