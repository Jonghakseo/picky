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
}
