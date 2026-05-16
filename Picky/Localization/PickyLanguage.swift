//
//  PickyLanguage.swift
//  Picky
//
//  User-facing language choice. `.system` follows whatever language macOS
//  exposes via `Locale.preferredLanguages`; the explicit cases pin Picky's
//  chrome regardless of the system setting. Adding a new language is just a
//  new case + a localizations entry in `Localizable.xcstrings`; nothing else
//  on the runtime side has to change.
//

import Foundation

enum PickyLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"

    var id: String { rawValue }

    /// Locale identifier used to look up strings in the catalog. `.system`
    /// resolves against the OS preference; everything else is fixed.
    var resolvedIdentifier: String {
        switch self {
        case .system: return PickyLanguage.systemPreferredIdentifier()
        case .english: return "en"
        case .korean: return "ko"
        }
    }

    /// The `Locale` we hand to SwiftUI via `.environment(\.locale, ...)`.
    /// Built from the resolved identifier so `.system` reflects the OS too.
    var resolvedLocale: Locale {
        Locale(identifier: resolvedIdentifier)
    }

    /// Localized display label for the picker. The strings themselves live in
    /// the catalog so they get translated alongside everything else.
    var displayKey: String.LocalizationValue {
        switch self {
        case .system: return "settings.language.system"
        case .english: return "settings.language.en"
        case .korean: return "settings.language.ko"
        }
    }

    /// Resolves the OS-preferred language to one of Picky's supported codes.
    /// We only look at the primary language tag (e.g. `ko-KR` → `ko`) and
    /// fall back to English when no supported language matches; this keeps
    /// the supported set explicit instead of hoping the catalog has every
    /// locale macOS might surface.
    static func systemPreferredIdentifier() -> String {
        let supported: Set<String> = ["en", "ko"]
        for raw in Locale.preferredLanguages {
            let primary = String(raw.split(separator: "-").first ?? Substring(raw))
            if supported.contains(primary) {
                return primary
            }
        }
        return "en"
    }
}
