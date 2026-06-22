//
//  QuickInputDoubleTapDetector.swift
//  Picky
//
//  Detects the user's Quick Input shortcut and emits an event with the
//  current cursor location. Two trigger flavors:
//
//  - `.doubleTapModifier(modifier)` — tap the modifier twice within
//    `doubleTapWindow`. A `pttGuardWindow` defends against natural
//    Control+Option PTT starts being mistaken for a Control double-tap.
//
//  - `.modifierCombo(modifiers, keyCode)` — single press of the combo. The
//    detector fires on keyDown when the modifier set is fully held.
//
//  The detector is fed by the shared CGEvent tap inside
//  `GlobalPushToTalkShortcutMonitor`, so we don't install a second tap.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Emitted whenever the user finishes a qualifying Quick Input shortcut press.
struct QuickInputDoubleTapEvent: Equatable {
    /// Global mouse location (AppKit screen coordinates) at the moment the
    /// trigger fired. Captured here so the panel manager can position itself
    /// even if the cursor moves before the next runloop.
    let mouseLocation: CGPoint
}

@MainActor
final class QuickInputDoubleTapDetector {
    /// Maximum gap between the first and second modifier press to be considered a double-tap.
    static let doubleTapWindow: TimeInterval = 0.35
    /// After a candidate modifier press, this much time must pass with no other
    /// modifier or key event before the press is committed. PTT (e.g. Control+Option)
    /// flips modifiers within a few ms; this kills the count before it fires.
    static let pttGuardWindow: TimeInterval = 0.08

    /// macOS keycodes for the four modifier physical keys we expose via the UI.
    /// `nil` value means there is no physical keyCode tracked specifically — the
    /// detector relies on the resulting flag set instead.
    private static let leftControlKeyCode: UInt16 = 59
    private static let rightControlKeyCode: UInt16 = 62
    private static let leftShiftKeyCode: UInt16 = 56
    private static let rightShiftKeyCode: UInt16 = 60
    private static let leftOptionKeyCode: UInt16 = 58
    private static let rightOptionKeyCode: UInt16 = 61
    private static let leftCommandKeyCode: UInt16 = 55
    private static let rightCommandKeyCode: UInt16 = 54
    private static let functionKeyCode: UInt16 = 63

    let eventPublisher = PassthroughSubject<QuickInputDoubleTapEvent, Never>()

    /// Currently-active Quick Input spec. Mutated by CompanionManager when the
    /// user saves a new shortcut.
    var currentShortcutSpec: PickyShortcutSpec = .defaultQuickInput {
        didSet { reset() }
    }

    private var firstPressAt: Date?
    /// Set when a candidate modifier press is observed but not yet committed.
    /// Any non-matching modifier or key event before the guard expires drops it.
    private var pendingPressAt: Date?
    private var pendingPressGuardTask: Task<Void, Never>?
    /// Per-modifier "key currently down" tracking so we don't double-count
    /// flagsChanged repeats.
    private var modifiersCurrentlyDown: NSEvent.ModifierFlags = []
    /// True while the spec's combo trigger is held — used to suppress repeats
    /// until the user releases at least one of the matching modifiers/keys.
    private var comboCurrentlyHeld = false

    /// Called from the global CGEvent tap callback for every flagsChanged /
    /// keyDown / keyUp event the system delivers. The detector is purely
    /// observational — it does not consume or modify events.
    func handleGlobalEvent(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)

