//
//  BuddyPushToTalkShortcut.swift
//  Picky
//
//  Stateless transition decoder for the push-to-talk shortcut. The actual
//  shortcut spec is owned by `PickySettings` and reaches us through the
//  `GlobalPushToTalkShortcutMonitor`'s currently-installed spec.
//

import AppKit

enum BuddyPushToTalkShortcut {
    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    /// Renders a short human label like `"control + option"` or `"control + space"`
    /// suitable for tooltips. Returns nil for shortcut shapes the PTT path can
    /// never trigger on (e.g. `.doubleTapModifier`).
    static func displayText(for spec: PickyShortcutSpec) -> String? {
        switch spec {
        case .modifierCombo(let modifiers, let keyCode):
            let modifierLabels = PickyShortcutKeyCap.modifierKeyCaps(for: modifiers).map { $0.label }
            let keyLabel = keyCode.flatMap { PickyShortcutKeyCodeMap.label(for: $0) }
            let parts = modifierLabels + (keyLabel.map { [$0] } ?? [])
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " + ")
        case .doubleTapModifier:
            return nil
        }
    }

    static func tooltipText(for spec: PickyShortcutSpec) -> String {
        guard let label = displayText(for: spec) else { return "push to talk" }
        return "push to talk (\(label))"
    }

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool,
        spec: PickyShortcutSpec
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
            spec: spec
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool,
        spec: PickyShortcutSpec
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
            spec: spec
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged: return .flagsChanged
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        default: return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged: return .flagsChanged
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        default: return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool,
        spec: PickyShortcutSpec
    ) -> ShortcutTransition {
        switch spec {
        case .modifierCombo(let requiredModifiers, let requiredKeyCode):
            if let requiredKeyCode {
                return modifierComboTransition(
                    eventType: shortcutEventType,
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
                    requiredModifiers: requiredModifiers,
                    requiredKeyCode: requiredKeyCode
                )
            }
            return modifierOnlyTransition(
                eventType: shortcutEventType,
                modifierFlags: modifierFlags,
                wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed,
                requiredModifiers: requiredModifiers
            )
        case .doubleTapModifier:
            // Double-tap shortcuts are not delivered through this path; the
            // QuickInputDoubleTapDetector owns them.
            return .none
        }
    }

    private static func modifierOnlyTransition(
        eventType: ShortcutEventType,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool,
        requiredModifiers: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        guard eventType == .flagsChanged, !requiredModifiers.isEmpty else { return .none }

        let isShortcutCurrentlyPressed = modifierFlags.contains(requiredModifiers)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        }
        if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
            return .released
        }
        return .none
    }

    private static func modifierComboTransition(
        eventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool,
        requiredModifiers: NSEvent.ModifierFlags,
        requiredKeyCode: UInt16
    ) -> ShortcutTransition {
        let modifiersHeld = requiredModifiers.isEmpty || modifierFlags.isSuperset(of: requiredModifiers)

        if eventType == .keyDown
            && keyCode == requiredKeyCode
            && modifiersHeld
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }
        if eventType == .keyUp
            && keyCode == requiredKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }
        return .none
    }
}
