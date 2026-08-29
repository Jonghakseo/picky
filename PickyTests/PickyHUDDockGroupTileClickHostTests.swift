//
//  PickyHUDDockGroupTileClickHostTests.swift
//  PickyTests
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupTileClickHostTests {
    private final class ContextMenuForwardingSpyView: NSView {
        var forwardedEvents: [NSEvent] = []

        override func rightMouseDown(with event: NSEvent) {
            forwardedEvents.append(event)
        }
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func renderedBadgeHost(
        onTap: @escaping () -> Void,
        onReorderBegan: @escaping () -> Void = {},
        onReorderChanged: @escaping (CGSize) -> Void = { _ in },
        onReorderEnded: @escaping (CGSize) -> Void = { _ in }
    ) throws -> (host: PickyHUDDockGroupTileClickNSView, hosting: NSHostingView<PickyHUDDockCollapsedGroupBadge>) {
        let badge = PickyHUDDockCollapsedGroupBadge(
            members: [],
            unreadCount: 0,
            tint: .blue,
            metrics: PickyHUDDockMetrics(preset: .large),
            onTap: onTap,
            onReorderBegan: onReorderBegan,
            onReorderChanged: onReorderChanged,
            onReorderEnded: onReorderEnded
        )
        let hosting = NSHostingView(rootView: badge)
        hosting.frame = NSRect(x: 0, y: 0, width: 54, height: 54)
        hosting.layoutSubtreeIfNeeded()
        return (try #require(findTileHost(in: hosting)), hosting)
    }

    private func renderedProductionFolder(
        onTap: @escaping () -> Void
    ) throws -> (host: PickyHUDDockGroupTileClickNSView, hosting: NSHostingView<AnyView>) {
        let group = PickyDockGroup(id: "group", name: "Research", color: .teal, memberSessionIDs: [])
        let metrics = PickyHUDDockMetrics(preset: .large)
        let root = AnyView(
            PickyHUDDockGroupFolderTileView(group: group, metrics: metrics, fontScale: 1) {
                PickyHUDDockCollapsedGroupBadge(
                    members: [],
                    unreadCount: 0,
                    tint: group.color.accent,
                    metrics: metrics,
                    onTap: onTap
                )
                .pickyDockGroupContextMenu(
                    group: group,
                    onRename: {},
                    onSetColor: { _ in },
                    onUngroup: {},
                    onDeleteWithArchive: {}
                )
            } header: { header in
                header
                    .pickyDockGroupContextMenu(
                        group: group,
                        onRename: {},
                        onSetColor: { _ in },
                        onUngroup: {},
                        onDeleteWithArchive: {}
                    )
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 80, height: 90)
        hosting.layoutSubtreeIfNeeded()
        return (try #require(findTileHost(in: hosting)), hosting)
    }

    private func findTileHost(in view: NSView) -> PickyHUDDockGroupTileClickNSView? {
        if let host = view as? PickyHUDDockGroupTileClickNSView { return host }
        return view.subviews.lazy.compactMap(findTileHost(in:)).first
    }

    private func findSessionIconHost(in view: NSView) -> PickyHUDDockIconClickNSView? {
        if let host = view as? PickyHUDDockIconClickNSView { return host }
        return view.subviews.lazy.compactMap(findSessionIconHost(in:)).first
    }

    @Test func renderedBadgeProductionPathActivatesExactlyOnceOnMouseUpBelowReorderThreshold() throws {
        var activations = 0
        let rendered = try renderedBadgeHost(onTap: { activations += 1 })

        rendered.host.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        rendered.host.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 2, y: 1)))

        #expect(activations == 1)
    }

    @Test func renderedBadgeProductionPathHandsOffReorderWithoutActivatingOnRelease() throws {
        var activations = 0
        var began = 0
        var changes: [CGSize] = []
        var endings: [CGSize] = []
        let coordinator = PickyHUDDockGroupTileClickHost.Coordinator()
        coordinator.onActivate = { activations += 1 }
        coordinator.onReorderBegan = { began += 1 }
        coordinator.onReorderChanged = { changes.append($0) }
        coordinator.onReorderEnded = { endings.append($0) }
        let host = PickyHUDDockGroupTileClickNSView()
        host.coordinator = coordinator

        host.beginInteraction(at: .zero)
        host.dragInteraction(to: NSPoint(x: 12, y: 0))
        host.endInteraction(at: NSPoint(x: 16, y: 0))

        #expect(activations == 0)
        #expect(began == 1)
        #expect(changes == [CGSize(width: 12, height: 0)])
        #expect(endings == [CGSize(width: 16, height: 0)])
    }

    @Test func productionBadgeConvertsWindowYTranslationToSwiftUIDragDirection() {
        var changes: [CGSize] = []
        var endings: [CGSize] = []
        let coordinator = PickyHUDDockGroupTileClickHost.Coordinator()
        coordinator.onReorderChanged = { changes.append($0) }
        coordinator.onReorderEnded = { endings.append($0) }
        let host = PickyHUDDockGroupTileClickNSView()
        host.coordinator = coordinator

        host.beginInteraction(at: NSPoint(x: 100, y: 100))
        host.dragInteraction(to: NSPoint(x: 112, y: 80))
        host.dragInteraction(to: NSPoint(x: 108, y: 120))
        host.endInteraction(at: NSPoint(x: 116, y: 70))

        #expect(changes == [
            CGSize(width: 12, height: 20),
            CGSize(width: 8, height: -20),
        ])
        #expect(endings == [CGSize(width: 16, height: 30)])
    }

    @Test func productionFolderSecondaryAndControlClicksForwardTheSharedMenuWithoutActivation() throws {
        var activations = 0
        let renderedFolder = try renderedProductionFolder(onTap: { activations += 1 })
        #expect(renderedFolder.host.contextMenuForwardingTarget() != nil)
        #expect(PickyHUDDockGroupContextMenuPresentation.actionTitles == [
            L10n.t("group.menu.rename"),
            L10n.t("group.menu.color"),
            L10n.t("group.menu.ungroup"),
            L10n.t("group.menu.delete"),
        ])

        let forwardingSpy = ContextMenuForwardingSpyView(frame: NSRect(x: 0, y: 0, width: 54, height: 54))
        let host = PickyHUDDockGroupTileClickNSView(frame: forwardingSpy.bounds)
        let coordinator = PickyHUDDockGroupTileClickHost.Coordinator()
        coordinator.onActivate = { activations += 1 }
        host.coordinator = coordinator
        forwardingSpy.addSubview(host)

        host.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: .zero))
        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero, modifierFlags: .control))

        #expect(forwardingSpy.forwardedEvents.count == 2)
        #expect(activations == 0)
    }

    @Test func singleMemberGroupProductionRailUsesTheSessionHoverAndOpenPath() throws {
        let metrics = PickyHUDDockMetrics(preset: .large)
        let agentSession = PickyAgentSession(
            id: "only",
            title: "Only Pickle",
            status: .running,
            cwd: "/tmp/picky",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastSummary: "Single member group",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )
        let session = PickyHUDDockSession(session: PickySessionCard.fromAgentSession(agentSession))
        let group = PickyDockGroup(id: "group", name: "Solo", color: .teal, memberSessionIDs: [session.id])
        let layout = PickyDockLayout(entries: [.group(group)])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: [session.id])
        let railHeight = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 1,
            groupCount: 1,
            isAddSlotExpanded: false,
            dockSide: .right,
            metrics: metrics
        )
        var hoveredSessions: [String] = []
        var openedSessions: [String] = []
        var activatedGroups: [String] = []
        var hoveredGroups: [String] = []
        let rail = PickyHUDDockRailView(
            sessions: [session],
            allSessions: [session],
            baseProjection: projection,
            layout: layout,
            activeSessionID: nil,
            openedSessionID: nil,
            previewSessionID: nil,
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            dockSide: .right,
            isCommandShortcutHintVisible: false,
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: [],
            metrics: metrics,
            availableRailLength: railHeight,
            onHoverSession: { hoveredSessions.append($0) },
            onOpenSession: { openedSessions.append($0) },
            onToggleScreenContextTarget: { _ in },
            onToggleStickyScreenContextTarget: { _ in },
            onCompactSession: { _ in },
            onArchiveSession: { _ in },
            onStopSession: { _ in },
            onCreatePickle: { _ in },
            pinnedPickleCwds: [],
            recentPickleCwds: [],
            onCreatePickleInRecentFolder: { _, _ in },
            onRemoveRecentPickleFolder: { _ in },
            onPinPickleFolder: { _ in },
            onUnpinPickleFolder: { _ in },
            onReorderPinnedPickleFolders: { _ in },
            onCreateDockGroup: { _, _ in "new-group" },
            onRenameDockGroup: { _, _ in },
            onSetDockGroupColor: { _, _ in },
            onActivateDockGroup: { activatedGroups.append($0) },
            onActivateDockGroupFromKeyboard: { _ in },
            onDockGroupTileHover: { groupID, _ in hoveredGroups.append(groupID) },
            onRemoveDockGroup: { _, _ in },
            onMoveSessionInDock: { _, _ in },
            onMoveDockGroup: { _, _ in },
            pendingPickleFolderPickerRequest: nil,
            onPickleFolderPickerPresentationAcknowledged: { _ in },
            onDockHoverChanged: { _ in },
            onAddSlotExpandedChanged: { _ in },
            onDoneFlashConsumed: { _ in },
            onDockHandleDragChanged: { _ in },
            onDockHandleDragEnded: {},
            onDockHandleDoubleClick: {}
        )
        let hosting = NSHostingView(rootView: rail)
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: PickyHUDDockRailLayoutPolicy.verticalCrossSize(groupCount: 1, metrics: metrics),
            height: railHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let iconHost = try #require(findSessionIconHost(in: hosting))

        iconHost.mouseEntered(with: try mouseEvent(.mouseMoved, at: .zero))
        iconHost.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        iconHost.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero))

        #expect(hoveredSessions == [session.id])
        #expect(openedSessions == [session.id])
        #expect(activatedGroups.isEmpty)
        #expect(hoveredGroups.isEmpty)
    }
}
