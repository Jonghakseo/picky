//
//  PickyRepeatingPulse.swift
//  Picky
//
//  The only place in the app that may start a `repeatForever` animation
//  (guard-enforced by `scripts/check-architecture-rules.js`).
//
//  A repeating animation attached with `.animation(_:value:)` or started with
//  `withAnimation` in `onAppear` animates every animatable change in that
//  transaction, including the view's own layout position. The first-layout
//  shift (or any later list reflow) is then replayed forever, so indicator dots
//  jump around instead of fading in place. Here the repeat is scoped with
//  `.animation(_:body:)` to the opacity modifier alone.
//
//  For motion that must move or scale (bounces), derive the value from the
//  clock with `TimelineView(.animation)` instead; see
//  `CursorWaitingIndicatorView` in `BlueCursorView.swift`.
//

import SwiftUI

extension View {
    /// Fades between full opacity and `dimmedOpacity` while `isActive`.
    /// When inactive or Reduce Motion is on, the view rests at `staticOpacity`.
    func pickyRepeatingPulse(
        isActive: Bool = true,
        dimmedOpacity: Double,
        halfPeriod: Double,
        delay: Double = 0,
        staticOpacity: Double = 1
    ) -> some View {
        modifier(PickyRepeatingPulseModifier(
            isActive: isActive,
            dimmedOpacity: dimmedOpacity,
            halfPeriod: halfPeriod,
            delay: delay,
            staticOpacity: staticOpacity
        ))
    }
}

private struct PickyRepeatingPulseModifier: ViewModifier {
    let isActive: Bool
    let dimmedOpacity: Double
    let halfPeriod: Double
    let delay: Double
    let staticOpacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    private var shouldPulse: Bool { isActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .animation(animation) { $0.opacity(opacity) }
            .onAppear { isDimmed = shouldPulse }
            .onChange(of: shouldPulse) { _, value in isDimmed = value }
    }

    private var opacity: Double {
        guard shouldPulse else { return staticOpacity }
        return isDimmed ? dimmedOpacity : 1
    }

    private var animation: Animation? {
        guard shouldPulse else { return nil }
        return .easeInOut(duration: halfPeriod).repeatForever(autoreverses: true).delay(delay)
    }
}
