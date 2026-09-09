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

/// Content-sized native popover, shared with offscreen layout checks.
struct PickyHubDockPickerView: View {
    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
    }

    let displays: [Display]
    let hubDisplayID: CGDirectDisplayID?
    let visibilityBinding: (CGDirectDisplayID) -> Binding<Bool>

    var body: some View {
        let _ = PickyPerf.event("hub_dock_picker_body")
        VStack(alignment: .leading, spacing: DS.Spacing.space3) {
            Text("hub.dock.control")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
            ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                Toggle(isOn: visibilityBinding(display.id)) {
                    HStack(spacing: DS.Spacing.space2) {
                        Text(verbatim: "\(index + 1). \(display.name)")
                            .fixedSize(horizontal: false, vertical: true)
                        if display.id == hubDisplayID {
                            Text("hub.dock.hubDisplay")
                                .foregroundStyle(PickyHubTheme.Colors.textSecondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall)
            }
        }
        .foregroundStyle(PickyHubTheme.Colors.textPrimary)
        .tint(PickyHubTheme.Colors.action)
        .padding(DS.Spacing.space4)
        .frame(idealWidth: PickyHubTheme.Layout.cardMinWidth)
        // AppKit probes the minimum size with a zero-width proposal. Do not let
        // wrapped display names turn that probe into a tall minimum popover.
        .fixedSize()
    }
}
