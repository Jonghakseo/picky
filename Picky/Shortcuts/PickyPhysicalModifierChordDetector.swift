import CoreGraphics
import Foundation

struct PickyPhysicalModifierTransition: Equatable {
    let key: PickyPhysicalModifierKey
    let isDown: Bool
}

/// Derives side-specific modifier transitions from the `flagsChanged` event
/// itself. `CGEventSource.keyState` can lag behind the event-tap callback, so
/// querying it here misclassifies a press as a release until another event
/// arrives.
struct PickyPhysicalModifierStateTracker {
    private var keysDown: Set<PickyPhysicalModifierKey> = []

    mutating func handleFlagsChanged(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) -> PickyPhysicalModifierTransition? {
        guard let key = PickyPhysicalModifierKey(keyCode: keyCode) else { return nil }

        let flags = CGEventFlags(rawValue: modifierFlagsRawValue)
        let isDown = flags.contains(.maskCommand) && !keysDown.contains(key)
        if isDown {
            keysDown.insert(key)
        } else {
            keysDown.remove(key)
        }
        return PickyPhysicalModifierTransition(key: key, isDown: isDown)
    }

    mutating func reset() {
        keysDown.removeAll()
    }
}

struct PickyPhysicalModifierChordDetector {
    static let simultaneousWindow: TimeInterval = 0.15

    private let requiredKeys: Set<PickyPhysicalModifierKey>
    private var heldKeys: Set<PickyPhysicalModifierKey> = []
    private var candidateStartedAt: Date?
    private var requiresFullRelease = false

    init(keys: [PickyPhysicalModifierKey]) {
        requiredKeys = Set(keys)
    }

    mutating func handle(
        eventType: CGEventType,
        keyCode: UInt16,
        isPhysicalModifierDown: Bool?,
        isAutorepeat: Bool,
        now: Date = Date()
    ) -> Bool {
        if isAutorepeat { return false }

        if eventType == .keyDown, PickyPhysicalModifierKey(keyCode: keyCode) == nil {
            if candidateStartedAt != nil || !heldKeys.isEmpty {
                candidateStartedAt = nil
                requiresFullRelease = true
            }
            return false
        }

        guard eventType == .flagsChanged,
              let key = PickyPhysicalModifierKey(keyCode: keyCode),
              requiredKeys.contains(key),
              let isPhysicalModifierDown
        else { return false }

        if isPhysicalModifierDown {
            guard heldKeys.insert(key).inserted else { return false }
            guard !requiresFullRelease else { return false }

            if candidateStartedAt == nil {
                candidateStartedAt = now
            }

            guard heldKeys.isSuperset(of: requiredKeys), let candidateStartedAt else {
                return false
            }
            guard now.timeIntervalSince(candidateStartedAt) <= Self.simultaneousWindow else {
                self.candidateStartedAt = nil
                requiresFullRelease = true
                return false
            }

            self.candidateStartedAt = nil
            requiresFullRelease = true
            return true
        }

        heldKeys.remove(key)
        if heldKeys.isEmpty {
            candidateStartedAt = nil
            requiresFullRelease = false
        }
        return false
    }

    var isGestureActiveForArbitration: Bool {
        !heldKeys.isEmpty || requiresFullRelease
    }

    mutating func reset() {
        heldKeys = []
        candidateStartedAt = nil
        requiresFullRelease = false
    }
}
