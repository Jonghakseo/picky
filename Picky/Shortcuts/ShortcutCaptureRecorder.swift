//
//  ShortcutCaptureRecorder.swift
//  Picky
//
//  Live key-capture state machine that backs the "Change" button on each
//  shortcut row. While capturing the recorder owns a local NSEvent monitor
//  scoped to the host panel (so capturing only happens while Settings is
//  visible) and exposes a draft spec for the UI to render and persist.
//
//  Capture rules per allowance:
//   - .pushToTalk  -> .modifierCombo(modifiers-only) or .modifierCombo(modifiers + key)
//   - .quickInput  -> .doubleTapModifier(modifier) or .modifierCombo(modifiers + key)
//   - .focusPickle -> .physicalModifierChord(left/right Command)
//

import AppKit
import Combine
import CoreGraphics
import Foundation

extension Notification.Name {
    /// Posted whenever a `ShortcutCaptureRecorder` toggles its `isCapturing`
    /// flag. The CompanionManager listens so the global PTT monitor and the
    /// Quick Input detector can pause while the user is recording a new
    /// shortcut — otherwise pressing the existing shortcut during capture
    /// would dismiss the panel and start a real voice/text session.
    static let pickyShortcutCaptureDidChange = Notification.Name("pickyShortcutCaptureDidChange")
}

enum PickyShortcutCaptureNotificationKeys {
    static let isCapturing = "isCapturing"
}

/// Shortcut recording must be scoped to the settings panel that started it.
/// The panel's hosting hierarchy persists while hidden, so an active recorder
/// otherwise continues to receive every app-local keyDown event and can block
/// typing in an unrelated HUD composer.
enum PickyShortcutCaptureEventRoutingPolicy {
    static func shouldConsume(
        isCapturing: Bool,
        hasCaptureWindow: Bool,
        isEventInCaptureWindow: Bool
    ) -> Bool {
        isCapturing && hasCaptureWindow && isEventInCaptureWindow
    }
}

@MainActor
final class ShortcutCaptureRecorder: ObservableObject {
    enum Allowance {
        case pushToTalk
        case quickInput
        case focusPickle

        var hint: String {
            switch self {
            case .pushToTalk:
                return "Press a shortcut. e.g. ⌃⌥, or ⌃⌥+space."
            case .quickInput:
                return "Press a shortcut. Tap the same modifier twice for a double-tap, or hold modifiers + key for a combo."
            case .focusPickle:
                return "Press left and right Command together, double-tap a modifier, or hold modifiers + key."
            }
        }
    }

    /// Same window the QuickInputDoubleTapDetector uses, so the capture UI
    /// agrees with the runtime behavior on what counts as a double-tap.
    static let doubleTapWindow: TimeInterval = QuickInputDoubleTapDetector.doubleTapWindow

    @Published private(set) var isCapturing: Bool = false {
        didSet {
            guard oldValue != isCapturing else { return }
            NotificationCenter.default.post(
                name: .pickyShortcutCaptureDidChange,
                object: self,
                userInfo: [PickyShortcutCaptureNotificationKeys.isCapturing: isCapturing]
            )
        }
    }
    @Published private(set) var draftSpec: PickyShortcutSpec?
    @Published private(set) var statusMessage: String?

    private let allowance: Allowance
    private var localMonitor: Any?
    private weak var captureWindow: NSWindow?
    /// Most recently observed pure modifier set (no non-modifier keys held yet).
    /// Used to distinguish modifier-only and double-tap candidates from combos.
    private var lastPureModifierSet: NSEvent.ModifierFlags = []
    private var lastModifierPressKey: NSEvent.ModifierFlags = []
    private var lastModifierPressAt: Date?
    private var physicalKeysCurrentlyDown: Set<PickyPhysicalModifierKey> = []

    init(allowance: Allowance) {
        self.allowance = allowance
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    var allowanceHint: String { allowance.hint }

    func start() {
        guard !isCapturing else { return }
        captureWindow = NSApp.keyWindow
        isCapturing = true
        draftSpec = nil
        statusMessage = allowance.hint
        lastPureModifierSet = []
        lastModifierPressKey = []
        lastModifierPressAt = nil
        physicalKeysCurrentlyDown = []
        installLocalMonitorIfNeeded()
    }

    func cancel() {
        finishCapture(clearDraft: true)
    }

    /// Stops capture without clearing the draft so the host can read it for Save.
    func commit() -> PickyShortcutSpec? {
        let spec = draftSpec
        finishCapture(clearDraft: false)
        return spec
    }

    /// Test-friendly handler so the recorder can be exercised without an
    /// NSEvent monitor.
    func handleEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        physicalModifierIsDown: Bool? = nil,
        now: Date = Date()
    ) {
        guard isCapturing else { return }
        let cleanedFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch type {
        case .flagsChanged:
            handleFlagsChanged(
                modifierFlags: cleanedFlags,
                keyCode: keyCode,
                physicalModifierIsDown: physicalModifierIsDown,
                now: now
            )
        case .keyDown:
            handleKeyDown(keyCode: keyCode, modifierFlags: cleanedFlags)
        default:
            break
        }
    }

