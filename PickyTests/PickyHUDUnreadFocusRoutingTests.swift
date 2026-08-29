import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHUDUnreadFocusRoutingTests {
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
