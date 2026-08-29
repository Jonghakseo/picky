import AppKit
import Combine
import CoreGraphics
import Foundation

struct PickyGlobalShortcutRawEvent {
    let eventType: CGEventType
    let keyCode: UInt16
    let modifierFlagsRawValue: UInt64
    let isAutorepeat: Bool
    let isPhysicalModifierDown: Bool?
    let mouseLocation: CGPoint
    let observedAt: Date
}

struct PickyFocusPickleShortcutEvent: Equatable {
    let mouseLocation: CGPoint
}

/// Owns the three global shortcut recognizers behind Picky's single listen-only
/// event tap. Persisted settings prevent conflicts; the runtime also applies a
/// stable priority (PTT, Quick Input, Focus Pickle) to malformed or overlapping
/// gestures so one physical sequence never fans out to multiple actions.
@MainActor
final class PickyGlobalShortcutArbiter {
    let quickInputDetector = QuickInputDoubleTapDetector()
    let focusPicklePublisher = PassthroughSubject<PickyFocusPickleShortcutEvent, Never>()

    var pushToTalkSpec: PickyShortcutSpec = .defaultPushToTalk {
        didSet { reset() }
    }
    var quickInputSpec: PickyShortcutSpec = .defaultQuickInput {
        didSet {
            quickInputDetector.currentShortcutSpec = quickInputSpec
            resetFocusDetectors()
        }
    }
    var focusPickleSpec: PickyShortcutSpec = .defaultFocusPickle {
        didSet { resetFocusDetectors() }
    }

    private enum FocusGestureClaim {
        case physicalChord
        case standardShortcut
    }

    private let focusStandardDetector = QuickInputDoubleTapDetector()
    private var focusPhysicalDetector = PickyPhysicalModifierChordDetector(
        keys: [.leftCommand, .rightCommand]
    )
    private var focusGestureClaim: FocusGestureClaim?
    private var quickInputGestureClaimed = false
    private var latestFocusMouseLocation = CGPoint.zero
    private var quickInputClaimCancellable: AnyCancellable?
    private var focusStandardClaimCancellable: AnyCancellable?

    init() {
        quickInputDetector.currentShortcutSpec = quickInputSpec
        quickInputClaimCancellable = quickInputDetector.eventPublisher.sink { [weak self] _ in
            guard let self else { return }
            quickInputGestureClaimed = quickInputDetector.isGestureActiveForArbitration
            focusGestureClaim = nil
            resetFocusRecognizerState()
        }
        focusStandardClaimCancellable = focusStandardDetector.eventPublisher.sink { [weak self] _ in
            guard let self else { return }
            focusGestureClaim = focusStandardDetector.isGestureActiveForArbitration
                ? .standardShortcut
                : nil
            focusPicklePublisher.send(PickyFocusPickleShortcutEvent(
                mouseLocation: latestFocusMouseLocation
            ))
        }
        resetFocusDetectors()
    }

    func handle(
        _ event: PickyGlobalShortcutRawEvent,
        wasPushToTalkPreviouslyPressed: Bool
    ) -> BuddyPushToTalkShortcut.ShortcutTransition {
        if let focusGestureClaim {
            continueClaimedFocusGesture(focusGestureClaim, event: event)
            return .none
        }

        let shortcuts: [PickyShortcutRole: PickyShortcutSpec] = [
            .pushToTalk: pushToTalkSpec,
            .quickInput: quickInputSpec,
            .focusPickle: focusPickleSpec,
        ]
        let quickInputEnabled = PickyShortcutConflictPolicy.conflictingRole(
            for: quickInputSpec,
            role: .quickInput,
            shortcuts: shortcuts
        ) != .pushToTalk
        let focusEnabled = PickyShortcutConflictPolicy.conflictingRole(
            for: focusPickleSpec,
            role: .focusPickle,
            shortcuts: shortcuts
        ) == nil

        let pushToTalkTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: event.eventType,
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlagsRawValue,
            wasShortcutPreviouslyPressed: wasPushToTalkPreviouslyPressed,
            spec: pushToTalkSpec
        )
        if wasPushToTalkPreviouslyPressed || claimsPushToTalk(pushToTalkTransition) {
            quickInputDetector.reset()
            quickInputGestureClaimed = false
            focusGestureClaim = nil
            resetFocusRecognizerState()
            return pushToTalkTransition
        }