    // MARK: - Private

    private func finishCapture(clearDraft: Bool) {
        isCapturing = false
        captureWindow = nil
        statusMessage = nil
        if clearDraft { draftSpec = nil }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self,
                  let captureWindow = self.captureWindow,
                  PickyShortcutCaptureEventRoutingPolicy.shouldConsume(
                    isCapturing: self.isCapturing,
                    hasCaptureWindow: true,
                    isEventInCaptureWindow: event.window === captureWindow
                  )
            else { return event }
            self.handleEvent(
                type: event.type,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                physicalModifierIsDown: event.type == .flagsChanged
                    ? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(event.keyCode))
                    : nil
            )
            // Swallow the event only inside the settings panel currently
            // recording a shortcut so other Picky inputs keep receiving keys.
            return nil
        }
    }

    private func handleFlagsChanged(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        physicalModifierIsDown: Bool?,
        now: Date
    ) {
        if allowance == .focusPickle,
           updatePhysicalChordCapture(keyCode: keyCode, isDown: physicalModifierIsDown) {
            return
        }

        let normalized = modifierFlags.intersection([.shift, .control, .option, .command, .function])

        // Track which single modifier key was just *pressed* by diffing against
        // the previously observed set — necessary for double-tap detection.
        let newlyPressed = normalized.subtracting(lastPureModifierSet)
        let newlyReleased = lastPureModifierSet.subtracting(normalized)

        if !newlyPressed.isEmpty {
            registerModifierPress(newlyPressed: newlyPressed, fullSet: normalized, now: now)
        } else if !newlyReleased.isEmpty {
            registerModifierRelease(remaining: normalized)
        }

        lastPureModifierSet = normalized
        _ = keyCode // keyCode of a flagsChanged event identifies the modifier; we infer it via flag diffs.
    }

    private func updatePhysicalChordCapture(keyCode: UInt16, isDown: Bool?) -> Bool {
        guard let key = PickyPhysicalModifierKey(keyCode: keyCode), let isDown else {
            return false
        }
        if isDown {
            physicalKeysCurrentlyDown.insert(key)
        } else {
            physicalKeysCurrentlyDown.remove(key)
        }

        let orderedKeys = PickyPhysicalModifierKey.allCases.filter(physicalKeysCurrentlyDown.contains)
        guard Set(orderedKeys) == Set(PickyPhysicalModifierKey.allCases) else {
            return false
        }
        draftSpec = .physicalModifierChord(keys: orderedKeys)
        statusMessage = nil
        lastModifierPressKey = []
        lastModifierPressAt = nil
        return true
    }

    private func registerModifierPress(
        newlyPressed: NSEvent.ModifierFlags,
        fullSet: NSEvent.ModifierFlags,
        now: Date
    ) {
        // Action shortcuts detect a double-tap of a single modifier when no
        // other modifier is currently engaged.
        if allowance != .pushToTalk,
           PickyShortcutKeyCap.singleModifierFlag(newlyPressed) != nil,
           fullSet == newlyPressed,
           lastModifierPressKey == newlyPressed,
           let previous = lastModifierPressAt,
           now.timeIntervalSince(previous) <= Self.doubleTapWindow {
            draftSpec = .doubleTapModifier(newlyPressed)
            statusMessage = "Captured as a double-tap."
            lastModifierPressKey = []
            lastModifierPressAt = nil
            return
        }

        lastModifierPressKey = newlyPressed
        lastModifierPressAt = now

        // Tentative draft updates so the keycap row reflects what the user is
        // currently holding even before they commit.
        if allowance == .pushToTalk {
            draftSpec = .modifierCombo(modifiers: fullSet, keyCode: nil)
            statusMessage = nil
        } else {
            // Action shortcuts don't allow a modifier-only single press. Focus
            // Pickle additionally accepts the left/right Command chord.
            draftSpec = nil
            statusMessage = allowance == .focusPickle
                ? "Add a key, tap the modifier again, or press the other Command."
                : "Add a key, or tap the same modifier once more."
        }
    }

    private func registerModifierRelease(remaining: NSEvent.ModifierFlags) {
        // The user lifted a modifier without pressing a non-modifier key. The
        // draft already holds a modifier-only spec for PTT, which is fine; for
        // Quick Input the hint message keeps standing.
        if allowance == .pushToTalk, !remaining.isEmpty {
            draftSpec = .modifierCombo(modifiers: remaining, keyCode: nil)
        }
    }

    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let normalized = modifierFlags.intersection([.shift, .control, .option, .command, .function])

        guard PickyShortcutKeyCodeMap.label(for: keyCode) != nil else {
            statusMessage = "This key can’t be used as a shortcut. Try another one."
            return
        }

        draftSpec = .modifierCombo(modifiers: normalized, keyCode: keyCode)
        statusMessage = nil
        lastModifierPressKey = []
        lastModifierPressAt = nil
    }
}
