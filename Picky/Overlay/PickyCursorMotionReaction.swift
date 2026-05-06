//
//  PickyCursorMotionReaction.swift
//  Picky
//
//  Pure math/decision helpers for Pi cursor stop reactions.
//

import CoreGraphics
import Foundation

enum PickyCursorMotionReaction {
    static let movementSpeed: CGFloat = 140
    static let fastSpeed: CGFloat = 900
    static let stoppedSpeed: CGFloat = 90
    static let stopOvershootCooldown: TimeInterval = 0.22
    static let overshootDistance: CGFloat = 6

    struct Sample: Equatable {
        let dx: CGFloat
        let dy: CGFloat
        let distance: CGFloat
        let speed: CGFloat
        let direction: CGVector
    }

    static func sample(
        previousPosition: CGPoint,
        currentPosition: CGPoint,
        previousTime: TimeInterval,
        currentTime: TimeInterval,
        minimumDelta: TimeInterval = 1.0 / 120.0
    ) -> Sample {
        let dt = max(currentTime - previousTime, minimumDelta)
        let dx = currentPosition.x - previousPosition.x
        let dy = currentPosition.y - previousPosition.y
        let distance = hypot(dx, dy)
        return Sample(
            dx: dx,
            dy: dy,
            distance: distance,
            speed: distance / CGFloat(dt),
            direction: normalizedVector(dx: dx, dy: dy)
        )
    }

    static func isMeaningfulMovement(_ sample: Sample) -> Bool {
        sample.speed > movementSpeed && sample.distance > 0.35
    }

    static func isFastMovement(_ sample: Sample) -> Bool {
        sample.speed > fastSpeed
    }

    static func shouldTriggerStopOvershoot(
        sample: Sample,
        wasCursorMovingFast: Bool,
        overshootActive: Bool,
        now: TimeInterval,
        lastOvershootAt: TimeInterval
    ) -> Bool {
        sample.speed < stoppedSpeed
            && wasCursorMovingFast
            && !overshootActive
            && now - lastOvershootAt > stopOvershootCooldown
    }

    static func overshootRotation(for direction: CGVector) -> Double {
        clamped(Double(direction.dx) * 4.0, min: -5.0, max: 5.0)
    }

    static func normalizedVector(dx: CGFloat, dy: CGFloat) -> CGVector {
        let length = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: dx / length, dy: dy / length)
    }

    static func clamped(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}
