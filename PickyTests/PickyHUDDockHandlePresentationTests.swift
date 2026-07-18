//
//  PickyHUDDockHandlePresentationTests.swift
//  PickyTests
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockHandlePresentationTests {
    @Test func restingHandleMeetsNonTextContrastAcrossAppearances() throws {
        let presentation = PickyHUDDockHandlePresentation.resolve(isActive: false)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let contrast = try contrastRatio(
                foreground: presentation.foregroundColor,
                opacity: presentation.opacity,
                background: DS.Colors.surface1,
                appearance: try #require(NSAppearance(named: appearanceName))
            )

            #expect(contrast >= 3.0, "Insufficient dock handle contrast in \(appearanceName.rawValue)")
        }
    }

    @Test func activeHandleIsStrongerThanRestingHandleAcrossAppearances() throws {
        let resting = PickyHUDDockHandlePresentation.resolve(isActive: false)
        let active = PickyHUDDockHandlePresentation.resolve(isActive: true)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let restingContrast = try contrastRatio(
                foreground: resting.foregroundColor,
                opacity: resting.opacity,
                background: DS.Colors.surface1,
                appearance: appearance
            )
            let activeContrast = try contrastRatio(
                foreground: active.foregroundColor,
                opacity: active.opacity,
                background: DS.Colors.surface1,
                appearance: appearance
            )

            #expect(activeContrast > restingContrast, "Active handle should strengthen contrast in \(appearanceName.rawValue)")
        }
    }

    private func contrastRatio(
        foreground: Color,
        opacity: Double,
        background: Color,
        appearance: NSAppearance
    ) throws -> Double {
        let foregroundRGB = try resolvedRGB(foreground, appearance: appearance)
        let backgroundRGB = try resolvedRGB(background, appearance: appearance)
        let composite = RGB(
            red: foregroundRGB.red * opacity + backgroundRGB.red * (1 - opacity),
            green: foregroundRGB.green * opacity + backgroundRGB.green * (1 - opacity),
            blue: foregroundRGB.blue * opacity + backgroundRGB.blue * (1 - opacity)
        )
        let foregroundLuminance = composite.relativeLuminance
        let backgroundLuminance = backgroundRGB.relativeLuminance

        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func resolvedRGB(_ color: Color, appearance: NSAppearance) throws -> RGB {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let value = try #require(resolved)
        return RGB(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent)
    }
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    var relativeLuminance: Double {
        0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    private func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
