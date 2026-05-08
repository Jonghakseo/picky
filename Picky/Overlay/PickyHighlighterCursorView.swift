//
//  PickyHighlighterCursorView.swift
//  Picky
//
//  Highlighter pen icon shown at the (hidden) system cursor position while
//  Picky owns ink capture. Replaces the cursor visual to make the "drawing
//  mode" affordance unmistakable.
//

import SwiftUI

struct PickyHighlighterCursorView: View {
    private let iconSize: CGFloat = 26
    private let frameSize: CGFloat = 36
    private let tipOffset = CGSize(width: -10, height: 10)

    var body: some View {
        Image(systemName: "highlighter")
            .font(.system(size: iconSize, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, DS.Colors.overlayCursorBlue)
            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1)
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.55), radius: 6, x: 0, y: 0)
            .frame(width: frameSize, height: frameSize)
            // Anchor the pen tip onto the virtual cursor point. The
            // SF Symbol's tip sits in the lower-leading region of its frame,
            // so shift the icon up/right so the tip lines up with .position().
            .offset(x: -tipOffset.width, y: -tipOffset.height)
    }
}
