//
//  PickyHUDCommandShortcutHintPolicy.swift
//  Picky
//
//  Window-scoped lifecycle policy for the transient Command shortcut hint.
//

import AppKit

enum PickyHUDCommandShortcutHintEvent {
    case modifierFlagsChanged(modifierFlags: NSEvent.ModifierFlags, isCurrentHUDPanelKey: Bool)
    case hudPanelDidResignKey(isCurrentHUDPanel: Bool)
}

enum PickyHUDCommandShortcutHintPolicy {
    /// How long Command must be held before shortcut badges appear.
    static let revealDelay: Duration = .seconds(1)

    static func visibility(
        current: Bool,
        after event: PickyHUDCommandShortcutHintEvent
    ) -> Bool {
        switch event {
        case let .modifierFlagsChanged(modifierFlags, isCurrentHUDPanelKey):
            isCurrentHUDPanelKey && modifierFlags.contains(.command)
        case let .hudPanelDidResignKey(isCurrentHUDPanel):
            isCurrentHUDPanel ? false : current
        }
    }
}

enum PickyHUDOptionModifierPolicy {
    static func isPressed(
        modifierFlags: NSEvent.ModifierFlags,
        isCurrentHUDPanelKey: Bool
    ) -> Bool {
        isCurrentHUDPanelKey && modifierFlags.contains(.option)
    }
}
