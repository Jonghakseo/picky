//
//  PickyCursorMotionReactionTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyCursorMotionReactionTests {
    @Test func sampleCalculatesSpeedDistanceAndDirection() {
        let sample = PickyCursorMotionReaction.sample(
            previousPosition: CGPoint(x: 10, y: 20),
            currentPosition: CGPoint(x: 70, y: 100),
            previousTime: 1.0,
            currentTime: 1.1
        )

        #expect(sample.dx == CGFloat(60))
        #expect(sample.dy == CGFloat(80))
        #expect(sample.distance == CGFloat(100))
        #expect(sample.speed.isApproximatelyEqual(to: 1000))
        #expect(sample.direction.dx.isApproximatelyEqual(to: 0.6))
        #expect(sample.direction.dy.isApproximatelyEqual(to: 0.8))
    }

    @Test func sampleUsesMinimumDeltaWhenTimestampsAreTooClose() {
        let sample = PickyCursorMotionReaction.sample(
            previousPosition: CGPoint.zero,
            currentPosition: CGPoint(x: 10, y: 0),
            previousTime: 2.0,
            currentTime: 2.0
        )

        #expect(sample.speed == CGFloat(1200))
    }

    @Test func fastMovementRequiresMeaningfulDistanceAndSpeed() {
        let fast = PickyCursorMotionReaction.sample(
            previousPosition: .zero,
            currentPosition: CGPoint(x: 100, y: 0),
            previousTime: 0,
            currentTime: 0.1
        )
        let tiny = PickyCursorMotionReaction.sample(
            previousPosition: .zero,
            currentPosition: CGPoint(x: 0.2, y: 0),
            previousTime: 0,
            currentTime: 0.001
        )

        #expect(PickyCursorMotionReaction.isMeaningfulMovement(fast))
        #expect(PickyCursorMotionReaction.isFastMovement(fast))
        #expect(!PickyCursorMotionReaction.isMeaningfulMovement(tiny))
    }

    @Test func stopOvershootTriggersOnlyAfterFastMovementStopsAndCooldownPassed() {
        let stopped = PickyCursorMotionReaction.sample(
            previousPosition: CGPoint(x: 100, y: 100),
            currentPosition: CGPoint(x: 100.1, y: 100),
            previousTime: 10,
            currentTime: 10.1
        )

        #expect(PickyCursorMotionReaction.shouldTriggerStopOvershoot(
            sample: stopped,
            wasCursorMovingFast: true,
            overshootActive: false,
            now: 10.1,
            lastOvershootAt: 9.0
        ))
        #expect(!PickyCursorMotionReaction.shouldTriggerStopOvershoot(
            sample: stopped,
            wasCursorMovingFast: false,
            overshootActive: false,
            now: 10.1,
            lastOvershootAt: 9.0
        ))
        #expect(!PickyCursorMotionReaction.shouldTriggerStopOvershoot(
            sample: stopped,
            wasCursorMovingFast: true,
            overshootActive: true,
            now: 10.1,
            lastOvershootAt: 9.0
        ))
        #expect(!PickyCursorMotionReaction.shouldTriggerStopOvershoot(
            sample: stopped,
            wasCursorMovingFast: true,
            overshootActive: false,
            now: 10.1,
            lastOvershootAt: 10.0
        ))
    }

    @Test func overshootRotationIsClamped() {
        #expect(PickyCursorMotionReaction.overshootRotation(for: CGVector(dx: 100, dy: 0)) == 5)
        #expect(PickyCursorMotionReaction.overshootRotation(for: CGVector(dx: -100, dy: 0)) == -5)
        #expect(PickyCursorMotionReaction.overshootRotation(for: CGVector(dx: 0.5, dy: 0)) == 2)
    }
}

private extension CGFloat {
    func isApproximatelyEqual(to expected: CGFloat, absoluteTolerance: CGFloat = 0.0001) -> Bool {
        abs(self - expected) <= absoluteTolerance
    }
}
