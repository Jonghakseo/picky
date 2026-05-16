//
//  L10n.swift
//  Picky
//
//  Tiny helper for non-SwiftUI code paths (NSAlert messages, notification
//  bodies, status item tooltips, error messages built outside of view
//  bodies). SwiftUI `Text("key")` automatically uses the locale injected
//  via `.environment(\.locale, ...)` so it doesn't need this helper at all.
//
//  Keys live in `Localizable.xcstrings`. Use the same dot-path convention
//  everywhere (`onboarding.bubble.preWelcome`, `prereq.pi.title`, etc.) so
//  the catalog stays scannable as it grows.
//

import Foundation

enum L10n {
    /// Localized lookup against the current strings bundle. Apply printf-style
    /// arguments via `args` (e.g. `%@`, `%lld`). When the key is missing from
    /// the catalog the value falls back to the key itself so screens at least
    /// render *something* instead of going blank.
    ///
    /// `nonisolated` because we read the bundle/locale through a thread-safe
    /// snapshot maintained by `LocaleManager`. Both SwiftUI views (main actor)
    /// and background closures (e.g. scenario builders called off-actor) can
    /// invoke this freely.
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let bundle = LocaleManager.nonisolatedStringsBundle
        let locale = LocaleManager.nonisolatedEffectiveLocale
        let format = NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
        if args.isEmpty { return format }
        return String(format: format, locale: locale, arguments: args)
    }
}
