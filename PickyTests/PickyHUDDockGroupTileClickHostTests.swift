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

    private func renderedHeaderHost(
        onToggle: @escaping () -> Void,
        withContextMenu: Bool = false,
        isAddPresented: Bool = false,
        orientation: PickyHUDDockOrientation = .vertical
    ) throws -> (host: PickyHUDDockGroupTileClickNSView, hosting: NSHostingView<AnyView>) {
        let group = PickyDockGroup(id: "group", name: "Research", color: .teal, memberSessionIDs: [])
        let header = PickyHUDDockGroupHeaderRow(
            group: group,
            orientation: orientation,
            members: [],
            unreadCount: 0,
            metrics: PickyHUDDockMetrics(preset: .large),
            isSelected: false,
            isDropTargeted: false,
            isAddPresented: isAddPresented,
            onToggleCollapsed: onToggle,
            onSetColor: { _ in },
            onReorderBegan: {},
            onReorderChanged: { _ in },
            onReorderEnded: { _ in }
        ) { PickyHUDDockGroupAddButton(side: 18) {} }
        let root: AnyView = withContextMenu
            ? AnyView(header.pickyDockGroupContextMenu(
                group: group,
                activeSessionIDs: [],
                onRename: {},
                onSetColor: { _ in },
                onUngroup: {},
                onDeleteWithArchive: {}
            ))
            : AnyView(header)
        let hosting = NSHostingView(rootView: root)
        let size = orientation == .horizontal ? hosting.fittingSize : CGSize(width: 196, height: 24)
        hosting.frame = NSRect(origin: .zero, size: size)
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

    @Test func groupAndSessionNativeHostsReportOneEnterAndOneExitTransition() throws {
        var groupTransitions: [Bool] = []
        let groupCoordinator = PickyHUDDockGroupTileClickHost.Coordinator()
        groupCoordinator.onHoverChanged = { groupTransitions.append($0) }
        let groupHost = PickyHUDDockGroupTileClickNSView()
        groupHost.coordinator = groupCoordinator
        let sessionCoordinator = PickyHUDDockIconClickHost.Coordinator()
        var sessionTransitions: [Bool] = []
        sessionCoordinator.onHoverChanged = { sessionTransitions.append($0) }
        let sessionHost = PickyHUDDockIconClickNSView()
        sessionHost.coordinator = sessionCoordinator
        let event = try mouseEvent(.mouseMoved, at: .zero)

        groupHost.mouseEntered(with: event)
        groupHost.mouseExited(with: event)
        sessionHost.mouseEntered(with: event)
        sessionHost.mouseExited(with: event)

        #expect(groupTransitions == [true, false])
        #expect(sessionTransitions == [true, false])
    }

    @Test func renderedHeaderTogglesExactlyOnceOnMouseUpBelowReorderThreshold() throws {
        var activations = 0
        let rendered = try renderedHeaderHost(onToggle: { activations += 1 })

        rendered.host.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        rendered.host.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 2, y: 1)))

        #expect(activations == 1)
    }

    /// An NSView child wins AppKit hit testing over any SwiftUI button in the
    /// same hosting view, so the header host has to decline the slots its
    /// buttons occupy. The chevron keeps toggling the group.
    @Test func headerHostDeclinesTheColorDotAndTheNewPickleButtonButKeepsTheChevron() throws {
        let rendered = try renderedHeaderHost(onToggle: {}, isAddPresented: true)
        let host = rendered.host
        let bounds = host.bounds
        func owner(atDistanceFromTrailingEdge distance: CGFloat) -> NSView? {
            host.hitTest(host.convert(CGPoint(x: bounds.maxX - distance, y: bounds.midY), to: host.superview))
        }

        // Color dot: 1pt leading padding plus a 6pt dot in a 4pt hit pad.
        #expect(host.hitTest(host.convert(CGPoint(x: bounds.minX + 6, y: bounds.midY), to: host.superview)) == nil)
        #expect(host.hitTest(host.convert(CGPoint(x: bounds.minX + 40, y: bounds.midY), to: host.superview)) === host)
        // Trailing edge inward: 6pt padding, an 8pt chevron, 6pt spacing, then
        // the 18pt `+`.
        #expect(owner(atDistanceFromTrailingEdge: 10) === host)
        #expect(owner(atDistanceFromTrailingEdge: 30) == nil)
        #expect(owner(atDistanceFromTrailingEdge: 45) === host)
    }

    @Test func headerHostKeepsItsTrailingSlotWhileTheActionsAreHidden() throws {
        let rendered = try renderedHeaderHost(onToggle: {})
        let host = rendered.host
        let point = CGPoint(x: host.bounds.maxX - 30, y: host.bounds.midY)

        #expect(host.hitTest(host.convert(point, to: host.superview)) === host)
    }

    /// A header is taller than the 14pt dot and the 18pt `+`, so the band
    /// above and below them still has to toggle, drag, and open the group menu.
    @Test func headerHostKeepsTheBandAboveAndBelowItsButtons() throws {
        for orientation in [PickyHUDDockOrientation.vertical, .horizontal] {
            let rendered = try renderedHeaderHost(onToggle: {}, isAddPresented: true, orientation: orientation)
            let host = rendered.host
            let bounds = host.bounds
            func owner(_ x: CGFloat, _ y: CGFloat) -> NSView? {
                host.hitTest(host.convert(CGPoint(x: x, y: y), to: host.superview))
            }
            let dotX = bounds.minX + 6
            let addX = bounds.maxX - 30

            #expect(owner(dotX, bounds.midY) == nil, "\(orientation) dot center")
            #expect(owner(addX, bounds.midY) == nil, "\(orientation) add center")
            #expect(owner(dotX, bounds.maxY - 1) === host, "\(orientation) above the dot")
            #expect(owner(dotX, bounds.minY + 1) === host, "\(orientation) below the dot")
            #expect(owner(addX, bounds.maxY - 1) === host, "\(orientation) above the add button")
            #expect(owner(addX, bounds.minY + 1) === host, "\(orientation) below the add button")
        }
    }

    /// Same contract on a Pickle row: only the hovered archive button's own
    /// frame leaves the host, so the rest of the row keeps opening the Pickle.
    @Test func hoveredRowHostDeclinesOnlyTheArchiveButtonFrame() throws {
        let metrics = PickyHUDDockMetrics(preset: .large)
        let agentSession = PickyAgentSession(
            id: "row", title: "Row Pickle", status: .running, cwd: "/tmp/picky",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastSummary: "Row", logs: [], tools: [], artifacts: [], changedFiles: []
        )
        let row = PickyHUDDockSessionRow(
            session: PickyHUDDockSession(session: PickySessionCard.fromAgentSession(agentSession)),
            orientation: .vertical,
            isActive: false,
            isOpened: false,
            isScreenContextArmed: false,
            isScreenContextSticky: false,
            shortcutNumber: nil,
            isCommandShortcutHintVisible: false,
            shouldFlashCompletion: false,
            isUnread: false,
            metrics: metrics
        )
        let hosting = NSHostingView(rootView: AnyView(row.environment(\.pickyAppFontScale, 1)))
        hosting.frame = NSRect(x: 0, y: 0, width: metrics.listWidth, height: metrics.rowHeight(fontScale: 1))
        hosting.layoutSubtreeIfNeeded()
        let host = try #require(findSessionIconHost(in: hosting))

        #expect(host.holes == .none)
        host.mouseEntered(with: try mouseEvent(.mouseMoved, at: .zero))
        hosting.layoutSubtreeIfNeeded()

        let bounds = host.bounds
        let buttonX = bounds.maxX - (metrics.rowHorizontalPadding - 2) - metrics.rowActionSide / 2
        func owner(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            host.hitTest(host.convert(CGPoint(x: x, y: y), to: host.superview))
        }

        #expect(host.holes.trailing != nil)
        #expect(owner(buttonX, bounds.midY) == nil)
        #expect(owner(buttonX, bounds.maxY - 1) === host)
        #expect(owner(buttonX, bounds.minY + 1) === host)
        #expect(owner(bounds.midX, bounds.midY) === host)
    }

    @Test func headerHostHandsOffReorderWithoutTogglingOnRelease() throws {
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

    @Test func headerHostConvertsWindowYTranslationToSwiftUIDragDirection() {
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

    @Test func headerSecondaryAndControlClicksForwardTheSharedMenuWithoutToggling() throws {
        var activations = 0
        let renderedHeader = try renderedHeaderHost(onToggle: { activations += 1 }, withContextMenu: true)
        #expect(renderedHeader.host.contextMenuForwardingTarget() != nil)
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

    @Test func expandedGroupInProductionRailOpensMemberRowsAndTogglesFromTheHeader() throws {
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
        let group = PickyDockGroup(id: "group", name: "Solo", color: .teal, memberSessionIDs: [session.id], isCollapsed: false)
        let layout = PickyDockLayout(entries: [.group(group)])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: [session.id])
        let railHeight = PickyHUDDockRailLayoutPolicy.contentLength(
            projection: projection,
            activeSessionIDs: [session.id],
            dockSide: .right,
            metrics: metrics,
            fontScale: 1
        )
        var openedSessions: [String] = []
        var collapseRequests: [(String, Bool)] = []
        let rail = PickyHUDDockRailView(
            sessions: [session],
            baseProjection: projection,
            layout: layout,
            activeSessionID: nil,
            openedSessionID: nil,
            screenContextTargetSessionID: nil,
            screenContextTargetSticky: false,
            dockSide: .right,
            isCommandShortcutHintVisible: false,
            pendingDoneFlashSessionIDs: [],
            unreadSessionIDs: [],
            metrics: metrics,
            availableRailLength: railHeight,
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
            onSetDockGroupCollapsed: { collapseRequests.append(($0, $1)) },
            onRemoveDockGroup: { _, _ in },
            onMoveSessionInDock: { _, _ in },
            onMoveDockGroup: { _, _ in },
            onDockHoverChanged: { _ in },
            onAddSlotExpandedChanged: { _ in },
            onDoneFlashConsumed: { _ in },
            onDockHandleDragChanged: { _ in },
            onDockHandleDragEnded: {},
            onDockHandleDoubleClick: {}
        )
        let hosting = NSHostingView(rootView: rail.environment(\.pickyAppFontScale, 1))
        hosting.frame = NSRect(x: 0, y: 0, width: metrics.railWidth, height: railHeight)
        hosting.layoutSubtreeIfNeeded()
        let rowHost = try #require(findSessionIconHost(in: hosting))
        let headerHost = try #require(findTileHost(in: hosting))

        rowHost.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        rowHost.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero))
        headerHost.mouseDown(with: try mouseEvent(.leftMouseDown, at: .zero))
        headerHost.mouseUp(with: try mouseEvent(.leftMouseUp, at: .zero))

        #expect(openedSessions == [session.id])
        #expect(collapseRequests.count == 1)
        #expect(collapseRequests.first?.0 == group.id)
        #expect(collapseRequests.first?.1 == true)
    }
}
