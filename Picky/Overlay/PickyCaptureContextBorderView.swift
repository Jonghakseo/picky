//
//  PickyCaptureContextBorderView.swift
//  Picky
//
//  Full-screen edge treatment shown while a display is being captured as
//  neutral model context (PTT recording / Quick Input open). A static angular-
//  gradient edge line plus a soft inward focus glow signal "this screen is
//  going to Pi as context". A separate compact panel provides the text status
//  and per-display control while this full-screen overlay stays click-through.
//
//  Deliberately static: an earlier version rotated the gradient via
//  `TimelineView(.animation)`, which kept the full-screen overlay window
//  continuously invalidated and re-composited above the Quick Input panel,
//  stuttering typing (confirmed by A/B signpost profiling — see
//  docs/perf-profiling.md). The border now renders once and only re-renders
//  when it appears/disappears, so it adds no per-frame compositing cost.
//
//  Rendered inside OverlayWindow, which conforms to
//  PickyScreenCaptureExcludedWindow, so this chrome is visible to the user but
//  never leaks into the screenshot sent as context.
//

import SwiftUI

struct PickyCaptureContextBorderView: View {
    let screenFrame: CGRect

    /// Border edge-line thickness in points.
    private let lineWidth: CGFloat = 1
    /// Corner radius hugging the display edge.
    private let cornerRadius: CGFloat = 0
    /// Focus-glow strength (0...1).
    private let glowStrength: Double = 0.55

    /// How far the edge bloom reaches toward screen center, in points.
    private let glowDepth: CGFloat = 28
    /// Peak bloom opacity right at the screen edge.
    private var glowPeakOpacity: Double { glowStrength }

    private var borderShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            focusGlow
            edgeBorder
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    /// Soft blue bloom bleeding inward from the four edges. Built from four
    /// cheap linear gradients (no full-screen `.blur()`), so the compositor
    /// never runs a Gaussian filter over the whole overlay window. Corners
    /// brighten where two edge gradients overlap, which reads as a frame.
    private var focusGlow: some View {
        let color = DS.Colors.overlayCursorBlue.opacity(glowPeakOpacity)
        return ZStack {
            LinearGradient(colors: [color, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: glowDepth)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [color, .clear], startPoint: .bottom, endPoint: .top)
                .frame(height: glowDepth)
                .frame(maxHeight: .infinity, alignment: .bottom)
            LinearGradient(colors: [color, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: glowDepth)
                .frame(maxWidth: .infinity, alignment: .leading)
            LinearGradient(colors: [color, .clear], startPoint: .trailing, endPoint: .leading)
                .frame(width: glowDepth)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(false)
    }

    private var edgeBorder: some View {
        borderShape.strokeBorder(angularGradient, lineWidth: lineWidth)
    }


    private var angularGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: DS.Colors.overlayCursorBlue, location: 0.0),
                .init(color: Color(hex: "#7FB2FF"), location: 0.25),
                .init(color: DS.Colors.overlayCursorBlue.opacity(0.05), location: 0.5),
                .init(color: Color(hex: "#5B93FF"), location: 0.75),
                .init(color: DS.Colors.overlayCursorBlue, location: 1.0)
            ]),
            center: .center
        )
    }
}
