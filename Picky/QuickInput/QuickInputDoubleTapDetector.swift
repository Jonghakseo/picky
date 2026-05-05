//
//  QuickInputDoubleTapDetector.swift
//  Picky
//
//  Detects a Control-key double-tap that opens the Quick Input pill.
//  Listens to the same global CGEvent tap that drives push-to-talk so we
//  don't install a second tap. Control must be the only modifier engaged
//  for both presses, and any other key/modifier within `ptcGuardWindow`
//  cancels the in-progress double-tap (so a natural Control+Option PTT
//  start never accidentally fires the Quick Input).
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Emitted whenever the user finishes a qualifying Control-key double-tap.
struct QuickInputDoubleTapEvent: Equatable {
    /// Global mouse location (AppKit screen coordinates) at the moment the
    /// second Control press was detected. Captured here so the panel manager
    /// can position itself even if the cursor moves before the next runloop.
    let mouseLocation: CGPoint
}

@MainActor
final class QuickInputDoubleTapDetector {
    /// Maximum gap between the first and second Control press to be considered a double-tap.
    static let doubleTapWindow: TimeInterval = 0.35
    /// After a Control press, this much time must pass with no other modifier
    /// or key event before the press is committed. PTT (Control+Option) flips
    /// modifiers within a few ms, so this kills the count before it fires.
    static let pttGuardWindow: TimeInterval = 0.08

    /// macOS keycodes for the two physical Control keys.
    private static let leftControlKeyCode: UInt16 = 59
    private static let rightControlKeyCode: UInt16 = 62

    let eventPublisher = PassthroughSubject<QuickInputDoubleTapEvent, Never>()

    private var firstPressAt: Date?
    /// Set when a Control-only press is observed but not yet committed. If any
    /// non-Control modifier or key event arrives before the guard expires, the
    /// pending press is discarded.
    private var pendingPressAt: Date?
    private var pendingPressGuardTask: Task<Void, Never>?
    private var isControlCurrentlyDown = false

    /// Called from the global CGEvent tap callback for every flagsChanged /
    /// keyDown / keyUp event the system delivers. Returns nothing — the
    /// detector is purely observational.
    func handleGlobalEvent(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)

        switch eventType {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown, .keyUp:
            // Any real key press during a pending double-tap means the user is
            // typing or starting a Control-modified shortcut, not double-tapping.
            cancelPendingPress()
        default:
            break
        }
    }

    /// Resets internal state. Call when the host stops the global tap so a
    /// stale pending press doesn't fire on the next start.
    func reset() {
        firstPressAt = nil
        pendingPressAt = nil
        pendingPressGuardTask?.cancel()
        pendingPressGuardTask = nil
        isControlCurrentlyDown = false
    }

    // MARK: - Internal helpers (exposed for tests)

    /// Test-friendly entry point that uses an injected clock instead of `Date()`.
    func handleFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        now: Date = Date()
    ) {
        let isControlKey = keyCode == Self.leftControlKeyCode || keyCode == Self.rightControlKeyCode
        let controlActive = flags.contains(.control)
        let onlyControlActive = controlActive
            && flags.intersection([.shift, .option, .command, .function, .capsLock]).isEmpty

        if !isControlKey {
            // A non-Control modifier (Shift, Option, Command, Fn) toggled.
            // If we were waiting for a guard window to confirm, cancel.
            cancelPendingPress()
            return
        }

        if controlActive {
            // Control transitioned from up to down (real keypress) only when
            // we previously thought it was up. Modifier-only flagsChanged events
            // can repeat for hold; we ignore those.
            guard !isControlCurrentlyDown else { return }
            isControlCurrentlyDown = true

            guard onlyControlActive else {
                // Control press arrived while another modifier is already held —
                // not a clean double-tap candidate.
                cancelPendingPress()
                firstPressAt = nil
                return
            }

            registerControlPressCandidate(at: now)
        } else {
            // Control released.
            isControlCurrentlyDown = false
        }
    }

    /// Allows tests to drain the guard window without sleeping.
    func forceCommitPendingPressForTesting(at now: Date = Date()) {
        commitPendingPress(at: now)
    }

    var hasPendingPressForTesting: Bool { pendingPressAt != nil }
    var firstPressAtForTesting: Date? { firstPressAt }

    // MARK: - Private

    private func registerControlPressCandidate(at now: Date) {
        // Drop expired first-press if too much time has passed.
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

        if let firstPressAt, now.timeIntervalSince(firstPressAt) <= Self.doubleTapWindow {
            self.firstPressAt = nil
            let mouseLocation = NSEvent.mouseLocation
            eventPublisher.send(QuickInputDoubleTapEvent(mouseLocation: mouseLocation))
            return
        }

        firstPressAt = pressedAt
    }
}
