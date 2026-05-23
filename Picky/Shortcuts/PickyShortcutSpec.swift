//
//  PickyShortcutSpec.swift
//  Picky
//
//  Persisted, user-configurable description of a global shortcut. Two flavors:
//
//  - `.modifierCombo(modifiers, keyCode?)`
//      Fires when the modifier set is held (and, if `keyCode` is set, while
//      that key is pressed). Used for push-to-talk and for "Quick Input as a
//      single-press combo" cases.
//
//  - `.doubleTapModifier(modifier)`
//      Fires when the user taps the same modifier twice within the
//      QuickInputDoubleTapDetector's window. Used for "double-tap Control"
//      style triggers.
//
//  The display layer renders the spec as a row of key caps so the settings
//  UI matches the screenshot (chevrons for shift/ctrl/option/cmd, a magic
//  hat-style glyph for fn, raw text for letters/digits/space).
//

import AppKit
import Foundation

enum PickyShortcutSpec: Codable, Equatable {
    case modifierCombo(modifiers: NSEvent.ModifierFlags, keyCode: UInt16?)
    case doubleTapModifier(NSEvent.ModifierFlags)

    // MARK: - Defaults

    static let defaultPushToTalk: PickyShortcutSpec = .modifierCombo(
        modifiers: [.control, .option],
        keyCode: nil
    )

    static let defaultQuickInput: PickyShortcutSpec = .doubleTapModifier(.control)

    // MARK: - Public helpers

    /// Returns true when the spec is well-formed — a `modifierCombo` must
    /// either have at least one modifier or a non-modifier key, and a
    /// `doubleTapModifier` must contain exactly one modifier flag.
    var isValid: Bool {
        switch self {
        case .modifierCombo(let modifiers, let keyCode):
            return !modifiers.isEmpty || keyCode != nil
        case .doubleTapModifier(let modifier):
            return PickyShortcutKeyCap.singleModifierFlag(modifier) != nil
        }
    }

    /// Compact text form for inline summaries (Settings index subtitle, etc.).
    /// Uses standard macOS modifier glyphs (⌃⌥⇧⌘) so the spec collapses to one
    /// short string without the chip-row chrome the full key-cap view needs.
    /// A double-tap of a single modifier renders as the glyph repeated twice.
    var summaryString: String {
        switch self {
        case .modifierCombo(let modifiers, let keyCode):
            var parts: [String] = PickyShortcutKeyCap.orderedSingleModifiers.compactMap { modifier in
                guard modifiers.contains(modifier) else { return nil }
                return PickyShortcutKeyCap.modifierGlyph(for: modifier)
            }
            if let keyCode, let label = PickyShortcutKeyCodeMap.label(for: keyCode) {
                parts.append(label)
            }
            return parts.joined()
        case .doubleTapModifier(let modifier):
            guard let glyph = PickyShortcutKeyCap.modifierGlyph(for: modifier) else { return "" }
            return glyph + glyph
        }
    }

    /// Sequence of key caps to render in the UI, left-to-right.
    var keyCaps: [PickyShortcutKeyCap] {
        switch self {
        case .modifierCombo(let modifiers, let keyCode):
            var caps = PickyShortcutKeyCap.modifierKeyCaps(for: modifiers)
            if let keyCode, let nonModifierCap = PickyShortcutKeyCap.nonModifier(for: keyCode) {
                caps.append(nonModifierCap)
            }
            return caps
        case .doubleTapModifier(let modifier):
            // Render the same modifier twice so the user sees that the trigger
            // is two presses, matching the design reference.
            guard let cap = PickyShortcutKeyCap.modifierKeyCaps(for: modifier).first else {
                return []
            }
            return [cap, cap]
        }
    }

    /// True when two specs would clash (same modifier combo, or one is a
    /// double-tap of a modifier the other already uses on every press).
    func conflicts(with other: PickyShortcutSpec) -> Bool {
        switch (self, other) {
        case let (.modifierCombo(lhsMods, lhsKey), .modifierCombo(rhsMods, rhsKey)):
            return lhsMods == rhsMods && lhsKey == rhsKey
        case let (.doubleTapModifier(lhs), .doubleTapModifier(rhs)):
            return lhs == rhs
        case let (.modifierCombo(mods, keyCode), .doubleTapModifier(tapMod)),
             let (.doubleTapModifier(tapMod), .modifierCombo(mods, keyCode)):
            // A double-tap of <X> conflicts with a modifier-only spec that
            // *is* exactly <X>, because pressing <X> would arm the double-tap
            // counter every time the modifier-only spec fires.
            return keyCode == nil && mods == tapMod
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case modifiers
        case keyCode
    }

    private enum Kind: String, Codable {
        case modifierCombo
        case doubleTapModifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let modifiersRaw = try container.decode(UInt.self, forKey: .modifiers)
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)
            .intersection(.deviceIndependentFlagsMask)
        switch kind {
        case .modifierCombo:
            let keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
            self = .modifierCombo(modifiers: modifiers, keyCode: keyCode)
        case .doubleTapModifier:
            self = .doubleTapModifier(modifiers)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifierCombo(let modifiers, let keyCode):
            try container.encode(Kind.modifierCombo, forKey: .kind)
            try container.encode(modifiers.rawValue, forKey: .modifiers)
            try container.encodeIfPresent(keyCode, forKey: .keyCode)
        case .doubleTapModifier(let modifier):
            try container.encode(Kind.doubleTapModifier, forKey: .kind)
            try container.encode(modifier.rawValue, forKey: .modifiers)
        }
    }
}

