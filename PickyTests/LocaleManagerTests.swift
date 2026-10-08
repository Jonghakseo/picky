//
//  LocaleManagerTests.swift
//  PickyTests
//

import Observation
import XCTest
@testable import Picky

@MainActor
final class LocaleManagerTests: XCTestCase {
    /// `apply(.korean)` updates the published values and the nonisolated
    /// snapshots together. Snapshot mirroring is what lets L10n.t work from
    /// background contexts (e.g. notification bodies built off the main actor).
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

    /// A view body that resolved copy through `L10n.t` must be invalidated
    /// when the language changes; otherwise child views keep showing the
    /// previous language after a runtime switch in Settings.
    func testLanguageSwitchInvalidatesL10nObservers() {
        let manager = LocaleManager.shared
        let previousChoice = manager.choice
        defer { manager.apply(previousChoice) }
        manager.apply(.korean)

        var invalidated = false
        let resolved = withObservationTracking {
            L10n.t("settings.oauth.status.stored")
        } onChange: {
            invalidated = true
        }
        XCTAssertEqual(resolved, "Pi에 로그인 정보 저장됨")

        manager.apply(.english)
        XCTAssertTrue(invalidated)
        XCTAssertEqual(L10n.t("settings.oauth.status.stored"), "Credentials saved in Pi")
    }

    /// Relative times follow the app language, not the system locale, and a
    /// shared formatter must not keep the language it was created with.
    func testDockRelativeTimeFollowsAppLanguage() {
        let manager = LocaleManager.shared
        let previousChoice = manager.choice
        defer { manager.apply(previousChoice) }
        let now = Date()
        let fiveMinutesAgo = now.addingTimeInterval(-300)

        manager.apply(.korean)
        XCTAssertTrue(PickyHUDDockRelativeTimePresentation.text(for: fiveMinutesAgo, relativeTo: now).contains("분"))

        manager.apply(.english)
        let english = PickyHUDDockRelativeTimePresentation.text(for: fiveMinutesAgo, relativeTo: now)
        XCTAssertNil(english.range(of: "[\u{AC00}-\u{D7A3}]", options: .regularExpression), english)
        XCTAssertTrue(english.contains("min"), english)
    }

    /// `.system` resolves the OS preference into one of Picky's supported codes
    /// and never falls through to an unsupported language.
    func testSystemChoiceResolvesToSupportedLanguage() {
        let resolved = PickyLanguage.system.resolvedIdentifier
        XCTAssertTrue(["en", "ko"].contains(resolved), "system resolved to unsupported language: \(resolved)")
    }

    func testFocusStackLabelsResolveInEnglishAndKorean() {
        let manager = LocaleManager.shared
        let previousChoice = manager.choice
        defer { manager.apply(previousChoice) }

        manager.apply(.english)
        XCTAssertEqual(L10n.t("hud.conversation.meta.context", "43%"), "Context: 43%")
        XCTAssertEqual(L10n.t("hud.conversation.status.running"), "Running")
        XCTAssertEqual(L10n.t("hud.presence.thinking"), "Thinking")
        XCTAssertEqual(activityCategoryLabels(), ["Read", "bash", "Edit", "Write", "Subagent", "Other"])
        XCTAssertEqual(PickyActivityDurationFormat.completionText(seconds: 125), "Completed in 2m 5s")

        manager.apply(.korean)
        XCTAssertEqual(L10n.t("hud.conversation.meta.context", "43%"), "컨텍스트: 43%")
        XCTAssertEqual(L10n.t("hud.conversation.status.running"), "실행 중")
        XCTAssertEqual(L10n.t("hud.presence.thinking"), "생각 중")
        XCTAssertEqual(activityCategoryLabels(), ["읽기", "실행", "수정", "쓰기", "서브에이전트", "기타"])
        XCTAssertEqual(PickyActivityDurationFormat.completionText(seconds: 125), "2분 5초 동안 완료")
    }

    private func activityCategoryLabels() -> [String] {
        PickyActivitySummary(
            edit: 1,
            bash: 1,
            other: 1,
            read: 1,
            write: 1,
            todo: 1,
            subagent: 1
        ).visibleToolCallItems.map(\.label)
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
