import AppKit
import Combine
import SwiftUI
import Testing
@testable import Picky

@Suite(.enabled("Requires macOS Keyboard Navigation for the button-focus contract") {
    guard PickyRuntimeEnvironment.runsPrePushUIEffectTests else { return true }
    return await MainActor.run { NSApp.isFullKeyboardAccessEnabled }
})
@MainActor
struct PickyHubNativeFocusTests {
    // This is a real WindowServer test. Only the pre-push gate may opt in.
    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func dismissingTheProductionModalReturnsKeyboardActivationToItsTrigger() async throws {
        let host = PickyHubModalHost()
        let window = PickyHubWindow(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Hub isolated keyboard verification"
        host.window = window
        defer {
            host.dismiss()
            window.orderOut(nil)
            window.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let ready = try await observe("window ready", window: window) {
            window.isKeyWindow && NSApp.isActive
        }
        try #require(ready, "The isolated fixture must become active and key before testing focus")

        // Both controls use the same window, locale and post-mount focus request.
        // The standard control distinguishes environment failures from Hub behavior.
        for useHubButton in [false, true] {
            let probe = HubFocusProbe()
            let hosting = NSHostingView(rootView: LocalizedHostingRoot {
                HubFocusFixture(host: host, probe: probe, useHubButton: useHubButton)
            })
            hosting.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let kind = useHubButton ? "Hub" : "standard"
            let mounted = try await observe("\(kind) mounted", window: window, probe: probe) { probe.didAppear }
            try #require(mounted, "The control must mount before requesting initial focus")
            probe.focusRequest += 1

            let responding = try await observe("\(kind) responder ready", window: window, probe: probe) {
                guard probe.triggerFocused, let responder = window.firstResponder as? NSView else { return false }
                return responder === hosting || responder.isDescendant(of: hosting)
            }
            try #require(responding, "The mounted control hierarchy must receive keyboard events")
            try sendSpace(to: window)
            let activated = try await observe("\(kind) initial Space", window: window, probe: probe) {
                probe.presses == 1
            }
            try #require(activated, "\(kind) must activate through Space, not a direct action invocation")
            if useHubButton {
                try await verifyModalRestoration(host: host, window: window, probe: probe)
            }

            window.contentView = nil
            if useHubButton {
                window.orderOut(nil)
                window.close()
            }
            let removed = try await observe("\(kind) fixture removed", window: window, probe: probe) {
                probe.fixtureDisappeared
            }
            try #require(removed, "Final counts must be checked after SwiftUI fixture cleanup")
            host.dismiss()
            #expect(probe.focusRequest == 1)
            #expect(probe.dismissalCallbacks == (useHubButton ? 1 : 0))
            #expect(probe.presses == (useHubButton ? 2 : 1))
            #expect(probe.cancelPresses == (useHubButton ? 1 : 0))
            #expect(probe.confirmPresses == 0)
        }
    }

    private func verifyModalRestoration(
        host: PickyHubModalHost, window: NSWindow, probe: HubFocusProbe
    ) async throws {
        host.present(
            accessibilityLabel: "Confirm",
            onDismiss: { probe.dismissalCallbacks += 1 },
            content: {
                PickyHubConfirmDialog(
                    title: "Confirm", message: "Isolated fixture, no settings or daemon changes.",
                    confirmTitle: "common.confirm",
                    onCancel: { probe.cancelPresses += 1; host.dismiss() },
                    onConfirm: { probe.confirmPresses += 1; host.dismiss() }
                )
                .onAppear { probe.dialogAppeared = true }
            }
        )
        let appeared = try await observe("dialog mounted", window: window, probe: probe) {
            probe.dialogAppeared && !probe.triggerFocused
        }
        try #require(appeared, "The production dialog must appear and move focus away from the trigger before Space")
        window.contentView?.layoutSubtreeIfNeeded()
        try sendSpace(to: window)
        let dismissed = try await observe("dialog Cancel Space", window: window, probe: probe) {
            !host.isPresenting && probe.dismissalCallbacks == 1
        }
        try #require(dismissed, "Space must dismiss the dialog and restore its prior native responder")
        #expect(probe.cancelPresses == 1, "Space must choose Cancel, not Confirm")
        #expect(probe.confirmPresses == 0)
        #expect(probe.presses == 1, "The disabled trigger must not receive the dialog's Space")

        window.contentView?.layoutSubtreeIfNeeded()
        try sendSpace(to: window)
        let reactivated = try await observe("restored trigger Space", window: window, probe: probe) {
            probe.presses == 2
        }
        #expect(reactivated, "The original trigger must accept Space after the dialog closes")
        #expect(probe.focusRequest == 1)
        #expect(probe.dismissalCallbacks == 1)
        #expect(probe.cancelPresses == 1)
        #expect(probe.confirmPresses == 0)
    }

    private func sendSpace(to window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49
            ))
            window.sendEvent(event)
        }
    }

    private func observe(
        _ phase: String, window: NSWindow, probe: HubFocusProbe? = nil, _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let succeeded = condition()
        // A window-level AX lookup can return the hosting group even when its
        // SwiftUI button owns focus. Keep it as diagnostics, not the keyboard oracle.
        let focus = window.isKeyWindow
            ? PickyHubAccessibilityObservation.describe(window.accessibilityFocusedUIElement)
            : "window is not key"
        let details = [
            "active=\(NSApp.isActive)", "key=\(window.isKeyWindow)",
            "keyboardNavigation=\(NSApp.isFullKeyboardAccessEnabled)",
            "locale=\(LocaleManager.shared.effectiveLocale.identifier)",
            "expectedTrigger=\(L10n.t("common.close"))", "expectedCancel=\(L10n.t("common.cancel"))",
            "appeared=\(probe?.didAppear ?? false)", "dialogAppeared=\(probe?.dialogAppeared ?? false)",
            "removed=\(probe?.fixtureDisappeared ?? false)",
            "focusRequests=\(probe?.focusRequest ?? 0)", "triggerFocused=\(probe?.triggerFocused ?? false)",
            "dismissals=\(probe?.dismissalCallbacks ?? 0)", "presses=\(probe?.presses ?? 0)",
            "cancel=\(probe?.cancelPresses ?? 0)", "confirm=\(probe?.confirmPresses ?? 0)",
            "firstResponder=\(String(describing: window.firstResponder))", "AX=\(focus)"
        ]
        print("Hub native focus [\(phase)] success=\(succeeded): \(details.joined(separator: "; "))")
        return succeeded
    }
}

@MainActor
private final class HubFocusProbe: ObservableObject {
    @Published var focusRequest = 0
    var didAppear = false
    var dialogAppeared = false
    var fixtureDisappeared = false
    var triggerFocused = false
    var presses = 0
    var dismissalCallbacks = 0
    var cancelPresses = 0
    var confirmPresses = 0
}

private struct HubFocusFixture: View {
    @ObservedObject var host: PickyHubModalHost
    @ObservedObject var probe: HubFocusProbe
    let useHubButton: Bool
    @FocusState private var triggerFocused: Bool

    var body: some View {
        PickyHubModalOverlay(host: host) {
            trigger
                .onAppear { probe.didAppear = true }
                .onChange(of: probe.focusRequest) { _, _ in triggerFocused = true }
                .onChange(of: triggerFocused) { _, focused in probe.triggerFocused = focused }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { probe.fixtureDisappeared = true }
    }

    @ViewBuilder
    private var trigger: some View {
        if useHubButton {
            PickyHubButton(title: "common.close", role: .secondary) { probe.presses += 1 }
                .focused($triggerFocused)
        } else {
            Button("common.close") { probe.presses += 1 }
                .focused($triggerFocused)
        }
    }
}
