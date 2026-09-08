import AppKit
import Combine
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHubNativeFocusTests {
    // This is a real WindowServer test. Only the pre-push gate may opt in.
    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func dismissingTheProductionModalReturnsKeyboardActivationToItsTrigger() async throws {
        let host = PickyHubModalHost()
        let probe = HubFocusProbe()
        let window = PickyHubWindow(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Hub isolated keyboard verification"
        host.window = window
        window.contentView = NSHostingView(rootView: HubFocusFixture(host: host, probe: probe)
            .environment(\.locale, LocaleManager.shared.effectiveLocale))
        defer {
            host.dismiss()
            window.orderOut(nil)
            window.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await eventually("initial trigger focus", in: window) { probe.didAppear && window.isKeyWindow && focusedLabel(in: window) == L10n.t("common.close") }
        sendSpace(to: window)
        try await eventually("initial keyboard activation", in: window) { probe.presses == 1 }

        host.present(accessibilityLabel: "Confirm", onDismiss: { probe.focusRequest += 1 }) {
            PickyHubConfirmDialog(
                title: "Confirm", message: "Isolated fixture, no settings or daemon changes.",
                confirmTitle: "common.confirm", onCancel: { host.dismiss() }, onConfirm: { host.dismiss() }
            )
            .onAppear { probe.dialogAppeared = true }
        }
        try await eventually("dialog Cancel focus", in: window) { probe.dialogAppeared && focusedLabel(in: window) == L10n.t("common.cancel") }
        // Space acts on the dialog's focused Cancel, not the disabled trigger.
        sendSpace(to: window)
        try await eventually("trigger focus after dismissal", in: window) { !host.isPresenting && probe.focusRequest == 1 && focusedLabel(in: window) == L10n.t("common.close") }
        #expect(probe.presses == 1)
        sendSpace(to: window)
        try await eventually("restored keyboard activation", in: window) { probe.presses == 2 }
    }

    private func focusedLabel(in window: NSWindow) -> String? {
        (window.accessibilityFocusedUIElement as? NSAccessibilityProtocol)?.accessibilityLabel()
    }

    private func sendSpace(to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func eventually(_ phase: String, in window: NSWindow, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                let focus = window.accessibilityFocusedUIElement
                Issue.record("Native Hub focus timed out at \(phase); key=\(window.isKeyWindow), label=\(focusedLabel(in: window) ?? "nil"), element=\(String(describing: focus))")
                throw FocusTimeout(phase: phase)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct FocusTimeout: Error { let phase: String }
}

@MainActor
private final class HubFocusProbe: ObservableObject {
    @Published var focusRequest = 0
    var didAppear = false
    var dialogAppeared = false
    var presses = 0
}

private struct HubFocusFixture: View {
    @ObservedObject var host: PickyHubModalHost
    @ObservedObject var probe: HubFocusProbe
    @FocusState private var triggerFocused: Bool

    var body: some View {
        PickyHubModalOverlay(host: host) {
            PickyHubButton(title: "common.close", role: .secondary) { probe.presses += 1 }
                .focused($triggerFocused)
                .onAppear {
                    triggerFocused = true
                    probe.didAppear = true
                }
                .onChange(of: probe.focusRequest) { _, _ in triggerFocused = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