        switch currentShortcutSpec {
        case .doubleTapModifier(let trackedModifier):
            handleForDoubleTap(
                eventType: eventType,
                keyCode: keyCode,
                flags: flags,
                trackedModifier: trackedModifier
            )
        case .modifierCombo(let requiredModifiers, let requiredKeyCode):
            handleForCombo(
                eventType: eventType,
                keyCode: keyCode,
                flags: flags,
                requiredModifiers: requiredModifiers,
                requiredKeyCode: requiredKeyCode
            )
        }
    }

    /// Resets internal state. Call when the host stops the global tap or the
    /// spec changes so a stale pending press doesn't fire on the next start.
    func reset() {
        firstPressAt = nil
        pendingPressAt = nil
        pendingPressGuardTask?.cancel()
        pendingPressGuardTask = nil
        modifiersCurrentlyDown = []
        comboCurrentlyHeld = false
    }

    // MARK: - Test entry points

    /// Test-friendly entry point that uses an injected clock instead of `Date()`.
    func handleFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        now: Date = Date()
    ) {
        guard case .doubleTapModifier(let trackedModifier) = currentShortcutSpec else { return }
        handleForDoubleTap(
            eventType: .flagsChanged,
            keyCode: keyCode,
            flags: flags,
            trackedModifier: trackedModifier,
            now: now
        )
    }

    /// Allows tests to drain the guard window without sleeping.
    func forceCommitPendingPressForTesting(at now: Date = Date()) {
        commitPendingPress(at: now)
    }

    var hasPendingPressForTesting: Bool { pendingPressAt != nil }
    var firstPressAtForTesting: Date? { firstPressAt }

    // MARK: - Double-tap path

    private func handleForDoubleTap(
        eventType: CGEventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        trackedModifier: NSEvent.ModifierFlags,
        now: Date = Date()
    ) {
        switch eventType {
        case .flagsChanged:
            handleDoubleTapFlagsChanged(
                keyCode: keyCode,
                flags: flags,
                trackedModifier: trackedModifier,
                now: now
            )
        case .keyDown, .keyUp:
            // Any real key press during a pending double-tap means the user is
            // typing or starting a modifier-modified shortcut, not double-tapping.
            cancelPendingPress()
        default:
            break
        }
    }

    private func handleDoubleTapFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        trackedModifier: NSEvent.ModifierFlags,
        now: Date
    ) {
        let isTrackedModifierKey = isPhysicalKeyCode(keyCode, in: trackedModifier)
        let trackedActive = flags.contains(trackedModifier)
        // We require the *only* modifier engaged to be the tracked one — any
        // other modifier means the user is starting a real shortcut combo.
        let onlyTrackedActive = trackedActive
            && flags.subtracting(trackedModifier)
                .intersection([.shift, .option, .command, .control, .function, .capsLock])
                .isEmpty

        if !isTrackedModifierKey {
            // A non-tracked modifier (or a different physical key event) —
            // any pending candidate must be discarded.
            cancelPendingPress()
            return
        }

        if trackedActive {
            // Modifier transitioned from up to down (real keypress) only when
            // it was previously up. flagsChanged events repeat for hold; we ignore those.
            guard !modifiersCurrentlyDown.contains(trackedModifier) else { return }
            modifiersCurrentlyDown.insert(trackedModifier)

            guard onlyTrackedActive else {
                // The tracked modifier press arrived while another modifier is
                // already held — not a clean double-tap candidate.
                cancelPendingPress()
                firstPressAt = nil
                return
            }

            registerCandidatePress(at: now)
        } else {
            modifiersCurrentlyDown.remove(trackedModifier)
        }
    }

    private func registerCandidatePress(at now: Date) {
        if let firstPressAt, now.timeIntervalSince(firstPressAt) > Self.doubleTapWindow {
            self.firstPressAt = nil
        }

        pendingPressAt = now
        pendingPressGuardTask?.cancel()
        let guardWindow = Self.pttGuardWindow
        pendingPressGuardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(guardWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.commitPendingPress(at: Date())
            }
        }
    }

    private func cancelPendingPress() {
        pendingPressAt = nil
        pendingPressGuardTask?.cancel()
        pendingPressGuardTask = nil
    }

    private func commitPendingPress(at now: Date) {
        guard let pressedAt = pendingPressAt else { return }
        pendingPressAt = nil
        pendingPressGuardTask = nil

        if let firstPressAt, pressedAt.timeIntervalSince(firstPressAt) <= Self.doubleTapWindow {
            self.firstPressAt = nil
            emitDoubleTap()
            return
        }

        firstPressAt = pressedAt
    }

    private func emitDoubleTap() {
        let mouseLocation = NSEvent.mouseLocation
        eventPublisher.send(QuickInputDoubleTapEvent(mouseLocation: mouseLocation))
    }

    private func isPhysicalKeyCode(_ keyCode: UInt16, in modifier: NSEvent.ModifierFlags) -> Bool {
        switch modifier {
        case .control:
            return keyCode == Self.leftControlKeyCode || keyCode == Self.rightControlKeyCode
        case .shift:
            return keyCode == Self.leftShiftKeyCode || keyCode == Self.rightShiftKeyCode
        case .option:
            return keyCode == Self.leftOptionKeyCode || keyCode == Self.rightOptionKeyCode
        case .command:
            return keyCode == Self.leftCommandKeyCode || keyCode == Self.rightCommandKeyCode
        case .function:
            return keyCode == Self.functionKeyCode
        default:
            return false
        }
    }

    // MARK: - Combo path

    private func handleForCombo(
        eventType: CGEventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        requiredModifiers: NSEvent.ModifierFlags,
        requiredKeyCode: UInt16?
    ) {
        let modifiersHeld = requiredModifiers.isEmpty || flags.contains(requiredModifiers)

        switch eventType {
        case .keyDown:
            guard let requiredKeyCode else {
                // Modifier-only combos are not exposed as Quick Input triggers
                // because they would conflict with PTT's modifier-only style.
                return
            }
            if keyCode == requiredKeyCode && modifiersHeld && !comboCurrentlyHeld {
                comboCurrentlyHeld = true
                emitDoubleTap()
            }
        case .keyUp:
            if let requiredKeyCode, keyCode == requiredKeyCode {
                comboCurrentlyHeld = false
            }
        case .flagsChanged:
            // If the user releases any required modifier, treat the combo as ended.
            if !modifiersHeld { comboCurrentlyHeld = false }
        default:
            break
        }
    }
}
