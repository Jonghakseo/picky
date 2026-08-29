import CoreGraphics
import Foundation
import Testing
@testable import Picky

struct PickyPhysicalModifierChordDetectorTests {
    private let base = Date(timeIntervalSince1970: 1_000)

    @Test func physicalStateTrackerDerivesDownAndUpFromEventTransitions() {
        var tracker = PickyPhysicalModifierStateTracker()

        let leftDown = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.leftCommand.keyCode,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        let rightDown = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.rightCommand.keyCode,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        let leftUp = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.leftCommand.keyCode,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        let rightUp = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.rightCommand.keyCode,
            modifierFlagsRawValue: 0
        )

        #expect(leftDown?.isDown == true)
        #expect(rightDown?.isDown == true)
        #expect(leftUp?.isDown == false)
        #expect(rightUp?.isDown == false)
    }

    @Test func physicalStateTrackerIgnoresNonPhysicalKeysAndResets() {
        var tracker = PickyPhysicalModifierStateTracker()

        let nonPhysicalTransition = tracker.handleFlagsChanged(
            keyCode: 49,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        #expect(nonPhysicalTransition == nil)
        _ = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.leftCommand.keyCode,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        tracker.reset()
        let leftDownAfterReset = tracker.handleFlagsChanged(
            keyCode: PickyPhysicalModifierKey.leftCommand.keyCode,
            modifierFlagsRawValue: UInt64(CGEventFlags.maskCommand.rawValue)
        )
        #expect(leftDownAfterReset?.isDown == true)
    }

    @Test func triggersOnceWhenLeftThenRightCommandOverlapWithinWindow() {
        var detector = makeDetector()

        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0) == false)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.05))
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.06, isAutorepeat: true) == false)
        #expect(change(&detector, key: .leftCommand, isDown: false, offset: 0.07) == false)
        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0.08) == false)
    }

    @Test func triggersWhenRightThenLeftCommandOverlapWithinWindow() {
        var detector = makeDetector()

        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0) == false)
        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0.04))
    }

    @Test func rearmsOnlyAfterBothCommandsAreReleased() {
        var detector = makeDetector()

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.03))
        _ = change(&detector, key: .leftCommand, isDown: false, offset: 0.04)
        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0.05) == false)
        _ = change(&detector, key: .leftCommand, isDown: false, offset: 0.06)
        _ = change(&detector, key: .rightCommand, isDown: false, offset: 0.07)

        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.10) == false)
        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0.13))
    }

    @Test func simultaneousWindowIncludesBoundaryAndRejectsLaterOverlap() {
        var boundary = makeDetector()
        _ = change(&boundary, key: .leftCommand, isDown: true, offset: 0)
        #expect(change(&boundary, key: .rightCommand, isDown: true, offset: PickyPhysicalModifierChordDetector.simultaneousWindow))

        var late = makeDetector()
        _ = change(&late, key: .leftCommand, isDown: true, offset: 0)
        #expect(change(&late, key: .rightCommand, isDown: true, offset: PickyPhysicalModifierChordDetector.simultaneousWindow + 0.001) == false)
    }

    @Test func handSwitchOverlapDoesNotCreateFreshCandidateUntilFullRelease() {
        var detector = makeDetector()

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.30) == false)
        _ = change(&detector, key: .leftCommand, isDown: false, offset: 0.31)
        #expect(change(&detector, key: .leftCommand, isDown: true, offset: 0.32) == false)
        _ = change(&detector, key: .leftCommand, isDown: false, offset: 0.33)
        _ = change(&detector, key: .rightCommand, isDown: false, offset: 0.34)

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0.40)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.42))
    }

    @Test func nonModifierKeyDownCancelsCandidateUntilFullRelease() {
        var detector = makeDetector()

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0)
        #expect(detector.handle(
            eventType: .keyDown,
            keyCode: 49,
            isPhysicalModifierDown: nil,
            isAutorepeat: false,
            now: base.addingTimeInterval(0.02)
        ) == false)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.03) == false)
    }

    @Test func resetDropsHeldAndCandidateState() {
        var detector = makeDetector()

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0)
        detector.reset()
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.02) == false)
        _ = change(&detector, key: .rightCommand, isDown: false, offset: 0.03)
        _ = change(&detector, key: .leftCommand, isDown: false, offset: 0.04)

        _ = change(&detector, key: .leftCommand, isDown: true, offset: 0.05)
        #expect(change(&detector, key: .rightCommand, isDown: true, offset: 0.07))
    }

    private func makeDetector() -> PickyPhysicalModifierChordDetector {
        PickyPhysicalModifierChordDetector(keys: [.leftCommand, .rightCommand])
    }

    private func change(
        _ detector: inout PickyPhysicalModifierChordDetector,
        key: PickyPhysicalModifierKey,
        isDown: Bool,
        offset: TimeInterval,
        isAutorepeat: Bool = false
    ) -> Bool {
        detector.handle(
            eventType: .flagsChanged,
            keyCode: key.keyCode,
            isPhysicalModifierDown: isDown,
            isAutorepeat: isAutorepeat,
            now: base.addingTimeInterval(offset)
        )
    }
}
