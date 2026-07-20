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

/// Atomic per-display visibility state published as one value.
///
/// Subscribers reacting to changes MUST read the emitted payload, never the
/// store property from inside the sink: `@Published` emits during `willSet`,
/// so the property still holds the pre-change state at emission time. The HUD
/// overlay manager once re-read the store there and applied every visibility
/// change one toggle late, which surfaced as "toggling display A first
/// toggles display B".
struct PickyHUDDockVisibilitySnapshot: Equatable {
    /// Legacy all-display default inherited by displays without an override.
    var defaultVisibility: Bool
    /// Explicit display overrides only. Displays without an entry inherit
    /// `defaultVisibility` so existing settings continue to show or hide
    /// every dock until the user changes one monitor independently.
    var overridesByDisplayID: [String: Bool]

    func isVisible(for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID else { return defaultVisibility }
        return overridesByDisplayID[String(displayID)] ?? defaultVisibility
    }
}

@MainActor
final class PickyHUDVisibilityStore: ObservableObject {
    @Published private(set) var snapshot: PickyHUDDockVisibilitySnapshot

    private let settingsStore: PickySettingsStore

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        let settings = settingsStore.load()
        self.snapshot = PickyHUDDockVisibilitySnapshot(
            defaultVisibility: settings.hudDockVisible,
            overridesByDisplayID: settings.hudDockVisibilityByDisplayID
        )
    }

    func isVisible(for displayID: CGDirectDisplayID?) -> Bool {
        snapshot.isVisible(for: displayID)
    }

    func setVisible(_ isVisible: Bool, for displayID: CGDirectDisplayID) {
        guard snapshot.isVisible(for: displayID) != isVisible else { return }

        var next = snapshot
        let key = String(displayID)
        if isVisible == next.defaultVisibility {
            next.overridesByDisplayID.removeValue(forKey: key)
        } else {
            next.overridesByDisplayID[key] = isVisible
        }
        snapshot = next
        persist()
    }

    func toggle(for displayID: CGDirectDisplayID) {
        setVisible(!isVisible(for: displayID), for: displayID)
    }

    /// Reserved for actions that intentionally reveal every monitor, such as
    /// notification routing when macOS cannot identify a target display.
    func setAllVisible(_ isVisible: Bool) {
        guard snapshot.defaultVisibility != isVisible || !snapshot.overridesByDisplayID.isEmpty else { return }
        snapshot = PickyHUDDockVisibilitySnapshot(defaultVisibility: isVisible, overridesByDisplayID: [:])
        persist()
    }

    private func persist() {
        var settings = settingsStore.load()
        settings.hudDockVisible = snapshot.defaultVisibility
        settings.hudDockVisibilityByDisplayID = snapshot.overridesByDisplayID
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
