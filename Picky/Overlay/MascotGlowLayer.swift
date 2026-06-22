//
//  MascotGlowLayer.swift
//  Picky
//

import SwiftUI

/// Blurred glow halo behind the cursor mascot. Extracted into its own
/// `Equatable` view so SwiftUI rasterizes the expensive `.blur` once and reuses
/// it across frames; the per-frame breathing `scale` is applied as a cheap
/// `.scaleEffect` transform on the cached layer at the call site. Inputs here
/// only change on expression/mood/style changes, never per frame, so
/// `.equatable()` skips re-rasterization while idle.
struct MascotGlowLayer: View, Equatable {
    let assetName: String
    let tint: Color
    let glowOpacity: Double
    let glowSize: Double
    let glowBlur: Double

    var body: some View {
        Image(assetName)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(tint.opacity(glowOpacity))
            .scaledToFit()
            .frame(width: CGFloat(glowSize), height: CGFloat(glowSize))
            .blur(radius: CGFloat(glowBlur))
    }
}
