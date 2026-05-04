//
//  PickyAppearanceMode.swift
//  Picky
//
//  User-controllable light/dark switch for the entire Picky UI surface
//  (menu bar companion panel, HUD side-agent cards, Settings window).
//

import SwiftUI

enum PickyAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    /// SwiftUI ColorScheme to feed `.preferredColorScheme(...)` so the entire
    /// hosted view tree adopts the requested appearance regardless of system setting.
    var colorScheme: ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }

    func toggled() -> PickyAppearanceMode {
        self == .dark ? .light : .dark
    }
}
