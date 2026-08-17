//
//  PickyHUDActualPanelVisibilityStore.swift
//  Picky
//
//  Observable actual visibility for per-display HUD panels.
//

import AppKit
import Combine
import CoreGraphics

/// Runtime panel visibility, distinct from the user's persisted dock visibility
/// preference. A panel can be configured visible while a secure macOS surface
/// temporarily orders it out.
struct PickyHUDActualPanelVisibilitySnapshot: Equatable {
    private var visibilityByDisplayID: [String: Bool] = [:]

    func isVisible(for displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID else { return false }
        return visibilityByDisplayID[String(displayID)] ?? false
    }

    mutating func setVisible(_ isVisible: Bool, for displayID: CGDirectDisplayID) {
        visibilityByDisplayID[String(displayID)] = isVisible
    }

    mutating func removePanel(for displayID: CGDirectDisplayID) {
        visibilityByDisplayID.removeValue(forKey: String(displayID))
    }
}

@MainActor
final class PickyHUDActualPanelVisibilityStore: ObservableObject {
    @Published private(set) var snapshot = PickyHUDActualPanelVisibilitySnapshot()

    func isVisible(for displayID: CGDirectDisplayID?) -> Bool {
        snapshot.isVisible(for: displayID)
    }

    /// Registers the manager-owned projection before normal or secure-surface
    /// ordering can change the AppKit panel's visibility.
    func track(_ panel: PickyHUDPanel, for displayID: CGDirectDisplayID) {
        panel.onActualVisibilityChanged = { [weak self] isVisible in
            self?.setVisible(isVisible, for: displayID)
        }
        setVisible(panel.isVisible, for: displayID)
    }

    func setVisible(_ isVisible: Bool, for displayID: CGDirectDisplayID) {
        guard snapshot.isVisible(for: displayID) != isVisible else { return }
        var next = snapshot
        next.setVisible(isVisible, for: displayID)
        snapshot = next
    }

    func removePanel(for displayID: CGDirectDisplayID) {
        var next = snapshot
        next.removePanel(for: displayID)
        guard next != snapshot else { return }
        snapshot = next
    }

    func removeAllPanels() {
        guard snapshot != PickyHUDActualPanelVisibilitySnapshot() else { return }
        snapshot = PickyHUDActualPanelVisibilitySnapshot()
    }
}
