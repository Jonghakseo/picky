import AppKit
import Testing
@testable import Picky

// These tests change the test host's Dock presence and key window. Only the
// pre-push WindowServer gate may run them, never an ordinary unit-test command.
@Suite(.serialized)
@MainActor
struct PickyHubWindowLifecycleTests {
    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func openMinimizeReopenAndClosePreserveTheHubApplicationLifecycle() async throws {
        let fixture = try PickyHubRenderGalleryFixture()
        let originalPolicy = NSApp.activationPolicy()
        let originalForeground = NSWorkspace.shared.frontmostApplication
        let controller = PickyHubWindowController(
            dependencies: fixture.dependencies,
            foregroundContextPreserver: PickyHubForegroundContextPreserver()
        )
        defer {
            controller.close()
            NSApp.setActivationPolicy(originalPolicy)
            originalForeground?.activate(options: [])
            fixture.removeTemporaryState()
        }

        controller.show()
        let window = try #require(fixture.dependencies.modalHost.window)
        try await waitUntil {
            window.isKeyWindow && window.isMainWindow && NSApp.isActive
                && !window.collectionBehavior.contains(.moveToActiveSpace)
        }
        #expect(NSApp.activationPolicy() == .regular)
        #expect(controller.isVisible)
        #expect(fixture.navigator.isWindowVisible)

        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized && !fixture.navigator.isWindowVisible }
        #expect(NSApp.activationPolicy() == .regular)

        controller.show()
        controller.show() // Repeated explicit opens must not leave a sticky Space policy.
        try await waitUntil {
            !window.isMiniaturized && window.isKeyWindow && window.isMainWindow
                && !window.collectionBehavior.contains(.moveToActiveSpace)
        }
        #expect(NSApp.activationPolicy() == .regular)
        #expect(fixture.navigator.isWindowVisible)

        controller.close()
        #expect(!controller.isVisible)
        #expect(!fixture.navigator.isWindowVisible)
        #expect(NSApp.activationPolicy() == .accessory)

        controller.show()
        try await waitUntil {
            window.isKeyWindow && window.isMainWindow && NSApp.isActive
                && !window.collectionBehavior.contains(.moveToActiveSpace)
        }
        #expect(NSApp.activationPolicy() == .regular)
        #expect(fixture.navigator.isWindowVisible)
    }

    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func voiceCaptureDismissesHubAndReturnsToAccessoryBeforeRestoringExternalFocus() async throws {
        let fixture = try PickyHubRenderGalleryFixture()
        let originalPolicy = NSApp.activationPolicy()
        let originalForeground = NSWorkspace.shared.frontmostApplication
        let picky = PickyForegroundApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let editor = PickyForegroundApplication(bundleIdentifier: "test.editor", processIdentifier: 2)
        var frontmost = editor
        var restored: PickyForegroundApplication?
        let preserver = PickyHubForegroundContextPreserver(
            pickyBundleIdentifier: picky.bundleIdentifier,
            frontmostApplicationProvider: { frontmost },
            applicationActivator: { target in
                // Context capture must yield both the window and regular app
                // activation before asking the external app to take focus.
                #expect(NSApp.activationPolicy() == .accessory)
                #expect(fixture.dependencies.modalHost.window?.isVisible == false)
                restored = target
                frontmost = target
                return true
            }
        )
        let controller = PickyHubWindowController(
            dependencies: fixture.dependencies,
            foregroundContextPreserver: preserver
        )
        defer {
            controller.close()
            NSApp.setActivationPolicy(originalPolicy)
            originalForeground?.activate(options: [])
            fixture.removeTemporaryState()
        }

        controller.show()
        try await waitUntil { NSApp.isActive && fixture.dependencies.modalHost.window?.isKeyWindow == true }
        #expect(NSApp.activationPolicy() == .regular)
        frontmost = picky
        await controller.restoreExternalForegroundForVoiceContextCapture()
        #expect(restored == editor)
        #expect(!controller.isVisible)
        #expect(!fixture.navigator.isWindowVisible)
        #expect(NSApp.activationPolicy() == .accessory)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The isolated Hub window did not reach the expected AppKit state")
    }
}
