import AppKit
import SwiftUI

/// The footer action and checkbox bindings share the existing per-display store.
@MainActor
struct PickyHubDockControl {
    let displayIDs: [CGDirectDisplayID]
    let targetDisplayID: CGDirectDisplayID?
    let visibilityStore: PickyHUDVisibilityStore

    var showsDisplayPicker: Bool { displayIDs.count > 1 }

    var presentation: CompanionPanelDockActionPresentation {
        if showsDisplayPicker {
            return .init(titleKey: "hub.dock.control", systemImage: "display.2")
        }
        return .resolve(isDockVisible: visibilityStore.isVisible(for: targetDisplayID))
    }

    /// Returns whether the caller should present the picker, without toggling a dock.
    func activate() -> Bool {
        if showsDisplayPicker { return true }
        if let targetDisplayID { visibilityStore.toggle(for: targetDisplayID) }
        return false
    }

    func visibilityBinding(for displayID: CGDirectDisplayID) -> Binding<Bool> {
        Binding(
            get: { visibilityStore.isVisible(for: displayID) },
            set: { visibilityStore.setVisible($0, for: displayID) }
        )
    }
}
