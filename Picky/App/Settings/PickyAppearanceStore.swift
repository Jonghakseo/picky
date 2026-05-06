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
    /// Slack-like dark overlay fill used by the markdown report and terminal panels.
    /// Kept local to auxiliary windows so the main HUD depth ladder can stay unchanged.
    static let overlayBackground = Color(light: Color(hex: "#F7F8F8"), dark: Color(hex: "#1A1D21"))

    /// Background tint behind the markdown report and terminal panels. In dark mode
    /// this avoids a near-black titlebar and matches `overlayBackground`.
    static func windowBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
            case .darkAqua:
                return darkOverlayBackground
            default:
                return NSColor(calibratedWhite: 0.97, alpha: 1.0)
            }
        }
    }

    static func resolvedOverlayBackground(isDark: Bool) -> NSColor {
        isDark ? darkOverlayBackground : NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)
    }

    private static var darkOverlayBackground: NSColor {
        NSColor(calibratedRed: 26.0 / 255.0, green: 29.0 / 255.0, blue: 33.0 / 255.0, alpha: 1.0)
    }
}
