//
//  PickyHUDPanel.swift
//  Picky
//
//  AppKit panel adapters used by the HUD and its dock group list.
//

import AppKit

final class PickyHUDPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
            if !clickHitsFocusedControl(event) {
                resignFocusedControl()
            }
        }
        if event.type == .keyDown {
            restoreRememberedNativeInputResponderIfNeeded()
            if let terminal = focusedTerminalView,
               terminal.handleMacLineEditingShortcut(event) {
                return
            }
        }
        super.sendEvent(event)
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
        onActualVisibilityChanged?(isVisible)
    }
}

/// The child list temporarily owns key input only while its inline name field
/// is active. Keeping this decision value-based makes restoration safe to test
/// without relying on WindowServer ordering.
enum PickyHUDDockGroupListPanelKeyPolicy {
    static func shouldRestoreOwningHUDKey(isEditing: Bool, isChildPanelKeyWindow: Bool) -> Bool {
        !isEditing && isChildPanelKeyWindow
    }
}

final class PickyHUDDockGroupListPanel: PickySecureSurfacePanel, PickyScreenCaptureExcludedWindow, PickyHUDDockGroupListContentHost {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: bufferingType, defer: flag)
        becomesKeyOnlyIfNeeded = true
    }

    func setDockGroupListContentView(_ contentView: NSView?) {
        self.contentView = contentView
    }
}
