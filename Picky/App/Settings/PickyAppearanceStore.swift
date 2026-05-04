//
//  PickyAppearanceStore.swift
//  Picky
//
//  ObservableObject that owns the user's selected light/dark mode and persists
//  it through PickySettingsStore. A single instance lives on the AppDelegate
//  and is injected as an environment object into the companion panel, the
//  HUD overlay, and the Settings scene so the entire UI flips together.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PickyAppearanceStore: ObservableObject {
    @Published var mode: PickyAppearanceMode

    private let settingsStore: PickySettingsStore

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.mode = settingsStore.load().appearance
    }

    func setMode(_ newMode: PickyAppearanceMode) {
        guard mode != newMode else { return }
        mode = newMode
        persist(newMode)
    }

    func toggle() {
        setMode(mode.toggled())
    }

    private func persist(_ newMode: PickyAppearanceMode) {
        var current = settingsStore.load()
        current.appearance = newMode
        do {
            try settingsStore.save(current)
        } catch {
            // Persistence failure should not break the in-memory toggle; just log it.
            // Settings file may live on a read-only volume during tests/CI runs.
            print("⚠️ PickyAppearanceStore: failed to persist appearance: \(error.localizedDescription)")
        }
    }
}

/// Wraps `.preferredColorScheme(...)` so the host view re-renders whenever the
/// observed `PickyAppearanceStore` publishes a new mode. Used at every NSPanel /
/// Settings root so the entire hosted SwiftUI tree flips together.
struct PickyPreferredColorSchemeModifier: ViewModifier {
    @ObservedObject var store: PickyAppearanceStore

    func body(content: Content) -> some View {
        content.preferredColorScheme(store.mode.colorScheme)
    }
}

/// Dynamic NSColor helpers for NSPanel chrome that lives outside the SwiftUI tree
/// (the titlebar fill behind the markdown report panel and the terminal panel).
/// They resolve against the panel's `effectiveAppearance`, which AppKit flips for
/// us when SwiftUI's `.preferredColorScheme(...)` is applied to the hosted root view.
enum PickyAppearancePanelChrome {
    /// Background tint behind the markdown report and terminal panels. Intentionally
    /// a hair darker / lighter than `DS.Colors.background` so the titlebar reads
    /// as a slightly recessed surface.
    static func windowBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua:
                return NSColor(calibratedWhite: 0.04, alpha: 0.98)
            default:
                return NSColor(calibratedWhite: 0.97, alpha: 1.0)
            }
        }
    }
}
