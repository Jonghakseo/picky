//
//  GlobalPushToTalkShortcutMonitor.swift
//  Picky
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Optional sink for raw flagsChanged/keyDown/keyUp events. Used by
    /// QuickInputDoubleTapDetector so we don't install a second CGEvent tap.
    /// Always invoked on the main thread (the event tap runs on `CFRunLoopGetMain()`).
    var rawEventForwarder: ((CGEventType, UInt16, UInt64) -> Void)?

    /// Currently-active push-to-talk shortcut. Mutated by CompanionManager
    /// whenever the user saves a new spec in Settings.
    var currentShortcutSpec: PickyShortcutSpec = .defaultPushToTalk {
        didSet { isShortcutCurrentlyPressed = false }
    }

    /// Set to true while the user is recording a new shortcut in Settings.
    /// While paused the tap stays installed (so we don't lose accessibility
    /// permission state) but neither raw events nor PTT transitions are
    /// forwarded — otherwise pressing the existing shortcut during capture
    /// would close the Settings panel and start a voice session.
    var isCapturePaused: Bool = false {
        didSet { if isCapturePaused { isShortcutCurrentlyPressed = false } }
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    /// Pure decision for whether the monitor should synthesize a `.released`
    /// transition after the tap was disabled (timeout or user-input). When the
    /// tap is briefly disabled we may have missed the real keyUp/flagsChanged
    /// release; without recovery `isShortcutCurrentlyPressed` stays stuck and
    /// every subsequent PTT press decodes as `.none`, leaving the user with a
    /// dead shortcut and a cursor stuck in `.listening` until they relaunch.
    ///
    /// Guarded by the actual modifier state so we never cut off a recording the
    /// user is still actively holding: only synthesize release when the spec's
    /// required modifiers are no longer held in the live `NSEvent.modifierFlags`.
    /// For combos with a keyCode we cannot probe the key itself, so we trust the
    /// modifier check — if modifiers were dropped, the spec is definitely not
    /// satisfied and a release is correct.
    static func reconcileStuckPressedState(
        spec: PickyShortcutSpec,
        isShortcutCurrentlyPressed: Bool,
        currentModifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard isShortcutCurrentlyPressed else { return false }
        let requiredModifiers: NSEvent.ModifierFlags
        switch spec {
        case .modifierCombo(let modifiers, _):
            requiredModifiers = modifiers
        case .doubleTapModifier(let modifier):
            requiredModifiers = modifier
        }
        guard !requiredModifiers.isEmpty else { return true }
        let cleanedFlags = currentModifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiersStillHeld = cleanedFlags.isSuperset(of: requiredModifiers)
        return !modifiersStillHeld
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            let reasonLabel = eventType == .tapDisabledByTimeout ? "timeout" : "user-input"
            let shouldSynthesizeRelease = Self.reconcileStuckPressedState(
                spec: currentShortcutSpec,
                isShortcutCurrentlyPressed: isShortcutCurrentlyPressed,
                currentModifierFlags: NSEvent.modifierFlags
            )
            print("⚠️ Global push-to-talk: tap re-enabled (\(reasonLabel)); pressed=\(isShortcutCurrentlyPressed) synthesizedRelease=\(shouldSynthesizeRelease)")
            if shouldSynthesizeRelease {
                isShortcutCurrentlyPressed = false
                shortcutTransitionPublisher.send(.released)
            }
            return Unmanaged.passUnretained(event)
        }

        if isCapturePaused {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlagsRawValue = event.flags.rawValue
        rawEventForwarder?(eventType, eventKeyCode, modifierFlagsRawValue)
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: modifierFlagsRawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed,
            spec: currentShortcutSpec
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