// MARK: - Key cap rendering

/// Renderable description of a single key cap inside a shortcut row. The view
/// layer uses `glyph` (an SF Symbol or a literal character) and `label` to
/// build a small chip such as `[⌃ control]` or `[Z]`.
struct PickyShortcutKeyCap: Equatable, Identifiable {
    enum Style: Equatable {
        case modifier
        case nonModifier
    }

    let id: String
    let glyph: String?
    let label: String
    let style: Style

    // MARK: - Modifier helpers

    /// Returns true if `flags` contains exactly one modifier — otherwise the
    /// double-tap spec doesn't have a clean single key cap to render.
    static func singleModifierFlag(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let cleaned = flags.intersection(.deviceIndependentFlagsMask)
        let count = orderedSingleModifiers.reduce(into: 0) { count, mod in
            if cleaned.contains(mod) { count += 1 }
        }
        return count == 1 ? cleaned : nil
    }

    /// Decomposes a modifier set into key caps in the canonical macOS order
    /// (fn, control, option, shift, command).
    static func modifierKeyCaps(for flags: NSEvent.ModifierFlags) -> [PickyShortcutKeyCap] {
        let cleaned = flags.intersection(.deviceIndependentFlagsMask)
        return orderedSingleModifiers.compactMap { modifier -> PickyShortcutKeyCap? in
            guard cleaned.contains(modifier) else { return nil }
            return modifierCap(modifier)
        }
    }

    /// Builds a key cap for a non-modifier `keyCode`. Returns nil for keys we
    /// don't want to expose as shortcuts (escape, return) — those are reserved
    /// for the capture UI's own controls.
    static func nonModifier(for keyCode: UInt16) -> PickyShortcutKeyCap? {
        if let label = PickyShortcutKeyCodeMap.label(for: keyCode) {
            return PickyShortcutKeyCap(
                id: "key-\(keyCode)",
                glyph: nil,
                label: label,
                style: .nonModifier
            )
        }
        return nil
    }

    // MARK: - Internals

    /// Modifier ordering used in the key-cap row; matches the layout shown in
    /// macOS System Settings → Keyboard → Shortcuts. Internal so `summaryString`
    /// on `PickyShortcutSpec` can reuse the same canonical order.
    static let orderedSingleModifiers: [NSEvent.ModifierFlags] = [
        .function, .control, .option, .shift, .command
    ]

    /// Unicode glyph for a single modifier flag, used by compact summaries.
    /// Returns `nil` for unrecognised flags so callers can skip them silently.
    static func modifierGlyph(for modifier: NSEvent.ModifierFlags) -> String? {
        switch modifier {
        case .function: return "fn"
        case .control: return "\u{2303}"
        case .option: return "\u{2325}"
        case .shift: return "\u{21E7}"
        case .command: return "\u{2318}"
        default: return nil
        }
    }

    private static func modifierCap(_ modifier: NSEvent.ModifierFlags) -> PickyShortcutKeyCap {
        switch modifier {
        case .function:
            return PickyShortcutKeyCap(id: "mod-fn", glyph: "globe", label: "fn", style: .modifier)
        case .control:
            return PickyShortcutKeyCap(id: "mod-control", glyph: "control", label: "control", style: .modifier)
        case .option:
            return PickyShortcutKeyCap(id: "mod-option", glyph: "option", label: "option", style: .modifier)
        case .shift:
            return PickyShortcutKeyCap(id: "mod-shift", glyph: "shift", label: "shift", style: .modifier)
        case .command:
            return PickyShortcutKeyCap(id: "mod-command", glyph: "command", label: "command", style: .modifier)
        default:
            return PickyShortcutKeyCap(id: "mod-unknown", glyph: nil, label: "?", style: .modifier)
        }
    }
}

// MARK: - macOS keycode → label

/// Subset of US-layout keycodes we let users bind. The capture recorder
/// intentionally rejects keycodes that aren't in this map so we don't ship a
/// shortcut the UI cannot describe.
enum PickyShortcutKeyCodeMap {
    static let blacklistedKeyCodes: Set<UInt16> = [
        53, // escape — used by the capture UI to cancel
        36, // return — used by the capture UI to confirm
        76, // numpad enter
    ]

    static func label(for keyCode: UInt16) -> String? {
        if blacklistedKeyCodes.contains(keyCode) { return nil }
        return labels[keyCode]
    }

    private static let labels: [UInt16: String] = [
        // Letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // Digits
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        // Whitespace / arrows / function
        48: "tab", 49: "space", 51: "delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // Function row (most useful subset)
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]
}
