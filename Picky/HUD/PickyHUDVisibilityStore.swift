//
//  PickyHUDVisibilityStore.swift
//  Picky
//
//  Observable per-display HUD dock visibility. Hiding a dock never stops the
//  session/client lifecycle; PickyHUDOverlayManager only orders that panel out.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class PickyHUDVisibilityStore: ObservableObject {
    /// Explicit display overrides only. Displays without an entry inherit the
    /// legacy visibility default so existing settings continue to show or hide
    /// every dock until the user changes one monitor independently.
    @Published private(set) var visibilityByDisplayID: [String: Bool]

    private let settingsStore: PickySettingsStore
    private var defaultVisibility: Bool

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        let settings = settingsStore.load()
        self.defaultVisibility = settings.hudDockVisible
        self.visibilityByDisplayID = settings.hudDockVisibilityByDisplayID
    }

    func isVisible(for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID else { return defaultVisibility }
        return visibilityByDisplayID[String(displayID)] ?? defaultVisibility
    }

    func setVisible(_ isVisible: Bool, for displayID: CGDirectDisplayID) {
        let key = String(displayID)
        let current = self.isVisible(for: displayID)
        guard current != isVisible else { return }

        var updated = visibilityByDisplayID
        if isVisible == defaultVisibility {
            updated.removeValue(forKey: key)
        } else {
            updated[key] = isVisible
        }
        visibilityByDisplayID = updated
        persist()
    }

    func toggle(for displayID: CGDirectDisplayID) {
        setVisible(!isVisible(for: displayID), for: displayID)
    }

    /// Reserved for actions that intentionally reveal every monitor, such as
    /// notification routing when macOS cannot identify a target display.
    func setAllVisible(_ isVisible: Bool) {
        guard defaultVisibility != isVisible || !visibilityByDisplayID.isEmpty else { return }
        defaultVisibility = isVisible
        visibilityByDisplayID = [:]
        persist()
    }

    private func persist() {
        var settings = settingsStore.load()
        settings.hudDockVisible = defaultVisibility
        settings.hudDockVisibilityByDisplayID = visibilityByDisplayID
        do {
            try settingsStore.save(settings)
        } catch {
            // Keep the live panel state responsive even if settings persistence
            // temporarily fails (for example on a read-only test volume).
            print("⚠️ PickyHUDVisibilityStore: failed to persist HUD visibility: \(error.localizedDescription)")
        }
    }
}

/// Resolves the display affected by the Companion footer's Dock action.
/// The display captured from the menu-bar icon is authoritative: both the
/// global mouse location and `NSPanel.screen` can change while the panel is
/// visible.
enum PickyHUDDockVisibilityTarget {
    static func resolve(
        companionDisplayID: CGDirectDisplayID?,
        cursorDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        companionDisplayID ?? cursorDisplayID
    }
}

struct CompanionPanelDockActionPresentation: Equatable {
    let titleKey: String
    let systemImage: String

    static func resolve(isDockVisible: Bool) -> Self {
        if isDockVisible {
            return Self(titleKey: "footer.dock.hide", systemImage: "dock.rectangle")
        }
        return Self(titleKey: "footer.dock.show", systemImage: "dock.arrow.up.rectangle")
    }
}
