//
//  LocaleManager.swift
//  Picky
//
//  Single source of truth for Picky's effective language. Holds the user's
//  `PickyLanguage` choice (from PickySettings), resolves it against the OS
//  preference when set to `.system`, and exposes:
//
//   - `effectiveLocale`  → injected into SwiftUI via `\.locale`
//   - `stringsBundle`    → used by `L10n.t(_:)` for non-SwiftUI call sites
//
//  Calling `apply(_:)` from the settings UI flips both immediately so the
//  in-app chrome retranslates without a relaunch. Some surfaces (the macOS
//  app menu, certain AppKit-driven dialogs) still snapshot the locale at
//  process start; the settings UI shows a one-time toast for those.
//

import Combine
import Foundation

@MainActor
final class LocaleManager: ObservableObject {
    static let shared = LocaleManager()

    @Published private(set) var choice: PickyLanguage
    @Published private(set) var effectiveLocale: Locale
    @Published private(set) var stringsBundle: Bundle

    /// Thread-safe mirror of `stringsBundle` for nonisolated callers (e.g.
    /// `L10n.t(_:)` when invoked from a background queue building scenario
    /// data). The published property is the source of truth on the main
    /// actor; this snapshot is updated atomically inside `apply(_:)`. `Bundle`
    /// is itself reference-thread-safe to read, and reassigning the snapshot
    /// pointer goes through `snapshotLock` so we can't tear the reference.
    private static let snapshotLock = NSLock()
    nonisolated(unsafe) private static var _snapshotBundle: Bundle = .main
    nonisolated(unsafe) private static var _snapshotLocale: Locale = Locale(identifier: "en")

    /// Snapshot of the current strings bundle for nonisolated reads.
    nonisolated static var nonisolatedStringsBundle: Bundle {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotBundle
    }

    /// Snapshot of the current effective locale for nonisolated reads. Used
    /// when formatting strings with arguments (`String(format:locale:_)`)
    /// from background contexts.
    nonisolated static var nonisolatedEffectiveLocale: Locale {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLocale
    }

    /// Posted right after `apply(_:)` swaps the bundle. AppKit code paths
    /// (NSAlert, NSSavePanel, status item tooltips) listen here to refresh
    /// any already-rendered chrome they own.
    static let didChangeNotification = Notification.Name("PickyLocaleDidChange")

    private init(initial: PickyLanguage = .system) {
        self.choice = initial
        let resolved = initial.resolvedLocale
        self.effectiveLocale = resolved
        let bundle = LocaleManager.bundle(for: resolved.identifier)
        self.stringsBundle = bundle
        LocaleManager.updateSnapshot(bundle: bundle, locale: resolved)
    }

    /// Update the choice and rebuild the strings bundle. Safe to call any
    /// number of times; we early-out on no-op transitions so the published
    /// signal doesn't churn views downstream.
    func apply(_ newChoice: PickyLanguage) {
        let nextLocale = newChoice.resolvedLocale
        let identifierChanged = nextLocale.identifier != effectiveLocale.identifier
        let choiceChanged = newChoice != choice
        guard choiceChanged || identifierChanged else { return }

        setLocaleState(choice: newChoice, locale: nextLocale)

        // Mirror the choice into `AppleLanguages` so the system-owned menu
        // bar items and any framework-driven dialogs pick the same language
        // on the next cold launch. Unit tests keep this mutation in memory and
        // must never write into the developer's real Picky preferences domain.
        if PickyRuntimeEnvironment.allowsUserEnvironmentEffects {
            switch newChoice {
            case .system:
                PickyRuntimeEnvironment.userDefaults.removeObject(forKey: "AppleLanguages")
            case .english:
                PickyRuntimeEnvironment.userDefaults.set(["en"], forKey: "AppleLanguages")
            case .korean:
                PickyRuntimeEnvironment.userDefaults.set(["ko"], forKey: "AppleLanguages")
            }
        }

        NotificationCenter.default.post(name: LocaleManager.didChangeNotification, object: nil)
    }

    /// Temporarily changes only this process's localization snapshots for an
    /// offscreen test/render scope. It intentionally avoids UserDefaults and
    /// notifications, then restores the exact prior state in `defer`.
    func withTemporaryChoiceForTesting<Result>(
        _ temporaryChoice: PickyLanguage,
        perform operation: () throws -> Result
    ) rethrows -> Result {
        let previousChoice = choice
        let previousLocale = effectiveLocale
        let previousBundle = stringsBundle
        let temporaryLocale = temporaryChoice.resolvedLocale
        setLocaleState(choice: temporaryChoice, locale: temporaryLocale)
        defer {
            choice = previousChoice
            effectiveLocale = previousLocale
            stringsBundle = previousBundle
            LocaleManager.updateSnapshot(bundle: previousBundle, locale: previousLocale)
        }
        return try operation()
    }

    private func setLocaleState(choice: PickyLanguage, locale: Locale) {
        self.choice = choice
        effectiveLocale = locale
        let bundle = LocaleManager.bundle(for: locale.identifier)
        stringsBundle = bundle
        LocaleManager.updateSnapshot(bundle: bundle, locale: locale)
    }

    private static func updateSnapshot(bundle: Bundle, locale: Locale) {
        snapshotLock.lock()
        _snapshotBundle = bundle
        _snapshotLocale = locale
        snapshotLock.unlock()
    }

    /// Look up an .lproj bundle for the resolved identifier. Falls back to
    /// `Bundle.main` when the catalog doesn't ship a matching translation,
    /// which gives us the source-language strings instead of empty UI.
    private static func bundle(for identifier: String) -> Bundle {
        let primary = String(identifier.split(separator: "-").first ?? Substring(identifier))
        if let path = Bundle.main.path(forResource: primary, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.main
    }
}