        if quickInputGestureClaimed {
            quickInputDetector.handleGlobalEvent(
                eventType: event.eventType,
                keyCode: event.keyCode,
                modifierFlagsRawValue: event.modifierFlagsRawValue
            )
            quickInputGestureClaimed = quickInputDetector.isGestureActiveForArbitration
            return .none
        }

        if quickInputEnabled {
            quickInputDetector.handleGlobalEvent(
                eventType: event.eventType,
                keyCode: event.keyCode,
                modifierFlagsRawValue: event.modifierFlagsRawValue
            )
            if quickInputGestureClaimed { return .none }
        } else {
            quickInputDetector.reset()
        }

        guard focusEnabled else {
            focusGestureClaim = nil
            resetFocusRecognizerState()
            return .none
        }

        latestFocusMouseLocation = event.mouseLocation
        switch focusPickleSpec {
        case .physicalModifierChord:
            let didTriggerFocus = focusPhysicalDetector.handle(
                eventType: event.eventType,
                keyCode: event.keyCode,
                isPhysicalModifierDown: event.isPhysicalModifierDown,
                isAutorepeat: event.isAutorepeat,
                now: event.observedAt
            )
            if didTriggerFocus {
                focusGestureClaim = .physicalChord
                publishFocusPickle()
            }
        case .modifierCombo, .doubleTapModifier:
            focusStandardDetector.handleGlobalEvent(
                eventType: event.eventType,
                keyCode: event.keyCode,
                modifierFlagsRawValue: event.modifierFlagsRawValue
            )
        }
        return .none
    }

    func reset() {
        quickInputDetector.reset()
        quickInputGestureClaimed = false
        resetFocusDetectors()
    }

    private func continueClaimedFocusGesture(
        _ claim: FocusGestureClaim,
        event: PickyGlobalShortcutRawEvent
    ) {
        switch claim {
        case .physicalChord:
            _ = focusPhysicalDetector.handle(
                eventType: event.eventType,
                keyCode: event.keyCode,
                isPhysicalModifierDown: event.isPhysicalModifierDown,
                isAutorepeat: event.isAutorepeat,
                now: event.observedAt
            )
            if !focusPhysicalDetector.isGestureActiveForArbitration {
                focusGestureClaim = nil
            }
        case .standardShortcut:
            latestFocusMouseLocation = event.mouseLocation
            focusStandardDetector.handleGlobalEvent(
                eventType: event.eventType,
                keyCode: event.keyCode,
                modifierFlagsRawValue: event.modifierFlagsRawValue
            )
            if !focusStandardDetector.isGestureActiveForArbitration {
                focusGestureClaim = nil
            }
        }
    }

    private func resetFocusDetectors() {
        focusGestureClaim = nil
        focusStandardDetector.currentShortcutSpec = focusPickleSpec
        if case .physicalModifierChord(let keys) = focusPickleSpec {
            focusPhysicalDetector = PickyPhysicalModifierChordDetector(keys: keys)
        } else {
            focusPhysicalDetector = PickyPhysicalModifierChordDetector(keys: [])
        }
    }

    private func resetFocusRecognizerState() {
        focusStandardDetector.reset()
        focusPhysicalDetector.reset()
    }

    private func publishFocusPickle() {
        focusPicklePublisher.send(PickyFocusPickleShortcutEvent(
            mouseLocation: latestFocusMouseLocation
        ))
    }

    private func claimsPushToTalk(
        _ transition: BuddyPushToTalkShortcut.ShortcutTransition
    ) -> Bool {
        switch transition {
        case .none: false
        case .pressed, .released: true
        }
    }
}
