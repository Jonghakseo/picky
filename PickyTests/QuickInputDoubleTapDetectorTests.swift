//
//  QuickInputDoubleTapDetectorTests.swift
//  PickyTests
//
//  Verifies the Control-key double-tap detector that opens the Quick Input
//  pill. Important guarantees:
//   - A single Control press never fires.
//   - Two Control presses inside the double-tap window fire exactly once.
//   - Two Control presses *outside* the window do not fire (the second press
//     becomes the new first press instead).
//   - Press combinations that are really PTT starts (Control with another
//     modifier already engaged, or another modifier added inside the guard
//     window) are suppressed.
//   - A real keyDown inside the guard window cancels the candidate press.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct QuickInputDoubleTapDetectorTests {
    private static let leftControlKeyCode: UInt16 = 59
    private static let rightControlKeyCode: UInt16 = 62

    @Test
    func singleControlTapDoesNotFire() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)

        controlDown(detector, at: Date(timeIntervalSince1970: 1_000))
        detector.forceCommitPendingPressForTesting(at: Date(timeIntervalSince1970: 1_000))
        controlUp(detector, at: Date(timeIntervalSince1970: 1_000.05))

        #expect(collector.events.isEmpty)
        #expect(detector.firstPressAtForTesting != nil)
    }

    @Test
    func twoControlTapsInsideWindowFireOnce() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 2_000)

        controlDown(detector, at: base)
        detector.forceCommitPendingPressForTesting(at: base)
        controlUp(detector, at: base.addingTimeInterval(0.05))

        controlDown(detector, at: base.addingTimeInterval(0.20))
        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(0.20))
        controlUp(detector, at: base.addingTimeInterval(0.25))

        #expect(collector.events.count == 1)
        #expect(detector.firstPressAtForTesting == nil)
    }

    @Test
    func secondControlTapJustInsideWindowStillFiresAfterGuardDelay() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 3_000)

        controlDown(detector, at: base)
        controlUp(detector, at: base.addingTimeInterval(0.05))
        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(QuickInputDoubleTapDetector.pttGuardWindow))

        let secondPress = base.addingTimeInterval(QuickInputDoubleTapDetector.doubleTapWindow - 0.001)
        controlDown(detector, at: secondPress)
        controlUp(detector, at: secondPress.addingTimeInterval(0.05))
        detector.forceCommitPendingPressForTesting(at: secondPress.addingTimeInterval(QuickInputDoubleTapDetector.pttGuardWindow))

        #expect(collector.events.count == 1)
        #expect(detector.firstPressAtForTesting == nil)
    }

    @Test
    func twoControlTapsOutsideWindowDoNotFire() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 3_100)

        controlDown(detector, at: base)
        detector.forceCommitPendingPressForTesting(at: base)
        controlUp(detector, at: base.addingTimeInterval(0.05))

        // Second press lands well after the doubleTapWindow elapses.
        controlDown(detector, at: base.addingTimeInterval(0.80))
        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(0.80))
        controlUp(detector, at: base.addingTimeInterval(0.85))

        #expect(collector.events.isEmpty)
        // The late press should now be remembered as a fresh first press.
        #expect(detector.firstPressAtForTesting == base.addingTimeInterval(0.80))
    }

    @Test
    func controlWithOtherModifierAlreadyHeldIsIgnored() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)

        // Simulate Option already held when Control is pressed (PTT-style start).
        detector.handleFlagsChanged(
            keyCode: Self.leftControlKeyCode,
            flags: [.control, .option]
        )

        #expect(detector.hasPendingPressForTesting == false)
        #expect(collector.events.isEmpty)
    }

    @Test
    func addingOtherModifierInsideGuardWindowCancelsPress() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 4_000)

        controlDown(detector, at: base)
        // Then Option is added before the guard expires (keyCode 58 == left option).
        detector.handleFlagsChanged(keyCode: 58, flags: [.control, .option])

        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(0.10))
        #expect(collector.events.isEmpty)
        #expect(detector.firstPressAtForTesting == nil)
    }

    @Test
    func keyDownInsideGuardWindowCancelsPress() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 5_000)

        controlDown(detector, at: base)
        // User pressed `c` (keyCode 8) while still holding Control — Ctrl+C.
        detector.handleGlobalEvent(
            eventType: .keyDown,
            keyCode: 8,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue)
        )

        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(0.10))
        #expect(collector.events.isEmpty)
        #expect(detector.firstPressAtForTesting == nil)
    }

    @Test
    func leftAndRightControlBothCount() async {
        let detector = QuickInputDoubleTapDetector()
        let collector = EventCollector(detector: detector)
        let base = Date(timeIntervalSince1970: 6_000)

        // First press: left control.
        detector.handleFlagsChanged(
            keyCode: Self.leftControlKeyCode,
            flags: [.control],
            now: base
        )
        detector.forceCommitPendingPressForTesting(at: base)
        controlUp(detector, at: base.addingTimeInterval(0.05))

        // Second press: right control inside the window.
        detector.handleFlagsChanged(
            keyCode: Self.rightControlKeyCode,
            flags: [.control],
            now: base.addingTimeInterval(0.18)
        )
        detector.forceCommitPendingPressForTesting(at: base.addingTimeInterval(0.18))

        #expect(collector.events.count == 1)
    }

    @Test
    func resetClearsState() async {
        let detector = QuickInputDoubleTapDetector()
        let base = Date(timeIntervalSince1970: 7_000)

        controlDown(detector, at: base)
        detector.forceCommitPendingPressForTesting(at: base)
        #expect(detector.firstPressAtForTesting != nil)

        detector.reset()
        #expect(detector.firstPressAtForTesting == nil)
        #expect(detector.hasPendingPressForTesting == false)
    }

    // MARK: - Helpers

    private func controlDown(_ detector: QuickInputDoubleTapDetector, at now: Date) {
        detector.handleFlagsChanged(
            keyCode: Self.leftControlKeyCode,
            flags: [.control],
            now: now
        )
    }

    private func controlUp(_ detector: QuickInputDoubleTapDetector, at now: Date) {
        detector.handleFlagsChanged(
            keyCode: Self.leftControlKeyCode,
            flags: [],
            now: now
        )
    }
}

/// Synchronously captures every emission from the detector's publisher. The
/// detector publishes from the main actor and we drive it from the main actor
/// inside the tests, so a plain stored array is sufficient.
@MainActor
private final class EventCollector {
    private(set) var events: [QuickInputDoubleTapEvent] = []
    private var cancellable: AnyCancellable?

    init(detector: QuickInputDoubleTapDetector) {
        cancellable = detector.eventPublisher.sink { [weak self] event in
            self?.events.append(event)
        }
    }
}
