import AppKit
import SwiftUI

struct PickyNativeMenuOption<Value: Hashable>: Equatable {
    let value: Value
    let title: String
}

/// Keeps AppKit's keyboard/accessibility behavior without SwiftUI rebuilding
/// attributed menu labels when the window's focus environment changes.
struct PickyNativeMenuPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [PickyNativeMenuOption<Value>]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.pickyAppFontScale) private var fontScale

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.menu = NSMenu()
        button.menu?.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.apply(
            to: button, title: title, selection: $selection, options: options,
            isEnabled: isEnabled, controlSize: nativeControlSize, fontScale: fontScale
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    private var nativeControlSize: NSControl.ControlSize {
        switch controlSize {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
    }

    final class Coordinator: NSObject {
        private var selection: Binding<Value>
        private var appliedOptions: [PickyNativeMenuOption<Value>] = []
        private var appliedTitle: String?
        private var appliedControlSize: NSControl.ControlSize?
        private var appliedFontScale: CGFloat?

        init(selection: Binding<Value>) { self.selection = selection }

        /// The menu and its items are retained on focus-only, selection-only,
        /// and enabled-state updates. This is a tested native-work contract.
        func apply(
            to button: NSPopUpButton,
            title: String,
            selection: Binding<Value>,
            options: [PickyNativeMenuOption<Value>],
            isEnabled: Bool,
            controlSize: NSControl.ControlSize,
            fontScale: CGFloat
        ) {
            self.selection = selection
            if appliedOptions != options {
                PickyPerf.interval("settings_native_menu_update") {
                    if appliedOptions.map(\.value) == options.map(\.value) {
                        for (index, option) in options.enumerated() where appliedOptions[index].title != option.title {
                            button.item(at: index)?.title = option.title
                        }
                    } else {
                        button.removeAllItems()
                        // addItem(withTitle:) deduplicates equal titles. Distinct values
                        // may legitimately share a display name, so append NSMenuItems.
                        for option in options {
                            button.menu?.addItem(NSMenuItem(title: option.title, action: nil, keyEquivalent: ""))
                        }
                    }
                }
                appliedOptions = options
            }
            let index = options.firstIndex { $0.value == selection.wrappedValue } ?? -1
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
            let enabled = isEnabled && !options.isEmpty
            if button.isEnabled != enabled { button.isEnabled = enabled }
            if appliedTitle != title {
                button.setAccessibilityLabel(title)
                appliedTitle = title
            }
            if appliedControlSize != controlSize || appliedFontScale != fontScale {
                button.controlSize = controlSize
                // design-token-exception: retain native popup metrics at the user's app font scale
                let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize) * fontScale)
                button.font = font
                button.menu?.font = font
                appliedControlSize = controlSize
                appliedFontScale = fontScale
            }
        }

        @objc func selectionChanged(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard button.isEnabled, appliedOptions.indices.contains(index) else { return }
            let value = appliedOptions[index].value
            guard value != selection.wrappedValue else { return }
            selection.wrappedValue = value
        }
    }
}
