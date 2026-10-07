import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockDisplaySettingsTests {
    @Test func resizingOnlyChangesTheSourceDisplayAndRestoresEachSize() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let first = fixture.attachPanel(to: manager, displayID: 777)
        let second = fixture.attachPanel(to: manager, displayID: 888)
        let originalCardSize = first.placement.cardSize
        let firstWidth = first.placement.panelWidth
        let secondWidth = second.placement.panelWidth

        manager.changeDockSizePreset(.small, displayID: 777)
        #expect(first.placement.dockSizePreset == .small)
        #expect(second.placement.dockSizePreset == .large)
        #expect(second.placement.panelWidth == secondWidth)
        #expect(first.placement.panelWidth < firstWidth)
        #expect(first.placement.cardSize == originalCardSize)
        manager.changeDockSizePreset(.medium, displayID: 888)
        await fixture.flush()

        let saved = try fixture.store.loadStrict()
        #expect(saved.hudDockSizePresetsByDisplayID == ["777": .small, "888": .medium])
        #expect(saved.hudDockSizePreset == .large)
        #expect(saved.hudDockPositions == fixture.initial.hudDockPositions)
        #expect(saved.hudCardSizes == fixture.initial.hudCardSizes)

        let restored = fixture.makeManager()
        #expect(fixture.attachPanel(to: restored, displayID: 777).placement.dockSizePreset == .small)
        #expect(fixture.attachPanel(to: restored, displayID: 888).placement.dockSizePreset == .medium)
        #expect(restored.dockSizePreset(for: 999) == .large)
    }

    @Test func groupTogglesKeepOtherDisplaysAndSharedMembershipIntactAfterReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let first = fixture.attachPanel(to: manager, displayID: 777)
        let second = fixture.attachPanel(to: manager, displayID: 888)
        let original = manager.projectedDockProjection(for: 888)
        #expect(original.shortcutSessionIDs == ["a", "b", "c"])

        manager.setDockGroupCollapsed(id: "group", collapsed: true, displayID: 777)
        #expect(first.placement.dockGroupCollapseOverrides == ["group": true])
        #expect(second.placement.dockGroupCollapseOverrides.isEmpty)
        #expect(manager.projectedDockProjection(for: 777).shortcutSessionIDs == ["c"])
        #expect(manager.projectedDockProjection(for: 777).scrollTargetID(forSessionID: "a") == "group:group")
        #expect(manager.projectedDockProjection(for: 888) == original)

        // The opposite action on another group stays local too.
        manager.setDockGroupCollapsed(id: "closed", collapsed: false, displayID: 888)
        #expect(manager.projectedDockProjection(for: 888).shortcutSessionIDs == ["a", "b", "c", "d"])
        #expect(manager.projectedDockProjection(for: 777).shortcutSessionIDs == ["c"])
        fixture.viewModel.renameDockGroup(id: "group", to: "Renamed")
        fixture.viewModel.moveSessionInDock(sessionID: "c", to: .group(id: "group", memberIndex: 2))
        #expect(manager.projectedDockProjection(for: 777).shortcutSessionIDs.isEmpty)
        #expect(manager.projectedDockProjection(for: 888).shortcutSessionIDs == ["a", "b", "c", "d"])
        await fixture.flush()

        let saved = try fixture.store.loadStrict()
        #expect(saved.hudDockGroupCollapseByDisplayID == ["777": ["group": true], "888": ["closed": false]])
        #expect(saved.dockLayout.group(withID: "group")?.isCollapsed == false)
        #expect(saved.dockLayout.group(withID: "group")?.name == "Renamed")
        #expect(saved.dockLayout.group(withID: "group")?.memberSessionIDs == ["a", "b", "c"])
        let restored = fixture.makeManager()
        #expect(fixture.attachPanel(to: restored, displayID: 777).placement.dockGroupCollapseOverrides == ["group": true])
        #expect(restored.projectedDockProjection(for: 777).shortcutSessionIDs.isEmpty)
        #expect(restored.projectedDockProjection(for: 888).shortcutSessionIDs == ["a", "b", "c", "d"])
        #expect(restored.projectedDockProjection(for: 999).shortcutSessionIDs == ["a", "b", "c"])
    }

    @Test func settingsReloadDoesNotRollBackDockEditsWaitingForPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        let panel = fixture.attachPanel(to: manager, displayID: 777)
        let persistence = PickySettingsPersistenceCoordinator.shared(for: fixture.store)
        // Hold the filesystem transaction boundary, not the main actor.
        let releaseWriter = DispatchSemaphore(value: 0)
        defer { releaseWriter.signal() }
        persistence.enqueue { _ in releaseWriter.wait() }
        manager.changeDockSizePreset(.small, displayID: 777)
        manager.setDockGroupCollapsed(id: "group", collapsed: true, displayID: 777)

        let started = AsyncStream<Void>.makeStream()
        let reload = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            await manager.reloadDockSettings()
        }
        for await _ in started.stream { break }
        releaseWriter.signal()
        await reload.value
        await fixture.flush()

        #expect(panel.placement.dockSizePreset == .small)
        #expect(panel.placement.dockGroupCollapseOverrides == ["group": true])
        #expect(manager.projectedDockProjection(for: 777).shortcutSessionIDs == ["c"])
        let saved = try fixture.store.loadStrict()
        #expect(saved.hudDockSizePresetsByDisplayID["777"] == .small)
        #expect(saved.hudDockGroupCollapseByDisplayID["777"] == ["group": true])
    }

    @Test func legacySettingsKeepTheirSizeAndGroupStateWithoutDisplayOverrides() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.initial)) as? [String: Any])
        json.removeValue(forKey: "hudDockSizePresetsByDisplayID")
        json.removeValue(forKey: "hudDockGroupCollapseByDisplayID")
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.store.url)
        let decoded = try fixture.store.loadStrict()
        #expect(decoded.hudDockSizePresetsByDisplayID.isEmpty)
        #expect(decoded.hudDockGroupCollapseByDisplayID.isEmpty)
        #expect(decoded.hudDockSizePreset == .large)
        #expect(decoded.dockLayout == fixture.initial.dockLayout)
        let manager = fixture.makeManager()
        #expect(fixture.attachPanel(to: manager, displayID: 777).placement.dockSizePreset == .large)
        #expect(manager.projectedDockProjection(for: 777).shortcutSessionIDs == ["a", "b", "c"])
    }

    @Test func dragPreviewUsesLocalCollapseWithoutWritingItIntoTheSharedLayout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.makeManager()
        manager.setDockGroupCollapsed(id: "group", collapsed: true, displayID: 777)
        let projection = manager.projectedDockProjection(for: 777)
        let displayLayout = fixture.viewModel.dockLayout.applyingGroupCollapseOverrides(["group": true])
        let preview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
            layout: displayLayout, draggedSessionID: "c", destination: .group(id: "group", memberIndex: 0)
        )
        #expect(PickyDockProjector.project(layout: preview, visibleSessionIDs: ["a", "b", "c", "d"]) == projection)
        #expect(fixture.viewModel.dockLayout.group(withID: "group")?.isCollapsed == false)
        await fixture.flush()
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let store: PickySettingsStore
        let initial: PickySettings
        let viewModel: PickySessionListViewModel
        private var panels: [PickyHUDPanel] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("dock-displays-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = PickySettingsStore(appSupportRoot: root)
            var settings = PickySettings.defaults(appSupportRoot: root, seedDefaultWorkspace: false)
            settings.defaultCwd = root.path
            settings.mainAgentCwd = root.path
            settings.worktreeParent = root.path
            settings.hudDockSizePreset = .large
            settings.hudDockGroupsExpandedForListDock = true
            settings.hudDockPositions = ["777": .init(side: .right, anchorPercent: 30, xOffset: 0)]
            settings.hudCardSizes = ["777": .init(width: 600, height: 420)]
            settings.dockLayout = .init(entries: [
                .group(.init(id: "group", name: "Group", memberSessionIDs: ["a", "b"], isCollapsed: false)),
                .session(id: "c"),
                .group(.init(id: "closed", memberSessionIDs: ["d"], isCollapsed: true))
            ])
            try store.save(settings)
            initial = settings
            viewModel = PickySessionListViewModel(
                client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter(),
                dockLayoutStore: PickySettingsDockLayoutStore(settingsStore: store),
                pickleRuntimeDefaultsStore: store
            )
            let events = PickyProjectionEventFixtures()
            for id in ["a", "b", "c", "d"] {
                viewModel.apply(.protocolEvent(events.snapshotEnvelope(session: PickyAgentSession(
                    id: id, title: id, status: .running,
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
                    logs: [], tools: [], artifacts: [], changedFiles: []
                ))))
            }
            // Session snapshots coalesce their dock publication onto the next main-queue turn.
            viewModel.flushDockStateForTesting()
        }

        func makeManager() -> PickyHUDOverlayManager {
            PickyHUDOverlayManager(
                viewModel: viewModel,
                appearanceStore: PickyAppearanceStore(settingsStore: store),
                fontScaleStore: PickyAppFontScaleStore(settingsStore: store),
                visibilityStore: PickyHUDVisibilityStore(settingsStore: store),
                settingsStore: store
            )
        }

        func attachPanel(to manager: PickyHUDOverlayManager, displayID: CGDirectDisplayID) -> PickyHUDOverlayManager.PanelEntry {
            let entry = manager.makePanelEntry(displayID: displayID)
            manager.panelsByDisplayID[displayID] = entry
            panels.append(entry.panel)
            return entry
        }

        func flush() async { await PickySettingsPersistenceCoordinator.shared(for: store).flush() }

        func cleanUp() {
            for panel in panels { panel.contentView = nil }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
