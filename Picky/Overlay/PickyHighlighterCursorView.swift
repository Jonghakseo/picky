//
//  PickyHighlighterCursorView.swift
//  Picky
//
//  Highlighter pen icon shown at the (hidden) system cursor position while
//  Picky owns ink capture. Drawn as a small tilted marker (dark body + blue
//  chisel tip) so the "drawing mode" affordance is unmistakable.
//

import SwiftUI

struct PickyHighlighterCursorView: View {
    private let frameSize: CGFloat = 30

    /// 1 source unit = `pixelsPerUnit` points. The marker geometry is sourced
    /// from the design mock at unit scale; this multiplier turns it into a
    /// crisp ~24×8 cursor.
    private let pixelsPerUnit: CGFloat = 1.7

    /// Counter-clockwise tilt that makes the marker read as "held in the right
    /// hand", matching the design mock.
    private let rotationDegrees: Double = -22

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(rotationDegrees))

            let s = pixelsPerUnit
            let blueShading: GraphicsContext.Shading = .color(DS.Colors.overlayCursorBlue)
            let darkShading: GraphicsContext.Shading = .color(Color(red: 27 / 255, green: 37 / 255, blue: 51 / 255))

            // Pen body
            let body = CGRect(x: -2 * s, y: -2 * s, width: 9 * s, height: 4 * s)
            context.fill(Path(roundedRect: body, cornerRadius: 1 * s), with: darkShading)

            // Ferrule (blue collar between body and tip)
            let ferrule = CGRect(x: -3.6 * s, y: -2.2 * s, width: 1.6 * s, height: 4.4 * s)
            context.fill(Path(ferrule), with: blueShading)

            // Chisel wedge tip — narrower at the writing edge (x = -7) than at
            // the ferrule (x = -3.6). Vertical taper 4 → 2 source units.
            var wedge = Path()
            wedge.move(to: CGPoint(x: -3.6 * s, y: -2 * s))
            wedge.addLine(to: CGPoint(x: -3.6 * s, y: 2 * s))
            wedge.addLine(to: CGPoint(x: -7 * s, y: 1 * s))
            wedge.addLine(to: CGPoint(x: -7 * s, y: -1 * s))
            wedge.closeSubpath()
            context.fill(wedge, with: blueShading)

            // Body highlight stripe (subtle white sheen)
            let highlight = CGRect(x: -1 * s, y: -1.4 * s, width: 6 * s, height: 0.6 * s)
            context.fill(
                Path(roundedRect: highlight, cornerRadius: 0.3 * s),
                with: .color(.white.opacity(0.18))
            )
        }
        .frame(width: frameSize, height: frameSize)
        .shadow(color: Color.black.opacity(0.32), radius: 2, x: 0, y: 1)
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.45), radius: 4, x: 0, y: 0)
        // Anchor the wedge tip onto the host's `.position(_:)` point. The
        // tip sits at (-7 source units, 0) before rotation, which after a
        // -22° tilt lands at roughly (-11, +4.5) points at the current scale.
        // Shifting the frame by (+11, -5) moves the geometric center off-cursor
        // so the tip itself sits exactly on the cursor anchor.
        .offset(x: 11, y: -5)
    }
}
