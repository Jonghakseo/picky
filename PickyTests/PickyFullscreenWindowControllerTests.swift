//
//  PickyFullscreenWindowControllerTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
@Suite("PickyFullscreenWindowController")
struct PickyFullscreenWindowControllerTests {
    @Test func fullscreenWindowDisablesMiniaturizeButKeepsCloseAndResize() throws {
        let controller = makeController { _ in }
        let window = try #require(controller.window)

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test func fullscreenWindowRetainsInjectedAppearanceStore() {
        let appearanceStore = PickyAppearanceStore()
        let controller = makeController(appearanceStore: appearanceStore) { _ in }

        #expect(controller.appearanceStore === appearanceStore)
    }

    @Test func closeCallbackRunsAfterHostedWindowTeardown() async throws {
        var callbackSnapshot: CloseCallbackSnapshot?
        let controller = makeController { controller in
            callbackSnapshot = CloseCallbackSnapshot(
                controllerWindowIsNil: controller.window == nil
            )
        }
        let hostedWindow = try #require(controller.window)
        #expect(hostedWindow.contentView != nil)
        #expect(hostedWindow.delegate != nil)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: hostedWindow))

        #expect(callbackSnapshot == nil)
        #expect(controller.window == nil)
        #expect(hostedWindow.contentView == nil)
        #expect(hostedWindow.delegate == nil)

        await Task.yield()

        #expect(callbackSnapshot == CloseCallbackSnapshot(controllerWindowIsNil: true))
    }

    @Test func duplicateCloseNotificationsReportOnlyOnce() async throws {
        var callbackCount = 0
        let controller = makeController { _ in
            callbackCount += 1
        }
        let hostedWindow = try #require(controller.window)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: hostedWindow))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: hostedWindow))

        await Task.yield()

        #expect(callbackCount == 1)
    }

    private func makeController(
        appearanceStore: PickyAppearanceStore? = nil,
        onClose: @escaping @MainActor (PickyFullscreenWindowController) -> Void
    ) -> PickyFullscreenWindowController {
        let injectedAppearanceStore = appearanceStore ?? PickyAppearanceStore()
        return PickyFullscreenWindowController(
            viewModel: PickySessionListViewModel(
                client: StubFullscreenWindowAgentClient(),
                notificationCenter: PickyNoopNotificationCenter()
            ),
            stateStore: PickyFullscreenStateStore(defaults: makeDefaults()),
            appearanceStore: injectedAppearanceStore,
            onClose: onClose
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "picky-fullscreen-window-controller-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct CloseCallbackSnapshot: Equatable {
    let controllerWindowIsNil: Bool
}

private final class StubFullscreenWindowAgentClient: PickyAgentClient {
    let events: AsyncStream<PickyClientEvent>

    init() {
        self.events = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func connect() async { }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }

    func send(_ command: PickyCommandEnvelope) async throws { }

    func disconnect() { }
}
