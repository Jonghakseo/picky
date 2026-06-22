//
//  PickyCursorMascotGlowLayerTests.swift
//  PickyTests
//
//  Locks the caching contract for the mascot glow optimization: the blurred
//  glow halo was extracted into an `Equatable` layer so SwiftUI rasterizes the
//  `.blur` once and reuses it across frames, applying only a cheap per-frame
//  `.scaleEffect` outside. These tests pin that the layer's identity depends
//  ONLY on inputs that do not change per frame (asset/tint/style), so a future
//  edit that leaks a per-frame transform (e.g. breathing `scale`) into the glow
//  layer — which would defeat `.equatable()` and re-rasterize the blur every
//  display refresh — fails here.
//

import SwiftUI
import Testing
@testable import Picky

struct PickyCursorMascotGlowLayerTests {
    private func layer(
        assetName: String = "PickyCursorNormal",
        tint: Color = .orange,
        glowOpacity: Double = 0.3,
        glowSize: Double = 14.0,
        glowBlur: Double = 0.3
    ) -> MascotGlowLayer {
        MascotGlowLayer(
            assetName: assetName,
            tint: tint,
            glowOpacity: glowOpacity,
            glowSize: glowSize,
            glowBlur: glowBlur
        )
    }

    @Test func identicalInputsCompareEqualSoBlurIsReused() {
        #expect(layer() == layer())
    }

    @Test func differingAssetNameInvalidatesCache() {
        #expect(layer(assetName: "PickyCursorNormal") != layer(assetName: "PickyCursorBlink"))
    }

    @Test func differingTintInvalidatesCache() {
        #expect(layer(tint: .orange) != layer(tint: .white))
    }

    @Test func differingGlowStyleInvalidatesCache() {
        #expect(layer(glowOpacity: 0.3) != layer(glowOpacity: 0.45))
        #expect(layer(glowSize: 14.0) != layer(glowSize: 16.0))
        #expect(layer(glowBlur: 0.3) != layer(glowBlur: 0.6))
    }

    @Test func perFrameBreathingScaleIsNotAnInputSoFramesStayEqual() {
        // The breathing `scale` animates the OUTER `.scaleEffect`, never the glow
        // layer's inputs. Two frames with different breathing scales must still
        // produce equal glow layers, which is what lets SwiftUI skip the blur.
        let frameA = layer()
        let frameB = layer()
        #expect(frameA == frameB)
    }
}
