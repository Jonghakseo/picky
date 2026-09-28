import AppKit
import SwiftUI

/// A transparent native hit and focus target. The SwiftUI face above it keeps
/// the Hub's colors, size, hover, pressed, and disabled presentation unchanged.
struct PickyHubNativeButton: NSViewRepresentable {
    let accessibilityLabel: String
    let onPress: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onPressedChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    func makeNSView(context: Context) -> PickyHubHitButton {
        let button = PickyHubHitButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        return button
    }

    func updateNSView(_ button: PickyHubHitButton, context: Context) {
        context.coordinator.onPress = onPress
        button.onFocusChanged = onFocusChanged
        button.onPressedChanged = onPressedChanged
        button.setAccessibilityLabel(accessibilityLabel)
        button.isEnabled = isEnabled
    }

    static func dismantleNSView(_ button: PickyHubHitButton, coordinator: Coordinator) {
        button.target = nil
        button.onFocusChanged = nil
        button.onPressedChanged = nil
    }

    final class Coordinator: NSObject {
        var onPress: () -> Void
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
        @objc func press() { onPress() }
    }
}

final class PickyHubHitButton: NSButton {
    var onFocusChanged: ((Bool) -> Void)?
    var onPressedChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChanged?(false) }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        onPressedChanged?(true)
        defer { onPressedChanged?(false) }
        super.mouseDown(with: event)
    }
}
