//
//  PickyCaptureContextBorderView.swift
//  Picky
//
//  Full-screen edge treatment shown while a display is being captured as
//  neutral model context (PTT recording / Quick Input open). A slowly rotating
//  angular-gradient border plus a soft inward focus glow signal "this screen is
//  going to Pi as context", with a small pill spelling it out in text so the
//  cue never relies on color alone.
//
//  Rendered inside OverlayWindow, which conforms to
//  PickyScreenCaptureExcludedWindow, so this chrome is visible to the user but
//  never leaks into the screenshot sent as context.
//

import SwiftUI

struct PickyCaptureContextBorderView: View {
    let screenFrame: CGRect
    let reduceMotion: Bool

    /// Border ring thickness in points.
    private let lineWidth: CGFloat = 4
    /// Corner radius hugging the display edge.
    private let cornerRadius: CGFloat = 22
    /// Seconds per full rotation of the angular gradient sweep.
    private let rotationPeriod: TimeInterval = 7
    /// Focus-glow strength (0...1). Locked to 30% for a subtle inward bloom.
    private let glowStrength: Double = 0.30

    private var glowBlur: CGFloat { 14 + CGFloat(glowStrength) * 34 }
    private var glowLineWidth: CGFloat { 8 + CGFloat(glowStrength) * 10 }

    private var borderShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            focusGlow
            rotatingBorder
            contextPill
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    /// Soft blue bloom bleeding inward from the edges. Clipped to the border
    /// shape so the blur only spills toward screen center, drawing the eye in.
    private var focusGlow: some View {
        borderShape
            .strokeBorder(DS.Colors.overlayCursorBlue.opacity(0.55), lineWidth: glowLineWidth)
            .blur(radius: glowBlur)
            .clipShape(borderShape)
    }

    private var rotatingBorder: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? .zero : rotation(at: timeline.date)
            borderShape
                .strokeBorder(angularGradient(rotation: angle), lineWidth: lineWidth)
        }
    }

    private var contextPill: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 7, height: 7)
                Text(L10n.t("overlay.captureBorder.contextLabel"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(hex: "#CFE1FF"))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: "#0A1423").opacity(0.72))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.35), lineWidth: 0.8)
            )
            .padding(.bottom, 20)
        }
    }

    private func rotation(at date: Date) -> Angle {
        let seconds = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: rotationPeriod)
        return .degrees(seconds / rotationPeriod * 360)
    }

    private func angularGradient(rotation: Angle) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: DS.Colors.overlayCursorBlue, location: 0.0),
                .init(color: Color(hex: "#7FB2FF"), location: 0.25),
                .init(color: DS.Colors.overlayCursorBlue.opacity(0.05), location: 0.5),
                .init(color: Color(hex: "#5B93FF"), location: 0.75),
                .init(color: DS.Colors.overlayCursorBlue, location: 1.0)
            ]),
            center: .center,
            angle: rotation
        )
    }
}
