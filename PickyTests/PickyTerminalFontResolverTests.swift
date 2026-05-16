//
//  PickyTerminalFontResolverTests.swift
//  PickyTests
//
//  Keeps the embedded Pi terminal aligned with the user's terminal font choices
//  so prompt icons / emoji fallback do not collapse into missing-glyph boxes.
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyTerminalFontResolverTests {
    @Test func ghosttyFontFamiliesParsesConfiguredFontFamilyLines() {
        let config = """
        # Ghostty config
        font-family = D2Coding
        font-family = "JetBrainsMono Nerd Font Mono"
        font-size = 14
        """

        #expect(PickyTerminalFontResolver.ghosttyFontFamilies(from: config) == [
            "D2Coding",
            "JetBrainsMono Nerd Font Mono",
        ])
    }

    @Test func environmentFontOverrideWinsBeforeGhosttyAndDefaults() {
        let selected = PickyTerminalFontResolver.selectedFontName(
            environment: [PickyTerminalFontResolver.environmentFontKey: "Custom Nerd Font, D2Coding"],
            ghosttyConfigContents: "font-family = Ghostty Font",
            isFontAvailable: { $0 == "D2Coding" || $0 == "Ghostty Font" }
        )

        #expect(selected == "D2Coding")
    }

    @Test func ghosttyConfiguredFontWinsBeforeBundledPreferences() {
        let selected = PickyTerminalFontResolver.selectedFontName(
            environment: [:],
            ghosttyConfigContents: "font-family = D2Coding",
            isFontAvailable: { $0 == "D2Coding" || $0 == "MesloLGS Nerd Font Mono" }
        )

        #expect(selected == "D2Coding")
    }

    @Test func candidateFontNamesDeduplicateCaseInsensitively() {
        let names = PickyTerminalFontResolver.candidateFontNames(
            environment: [PickyTerminalFontResolver.environmentFontKey: "D2Coding"],
            ghosttyConfigContents: "font-family = d2coding\nfont-family = D2Coding"
        )

        #expect(names.filter { $0.lowercased() == "d2coding" } == ["D2Coding"])
    }

    @Test func symbolsOnlyFontIsFallbackNotDefaultPrimaryFont() {
        let selected = PickyTerminalFontResolver.selectedFontName(
            environment: [:],
            ghosttyConfigContents: nil,
            isFontAvailable: { PickyTerminalFontResolver.bundledSymbolsFontNames.contains($0) }
        )

        #expect(selected == nil)
        #expect(PickyTerminalFontResolver.terminalFallbackFontNames.contains("Symbols Nerd Font Mono"))
    }

    @Test func bundledSymbolsFontResourceCanBeLocated() {
        #expect(PickyTerminalFontResolver.bundledSymbolsFontURL() != nil)
    }

    @Test func bundledSymbolsFontRegistersForProcessFallback() {
        #expect(PickyTerminalFontResolver.registerBundledTerminalFonts())
        #expect(PickyTerminalFontResolver.bundledSymbolsFontNames.contains { NSFont(name: $0, size: 12) != nil })
    }
}
