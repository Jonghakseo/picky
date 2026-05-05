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
//

import AppKit
import Combine
import Foundation

@MainActor
final class ShortcutCaptureRecorder: ObservableObject {
    enum Allowance {
        case pushToTalk
        case quickInput

        var hint: String {
            switch self {
            case .pushToTalk:
                return "단축키를 누르세요. 예: ⌃⌥, 또는 ⌃⌥+space"
            case .quickInput:
                return "단축키를 누르세요. 같은 키를 두 번 누르면 더블탭, 모디파이어와 키를 함께 누르면 콤보입니다."
            }
        }
    }

    /// Same window the QuickInputDoubleTapDetector uses, so the capture UI
    /// agrees with the runtime behavior on what counts as a double-tap.
    static let doubleTapWindow: TimeInterval = QuickInputDoubleTapDetector.doubleTapWindow

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var draftSpec: PickyShortcutSpec?
    @Published private(set) var statusMessage: String?

    private let allowance: Allowance
    private var localMonitor: Any?
    /// Most recently observed pure modifier set (no non-modifier keys held yet).
    /// Used to distinguish modifier-only and double-tap candidates from combos.
    private var lastPureModifierSet: NSEvent.ModifierFlags = []
    private var lastModifierPressKey: NSEvent.ModifierFlags = []
    private var lastModifierPressAt: Date?

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
        isCapturing = true
        draftSpec = nil
        statusMessage = allowance.hint
        lastPureModifierSet = []
        lastModifierPressKey = []
        lastModifierPressAt = nil
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
        now: Date = Date()
    ) {
        guard isCapturing else { return }
        let cleanedFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch type {
        case .flagsChanged:
            handleFlagsChanged(modifierFlags: cleanedFlags, keyCode: keyCode, now: now)
        case .keyDown:
            handleKeyDown(keyCode: keyCode, modifierFlags: cleanedFlags)
        default:
            break
        }
    }

    // MARK: - Private

    private func finishCapture(clearDraft: Bool) {
        isCapturing = false
        statusMessage = nil
        if clearDraft { draftSpec = nil }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.handleEvent(
                type: event.type,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
            // Swallow the event so it doesn't leak into surrounding controls
            // (e.g. typing "S" wouldn't activate a button labelled "Save").
            return nil
        }
    }

    private func handleFlagsChanged(
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        now: Date
    ) {
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

    private func registerModifierPress(
        newlyPressed: NSEvent.ModifierFlags,
        fullSet: NSEvent.ModifierFlags,
        now: Date
    ) {
        // Quick Input only: detect double-tap of a single modifier when no other
        // modifier is currently engaged.
        if allowance == .quickInput,
           PickyShortcutKeyCap.singleModifierFlag(newlyPressed) != nil,
           fullSet == newlyPressed,
           lastModifierPressKey == newlyPressed,
           let previous = lastModifierPressAt,
           now.timeIntervalSince(previous) <= Self.doubleTapWindow {
            draftSpec = .doubleTapModifier(newlyPressed)
            statusMessage = "더블탭으로 저장됩니다."
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
            // For Quick Input we don't allow modifier-only single press; show a
            // hint that they need to either add a non-modifier key or tap again.
            draftSpec = nil
            statusMessage = "키를 추가하거나 같은 모디파이어를 한 번 더 누르세요."
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
            statusMessage = "이 키는 단축키로 사용할 수 없습니다. 다른 키를 눌러주세요."
            return
        }

        draftSpec = .modifierCombo(modifiers: normalized, keyCode: keyCode)
        statusMessage = nil
        lastModifierPressKey = []
        lastModifierPressAt = nil
    }
}
