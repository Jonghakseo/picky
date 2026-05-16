//
//  PickyShortcutSpecTests.swift
//  PickyTests
//
//  Round-trip serialization and conflict / display behaviour for the shared
//  shortcut spec model.
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyShortcutSpecTests {
    @Test func defaultsAreValid() {
        #expect(PickyShortcutSpec.defaultPushToTalk.isValid)
        #expect(PickyShortcutSpec.defaultQuickInput.isValid)
    }

    @Test func emptyModifierComboIsInvalid() {
        let spec = PickyShortcutSpec.modifierCombo(modifiers: [], keyCode: nil)
        #expect(spec.isValid == false)
    }

    @Test func doubleTapWithMultipleModifiersIsInvalid() {
        let spec = PickyShortcutSpec.doubleTapModifier([.control, .option])
        #expect(spec.isValid == false)
    }

    @Test func keyCapsForControlOptionRenderInCanonicalOrder() {
        let spec = PickyShortcutSpec.modifierCombo(modifiers: [.control, .option], keyCode: nil)
        #expect(spec.keyCaps.map(\.label) == ["control", "option"])
    }

    @Test func keyCapsForDoubleTapShowSameModifierTwice() {
        let spec = PickyShortcutSpec.doubleTapModifier(.control)
        #expect(spec.keyCaps.map(\.label) == ["control", "control"])
    }

    @Test func keyCapsForComboAppendsKeyCap() {
        let spec = PickyShortcutSpec.modifierCombo(modifiers: [.shift], keyCode: 6) // Z
        #expect(spec.keyCaps.map(\.label) == ["shift", "Z"])
    }

    @Test func conflictsBetweenDoubleTapAndModifierOnly() {
        let modifierOnly = PickyShortcutSpec.modifierCombo(modifiers: .control, keyCode: nil)
        let doubleTap = PickyShortcutSpec.doubleTapModifier(.control)
        #expect(modifierOnly.conflicts(with: doubleTap))
        #expect(doubleTap.conflicts(with: modifierOnly))
    }

    @Test func doubleTapDoesNotConflictWithComboUsingDifferentModifier() {
        let combo = PickyShortcutSpec.modifierCombo(modifiers: [.control, .option], keyCode: nil)
        let doubleTap = PickyShortcutSpec.doubleTapModifier(.shift)
        #expect(combo.conflicts(with: doubleTap) == false)
    }

    @Test func roundTripModifierCombo() throws {
        let original = PickyShortcutSpec.modifierCombo(modifiers: [.control, .option], keyCode: 49)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickyShortcutSpec.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func roundTripDoubleTap() throws {
        let original = PickyShortcutSpec.doubleTapModifier(.control)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickyShortcutSpec.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func decodingDropsTransientFlags() throws {
        // Persisted modifier flags should be filtered to the device-independent set.
        let original = PickyShortcutSpec.modifierCombo(
            modifiers: [.control, .option, .capsLock],
            keyCode: nil
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PickyShortcutSpec.self, from: encoded)
        if case .modifierCombo(let modifiers, _) = decoded {
            #expect(modifiers.contains(.control))
            #expect(modifiers.contains(.option))
        } else {
            #expect(Bool(false), "expected modifierCombo")
        }
    }
}

struct BuddyPushToTalkShortcutSpecMatchingTests {
    @Test func modifierOnlyComboTransitionsOnFlagsChanged() {
        let spec = PickyShortcutSpec.modifierCombo(modifiers: [.shift, .control], keyCode: nil)
        let pressed = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64((NSEvent.ModifierFlags([.shift, .control])).rawValue),
            wasShortcutPreviouslyPressed: false,
            spec: spec
        )
        #expect(pressed == .pressed)

        let released = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: 0,
            wasShortcutPreviouslyPressed: true,
            spec: spec
        )
        #expect(released == .released)
    }

    @Test func modifierComboWithKeyTransitionsOnKeyDownAndKeyUp() {
        let spec = PickyShortcutSpec.modifierCombo(modifiers: [.control, .option], keyCode: 49) // space

        let pressed = BuddyPushToTalkShortcut.shortcutTransition(
            for: .keyDown,
            keyCode: 49,
            modifierFlagsRawValue: UInt64((NSEvent.ModifierFlags([.control, .option])).rawValue),
            wasShortcutPreviouslyPressed: false,
            spec: spec
        )
        #expect(pressed == .pressed)

        let released = BuddyPushToTalkShortcut.shortcutTransition(
            for: .keyUp,
            keyCode: 49,
            modifierFlagsRawValue: UInt64((NSEvent.ModifierFlags([.control, .option])).rawValue),
            wasShortcutPreviouslyPressed: true,
            spec: spec
        )
        #expect(released == .released)
    }

    @Test func doubleTapSpecNeverFiresInPushToTalkPath() {
        let spec = PickyShortcutSpec.doubleTapModifier(.control)
        let result = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue),
            wasShortcutPreviouslyPressed: false,
            spec: spec
        )
        #expect(result == .none)
    }
}
