//
//  LocaleManagerTests.swift
//  PickyTests
//

import XCTest
@testable import Picky

@MainActor
final class LocaleManagerTests: XCTestCase {
    /// `apply(.korean)` updates the published values and the nonisolated
    /// snapshots together. Snapshot mirroring is what lets L10n.t work from
    /// background contexts (e.g. OnboardingAgentClient's scenario builder).
    func testApplyKoreanUpdatesLocaleAndSnapshots() {
        let manager = LocaleManager.shared
        let previousChoice = manager.choice
        let previousAppleLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        defer { manager.apply(previousChoice) }

        manager.apply(.korean)
        XCTAssertEqual(manager.effectiveLocale.identifier, "ko")
        XCTAssertEqual(LocaleManager.nonisolatedEffectiveLocale.identifier, "ko")
        // Bundle identity is reference-equal because Bundle(path:) caches.
        XCTAssertTrue(manager.stringsBundle === LocaleManager.nonisolatedStringsBundle)
        XCTAssertEqual(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], previousAppleLanguages)
    }

    /// `.system` resolves the OS preference into one of Picky's supported codes
    /// and never falls through to an unsupported language.
    func testSystemChoiceResolvesToSupportedLanguage() {
        let resolved = PickyLanguage.system.resolvedIdentifier
        XCTAssertTrue(["en", "ko"].contains(resolved), "system resolved to unsupported language: \(resolved)")
    }

    /// English remains the source language regardless of the OS locale, so
    /// catalog lookups for an English-only key still return a usable string.
    func testEnglishChoicePinsRegardlessOfOS() {
        let manager = LocaleManager.shared
        let previousChoice = manager.choice
        let previousAppleLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        defer { manager.apply(previousChoice) }

        manager.apply(.english)
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")
        XCTAssertEqual(LocaleManager.nonisolatedEffectiveLocale.identifier, "en")
        XCTAssertEqual(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String], previousAppleLanguages)
    }
}
