import Foundation
import SwiftUI
import Testing
@testable import Picky

struct PickyToolCallPulsingDotTests {
    @Test
    func pulseClearsInheritedLayoutAnimation() {
        var transaction = Transaction(animation: .linear(duration: 10))
        #expect(transaction.animation != nil)

        PickyToolCallPulseAnimationPolicy.isolate(&transaction)

        #expect(transaction.animation == nil)
    }

    @Test
    func opacityFollowsOneAndAHalfSecondPulseWithoutAnimatingReducedMotion() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let midpoint = start.addingTimeInterval(PickyToolCallPulseAnimationPolicy.period / 2)
        let end = start.addingTimeInterval(PickyToolCallPulseAnimationPolicy.period)

        #expect(abs(PickyToolCallPulseAnimationPolicy.opacity(at: start, reduceMotion: false) - 1) < 0.000_001)
        #expect(abs(PickyToolCallPulseAnimationPolicy.opacity(at: midpoint, reduceMotion: false) - 0.35) < 0.000_001)
        #expect(abs(PickyToolCallPulseAnimationPolicy.opacity(at: end, reduceMotion: false) - 1) < 0.000_001)
        #expect(PickyToolCallPulseAnimationPolicy.opacity(at: midpoint, reduceMotion: true) == 1)
    }
}
