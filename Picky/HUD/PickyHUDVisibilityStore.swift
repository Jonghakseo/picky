//
//  PickyHUDVisibilityStore.swift
//  Picky
//
//  Observable global HUD dock visibility. Hiding the dock never stops the
//  session/client lifecycle; PickyHUDOverlayManager only orders its panels out.
//

import Combine
import Foundation

@MainActor
final class PickyHUDVisibilityStore: ObservableObject {
    @Published private(set) var isVisible: Bool

    private let settingsStore: PickySettingsStore

    init(settingsStore: PickySettingsStore = PickySettingsStore()) {
        self.settingsStore = settingsStore
        self.isVisible = settingsStore.load().hudDockVisible
    }

    func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else { return }
        self.isVisible = isVisible
        persist(isVisible)
    }

    func toggle() {
        setVisible(!isVisible)
    }

    private func persist(_ isVisible: Bool) {
        var settings = settingsStore.load()
        settings.hudDockVisible = isVisible
        do {
            try settingsStore.save(settings)
        } catch {
            // Keep the live panel state responsive even if settings persistence
            // temporarily fails (for example on a read-only test volume).
            print("⚠️ PickyHUDVisibilityStore: failed to persist HUD visibility: \(error.localizedDescription)")
        }
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
