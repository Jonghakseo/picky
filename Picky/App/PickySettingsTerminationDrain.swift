//
//  PickySettingsTerminationDrain.swift
//  Picky
//

import Foundation

/// Main-actor state machine for a single clean-quit settings drain. A late
/// completion from a timed-out drain is intentionally ignored so it cannot
/// terminate an app whose quit request was already cancelled.
@MainActor
final class PickySettingsTerminationDrain {
    private var activeToken: UInt64?
    private var nextToken: UInt64 = 0

    func begin() -> UInt64? {
        guard activeToken == nil else { return nil }
        nextToken += 1
        activeToken = nextToken
        return nextToken
    }

    /// Starts two independently scheduled completions. Neither callback waits
    /// for the other, which lets a timeout cancel termination even when a
    /// filesystem operation behind the flush callback is stuck indefinitely.
    @discardableResult
    func beginRace(
        drain: (@escaping @MainActor (Bool) -> Void) -> Void,
        scheduleTimeout: (@escaping @MainActor () -> Void) -> Void,
        onSettled: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard let token = begin() else { return false }
        drain { [weak self] didDrain in
            guard let self, self.settle(token: token) else { return }
            onSettled(didDrain)
        }
        scheduleTimeout { [weak self] in
            guard let self, self.settle(token: token) else { return }
            onSettled(false)
        }
        return true
    }

    /// Returns whether this token may still reply to AppKit's termination
    /// request. `false` means a timeout/cancellation already settled it.
    func settle(token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }
}
