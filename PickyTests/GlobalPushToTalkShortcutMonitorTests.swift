//
//  GlobalPushToTalkShortcutMonitorTests.swift
//  PickyTests
//
//  Covers the tap-disabled recovery decision used to unstick PTT when
//  CGEventTap loses the corresponding key release. The decision must
//  preserve any in-flight recording when the user is still physically
//  holding the shortcut.
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct GlobalPushToTalkShortcutMonitorTests {
    @Test func reconcileNoOpWhenNotPressed() {
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control, .option], keyCode: nil),
            isShortcutCurrentlyPressed: false,
            currentModifierFlags: []
        )
        #expect(shouldSynthesizeRelease == false)
    }

    @Test func reconcileSynthesizesReleaseWhenModifiersDroppedForModifierOnlySpec() {
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control, .option], keyCode: nil),
            isShortcutCurrentlyPressed: true,
            currentModifierFlags: []
        )
        #expect(shouldSynthesizeRelease == true)
    }

    @Test func reconcileKeepsPressedWhenModifiersStillHeldForModifierOnlySpec() {
        // Tap may disable mid-utterance while the user is still holding PTT.
        // Synthesizing a release here would cut the recording short.
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control, .option], keyCode: nil),
            isShortcutCurrentlyPressed: true,
            currentModifierFlags: [.control, .option]
        )
        #expect(shouldSynthesizeRelease == false)
    }

    @Test func reconcileKeepsPressedWhenModifiersHeldForKeyComboSpec() {
        // We cannot probe key state for combos, so we trust modifiers as a
        // proxy: if modifiers are still held, leave the pressed state alone
        // and let the real keyUp resolve it.
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control], keyCode: 49),
            isShortcutCurrentlyPressed: true,
            currentModifierFlags: [.control]
        )
        #expect(shouldSynthesizeRelease == false)
    }

    @Test func reconcileSynthesizesReleaseWhenModifiersDroppedForKeyComboSpec() {
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control], keyCode: 49),
            isShortcutCurrentlyPressed: true,
            currentModifierFlags: []
        )
        #expect(shouldSynthesizeRelease == true)
    }

    @Test func reconcileIgnoresTransientCapsLockFlag() {
        // System modifierFlags can include capsLock; spec's required modifiers
        // are device-independent. We must still detect "modifiers still held"
        // when only capsLock differs.
        let shouldSynthesizeRelease = GlobalPushToTalkShortcutMonitor.reconcileStuckPressedState(
            spec: .modifierCombo(modifiers: [.control, .option], keyCode: nil),
            isShortcutCurrentlyPressed: true,
            currentModifierFlags: [.control, .option, .capsLock]
        )
        #expect(shouldSynthesizeRelease == false)
    }
}
