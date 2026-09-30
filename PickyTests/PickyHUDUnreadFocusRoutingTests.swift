import AppKit
import Combine
import CoreGraphics
import SwiftUI
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHUDUnreadFocusRoutingTests {
    @Test func focusesOnlyTheTargetDisplayAfterRestoringMinimizedInput() {
        let target = FakeHUDSessionFocusPanel()
        let other = FakeHUDSessionFocusPanel()

        PickyHUDSessionFocusPresenter.present(
            targetDisplayID: 777,
            panelsByDisplayID: [777: target, 888: other]
        )

        #expect(target.orderFrontCallCount == 1)
        #expect(target.makeKeyCallCount == 1)
        #expect(other.orderFrontCallCount == 0)
        #expect(other.makeKeyCallCount == 0)
    }

    @Test func restoresHiddenTargetDisplayAndKeepsDisplayOnOpenRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyHUDUnreadFocusRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = PickySettingsStore(appSupportRoot: root)
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter()
        )
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "snapshot",
            protocolVersion: "1",
            timestamp: Date(),
            event: .sessionSnapshot(PickySessionSnapshot(sessions: [
                session(id: "first"),
                session(id: "unread"),
            ]))
        )))
        viewModel.dockLayout = PickyDockLayout(entries: [
            .session(id: "first"),
            .session(id: "unread"),
        ])
        viewModel.unreadSessionIDs = ["unread"]

        let visibilityStore = PickyHUDVisibilityStore(settingsStore: settingsStore)
        visibilityStore.setAllVisible(false, persist: false)
        let manager = PickyHUDOverlayManager(
            viewModel: viewModel,
            appearanceStore: PickyAppearanceStore(settingsStore: settingsStore),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settingsStore),
            visibilityStore: visibilityStore,
            settingsStore: settingsStore,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry()
        )
        let displayID: CGDirectDisplayID = 777

        let opened = manager.focusUnreadOrRecentSession(
            targetDisplayID: displayID,
            persistVisibility: false
        )

        #expect(opened == "unread")
        #expect(visibilityStore.isVisible(for: displayID))
        #expect(viewModel.openSessionRequest?.sessionID == "unread")
        #expect(viewModel.openSessionRequest?.targetDisplayID == displayID)
        #expect(viewModel.unreadSessionIDs.contains("unread"))
    }

    @Test func notificationActivationOpensSourcePickleOnHiddenHUDWithoutPresentingHub() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyNotificationHUDRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PickySettingsStore(appSupportRoot: root)
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(),
            notificationCenter: PickyNoopNotificationCenter()
        )
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "snapshot",
            protocolVersion: "1",
            timestamp: Date(),
            event: .sessionSnapshot(PickySessionSnapshot(sessions: [
                session(id: "other"), session(id: "notified"),
            ]))
        )))
        viewModel.select(sessionID: "other")
        let visibility = PickyHUDVisibilityStore(settingsStore: settings)
        visibility.setAllVisible(false, persist: false)
        let target = FakeHUDSessionFocusPanel()
        let other = FakeHUDSessionFocusPanel()
        let manager = PickyHUDOverlayManager(
            viewModel: viewModel,
            appearanceStore: PickyAppearanceStore(settingsStore: settings),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settings),
            visibilityStore: visibility,
            settingsStore: settings,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry(),
            presentSessionPanels: { displayID in
                PickyHUDSessionFocusPresenter.present(
                    targetDisplayID: displayID,
                    panelsByDisplayID: [777: target, 888: other]
                )
            }
        )
        var scheduledActions: [@MainActor () -> Void] = []
        let router = PickyAppActivationRouter(schedule: { _, action in scheduledActions.append(action) })
        var hubPresentationCount = 0

        router.handleReopen { hubPresentationCount += 1 }
        let response = try #require(router.recordNotificationResponse(identifier: "notified:7"))
        router.handleNotificationResponse(response) { sessionID in
            manager.focusSession(id: sessionID, targetDisplayID: 777, persistVisibility: false)
        }
        router.handleReopen { hubPresentationCount += 1 }
        router.handleReopen { hubPresentationCount += 1 }
        scheduledActions.forEach { $0() }

        #expect(hubPresentationCount == 0)
        #expect(visibility.isVisible(for: 777))
        #expect(!visibility.isVisible(for: 888))
        #expect(target.orderFrontCallCount == 1)
        #expect(target.makeKeyCallCount == 1)
        #expect(other.orderFrontCallCount == 0)
        #expect(other.makeKeyCallCount == 0)
        #expect(viewModel.openSessionRequest?.targetDisplayID == 777)
        #expect(viewModel.selectedSessionID == "notified")
        #expect(PickyHUDDockLayout.requestedOpenResolution(
            pendingSessionID: viewModel.openSessionRequest?.sessionID,
            visibleIDs: viewModel.sessions.map(\.id)
        ) == .open("notified"))
    }

    @Test func selectingGroupMemberOpensAndFocusesOnlyItsDisplay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyGroupSelectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PickySettingsStore(appSupportRoot: root)
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()
        )
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "snapshot", protocolVersion: "1", timestamp: Date(),
            event: .sessionSnapshot(PickySessionSnapshot(sessions: [session(id: "member")]))
        )))
        let visibility = PickyHUDVisibilityStore(settingsStore: settings)
        let target = FakeHUDSessionFocusPanel()
        let other = FakeHUDSessionFocusPanel()
        let manager = PickyHUDOverlayManager(
            viewModel: viewModel,
            appearanceStore: PickyAppearanceStore(settingsStore: settings),
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settings),
            visibilityStore: visibility, settingsStore: settings,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry(),
            presentSessionPanels: { displayID in
                PickyHUDSessionFocusPresenter.present(
                    targetDisplayID: displayID, panelsByDisplayID: [777: target, 888: other]
                )
            }
        )

        manager.selectDockGroupListRow(displayID: 777, sessionID: "member")

        #expect(viewModel.selectedSessionID == "member")
        #expect(viewModel.openSessionRequest?.sessionID == "member")
        #expect(viewModel.openSessionRequest?.targetDisplayID == 777)
        #expect(target.makeKeyCallCount == 1)
        #expect(other.makeKeyCallCount == 0)
    }

    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func groupMemberOpenedFromAnotherWindowClosesOnFirstCommandW() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PickyGroupKeyboardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = PickySettingsStore(appSupportRoot: root)
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()
        )
        viewModel.apply(.protocolEvent(PickyEventEnvelope(
            id: "snapshot", protocolVersion: "1", timestamp: Date(),
            event: .sessionSnapshot(PickySessionSnapshot(sessions: [session(id: "member")]))
        )))
        let appearance = PickyAppearanceStore(settingsStore: settings)
        let manager = PickyHUDOverlayManager(
            viewModel: viewModel, appearanceStore: appearance,
            fontScaleStore: PickyAppFontScaleStore(settingsStore: settings),
            visibilityStore: PickyHUDVisibilityStore(settingsStore: settings), settingsStore: settings,
            voiceTargetHitTestRegistry: PickyVoiceTargetHitTestRegistry()
        )
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 80, y: 80, width: 640, height: 600),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let previousWindow = NSWindow(
            contentRect: NSRect(x: 760, y: 80, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        previousWindow.isReleasedWhenClosed = false
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            previousWindow.orderOut(nil)
            previousWindow.close()
        }
        let placement = PickyHUDPlacement()
        panel.identifier = NSUserInterfaceItemIdentifier("group-keyboard-test")
        let closeRequests = PassthroughSubject<Void, Never>()
        panel.onCloseRequested = { closeRequests.send() }
        var openedSessionID: String?
        var renderedSessionID: String?
        let hosting = NSHostingView(rootView: LocalizedHostingRoot {
            PickyHUDView(
                viewModel: viewModel, dockState: viewModel.dockState,
                panelIdentifier: panel.identifier, closeRequests: closeRequests.eraseToAnyPublisher(),
                displayID: 777, placement: placement,
                onSizeChange: { _, sessionID in renderedSessionID = sessionID },
                onDockGroupListGeometryChange: { _, _, _, _, sessionID in openedSessionID = sessionID }
            )
            .environmentObject(appearance)
        })
        panel.contentView = hosting
        manager.panelsByDisplayID[777] = .init(
            panel: panel, placement: placement, lastContentSize: panel.frame.size
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        previousWindow.makeKeyAndOrderFront(nil)
        try await waitForGroupKeyboardState { NSApp.keyWindow === previousWindow }

        manager.selectDockGroupListRow(displayID: 777, sessionID: "member")
        try await waitForGroupKeyboardState {
            NSApp.keyWindow === panel && openedSessionID == "member" && renderedSessionID == "member"
        }
        let keyWindow = try #require(NSApp.keyWindow)
        let close = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: keyWindow.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        NSApp.sendEvent(close)
        try await waitForGroupKeyboardState { openedSessionID == nil && renderedSessionID == nil }
        #expect(panel.isVisible, "Closing the card must leave its dock panel alive")
        #expect(viewModel.sessions.contains { $0.id == "member" }, "Cmd+W must not archive the Pickle")
    }

    private func waitForGroupKeyboardState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "The production HUD must reach the expected keyboard/render state")
    }

    private func session(id: String) -> PickyAgentSession {
        PickyAgentSession(
            id: id,
            title: id,
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )
    }
}

@MainActor
private final class FakeHUDSessionFocusPanel: PickyHUDSessionFocusPanelPresenting {
    private(set) var orderFrontCallCount = 0
    private(set) var makeKeyCallCount = 0
    private var acceptsKeyFocus = false

    func prepareForSessionFocus() { acceptsKeyFocus = true }

    func orderFrontRegardless() {
        orderFrontCallCount += 1
    }

    func makeKey() {
        // Model the native minimized panel refusing key focus until restored.
        guard acceptsKeyFocus else { return }
        makeKeyCallCount += 1
    }
}
