//
//  ShortcutCaptureRecorderTests.swift
//  PickyTests
//
//  Verifies the live capture state machine: which event sequences resolve to
//  modifier-only / modifier+key / double-tap drafts, and that allowance rules
//  reject unsupported shapes (Quick Input modifier-only single press, etc.).
//

import AppKit
import Combine
import Foundation
import Testing
@testable import Picky

@MainActor
struct ShortcutCaptureRecorderTests {
    private let leftControl: UInt16 = 59
    private let leftOption: UInt16 = 58
    private let leftShift: UInt16 = 56

    @Test
    func pushToTalkCapturesModifierOnly() {
        let recorder = ShortcutCaptureRecorder(allowance: .pushToTalk)
        recorder.start()

        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control])
        recorder.handleEvent(type: .flagsChanged, keyCode: leftOption, modifierFlags: [.control, .option])
        recorder.handleEvent(type: .flagsChanged, keyCode: leftOption, modifierFlags: [.control])
        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [])

        if case .modifierCombo(let mods, let key) = recorder.draftSpec {
            #expect(mods.contains(.control))
            #expect(key == nil)
        } else {
            #expect(Bool(false), "expected modifierCombo, got \(String(describing: recorder.draftSpec))")
        }
    }

    @Test
    func pushToTalkCapturesModifierPlusKey() {
        let recorder = ShortcutCaptureRecorder(allowance: .pushToTalk)
        recorder.start()

        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control])
        recorder.handleEvent(type: .flagsChanged, keyCode: leftOption, modifierFlags: [.control, .option])
        recorder.handleEvent(
            type: .keyDown,
            keyCode: 49, // space
            modifierFlags: [.control, .option]
        )

        if case .modifierCombo(let mods, let key) = recorder.draftSpec {
            #expect(mods == [.control, .option])
            #expect(key == 49)
        } else {
            #expect(Bool(false), "expected modifierCombo with key, got \(String(describing: recorder.draftSpec))")
        }
    }

    @Test
    func quickInputCapturesDoubleTap() {
        let recorder = ShortcutCaptureRecorder(allowance: .quickInput)
        recorder.start()
        let base = Date(timeIntervalSince1970: 1_000)

        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control], now: base)
        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [], now: base.addingTimeInterval(0.05))
        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control], now: base.addingTimeInterval(0.20))

        #expect(recorder.draftSpec == .doubleTapModifier(.control))
    }

    @Test
    func quickInputRefusesModifierOnlySinglePress() {
        let recorder = ShortcutCaptureRecorder(allowance: .quickInput)
        recorder.start()

        recorder.handleEvent(type: .flagsChanged, keyCode: leftShift, modifierFlags: [.shift])
        recorder.handleEvent(type: .flagsChanged, keyCode: leftShift, modifierFlags: [])

        #expect(recorder.draftSpec == nil)
    }

    @Test
    func quickInputCapturesModifierPlusKeyCombo() {
        let recorder = ShortcutCaptureRecorder(allowance: .quickInput)
        recorder.start()

        recorder.handleEvent(type: .flagsChanged, keyCode: leftShift, modifierFlags: [.shift])
        recorder.handleEvent(type: .keyDown, keyCode: 6 /* Z */, modifierFlags: [.shift])

        if case .modifierCombo(let mods, let key) = recorder.draftSpec {
            #expect(mods == .shift)
            #expect(key == 6)
        } else {
            #expect(Bool(false), "expected combo, got \(String(describing: recorder.draftSpec))")
        }
    }

    @Test
    func cancelClearsDraft() {
        let recorder = ShortcutCaptureRecorder(allowance: .pushToTalk)
        recorder.start()
        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control])
        recorder.cancel()
        #expect(recorder.draftSpec == nil)
        #expect(recorder.isCapturing == false)
    }

    @Test
    func commitReturnsDraftAndStops() {
        let recorder = ShortcutCaptureRecorder(allowance: .pushToTalk)
        recorder.start()
        recorder.handleEvent(type: .flagsChanged, keyCode: leftControl, modifierFlags: [.control])
        let spec = recorder.commit()
        #expect(spec != nil)
        #expect(recorder.isCapturing == false)
    }

    @Test
    func startAndCancelEmitCaptureLifecycleNotifications() async {
        let recorder = ShortcutCaptureRecorder(allowance: .pushToTalk)
        var observed: [Bool] = []
        let token = NotificationCenter.default.addObserver(
            forName: .pickyShortcutCaptureDidChange,
            object: recorder,
            queue: nil
        ) { note in
            if let value = note.userInfo?[PickyShortcutCaptureNotificationKeys.isCapturing] as? Bool {
                observed.append(value)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        recorder.start()
        recorder.cancel()

        #expect(observed == [true, false])
    }
}

@MainActor
struct QuickInputComboDetectorTests {
    @Test
    func comboSpecFiresOnKeyDownWithModifiersHeld() {
        let detector = QuickInputDoubleTapDetector()
        detector.currentShortcutSpec = .modifierCombo(modifiers: [.shift], keyCode: 6 /* Z */)

        var firedCount = 0
        let cancellable = detector.eventPublisher.sink { _ in firedCount += 1 }
        defer { cancellable.cancel() }

        detector.handleGlobalEvent(
            eventType: .keyDown,
            keyCode: 6,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.shift.rawValue)
        )

        #expect(firedCount == 1)
    }

    @Test
    func comboSpecDoesNotFireWithoutRequiredModifiers() {
        let detector = QuickInputDoubleTapDetector()
        detector.currentShortcutSpec = .modifierCombo(modifiers: [.shift], keyCode: 6)

        var firedCount = 0
        let cancellable = detector.eventPublisher.sink { _ in firedCount += 1 }
        defer { cancellable.cancel() }

        detector.handleGlobalEvent(eventType: .keyDown, keyCode: 6, modifierFlagsRawValue: 0)
        #expect(firedCount == 0)
    }

    @Test
    func comboSpecDoesNotRepeatUntilKeyReleased() {
        let detector = QuickInputDoubleTapDetector()
        detector.currentShortcutSpec = .modifierCombo(modifiers: [.shift], keyCode: 6)

        var firedCount = 0
        let cancellable = detector.eventPublisher.sink { _ in firedCount += 1 }
        defer { cancellable.cancel() }

        let modifiers = UInt64(NSEvent.ModifierFlags.shift.rawValue)
        detector.handleGlobalEvent(eventType: .keyDown, keyCode: 6, modifierFlagsRawValue: modifiers)
        detector.handleGlobalEvent(eventType: .keyDown, keyCode: 6, modifierFlagsRawValue: modifiers)
        #expect(firedCount == 1)

        detector.handleGlobalEvent(eventType: .keyUp, keyCode: 6, modifierFlagsRawValue: modifiers)
        detector.handleGlobalEvent(eventType: .keyDown, keyCode: 6, modifierFlagsRawValue: modifiers)
        #expect(firedCount == 2)
    }

    @Test
    func switchingSpecResetsState() {
        let detector = QuickInputDoubleTapDetector()
        detector.currentShortcutSpec = .modifierCombo(modifiers: [.shift], keyCode: 6)

        let modifiers = UInt64(NSEvent.ModifierFlags.shift.rawValue)
        detector.handleGlobalEvent(eventType: .keyDown, keyCode: 6, modifierFlagsRawValue: modifiers)

        // Switching to a different spec should clear comboCurrentlyHeld so the
        // next press of the new spec fires immediately.
        detector.currentShortcutSpec = .doubleTapModifier(.control)
        #expect(detector.firstPressAtForTesting == nil)
        #expect(detector.hasPendingPressForTesting == false)
    }
}
