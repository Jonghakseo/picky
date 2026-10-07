import AppKit
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockMinimizedPresentationTests {
    @Test func targetedSessionRequestRestoresOnlyItsMinimizedDisplayAndResolvesTheCard() {
        let viewModel = PickySessionListViewModel(
            client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()
        )
        let target = PickyHUDPlacement(dockSide: .right)
        let other = PickyHUDPlacement(dockSide: .bottom)
        target.isMinimized = true
        other.isMinimized = true

        viewModel.requestOpenSession(sessionID: "pickle", targetDisplayID: 777)
        let request = viewModel.dockState.snapshot.openSessionRequest
        let ignored = PickyHUDDockOpenRequestPolicy.apply(
            request, displayID: 888, openedSessionID: nil, placement: other
        )
        #expect(ignored == nil)
        #expect(other.isMinimized)

        let effect = PickyHUDDockOpenRequestPolicy.apply(
            request, displayID: 777, openedSessionID: nil, placement: target
        )
        #expect(effect == .open("pickle"))
        #expect(!target.isMinimized)
        #expect(PickyHUDDockLayout.requestedOpenResolution(
            pendingSessionID: "pickle", visibleIDs: ["pickle"]
        ) == .open("pickle"))
        #expect(other.isMinimized)

        viewModel.requestCloseSession(sessionID: "pickle", targetDisplayID: 777)
        let close = viewModel.dockState.snapshot.openSessionRequest
        #expect(PickyHUDDockOpenRequestPolicy.apply(
            close, displayID: 777, openedSessionID: "other", placement: target
        ) == nil)
        #expect(PickyHUDDockOpenRequestPolicy.apply(
            close, displayID: 777, openedSessionID: "pickle", placement: target
        ) == .close("pickle"))
    }

    @Test func minimizedRailPublishesOnlyTheRestoreButtonForDesktopHitTesting() throws {
        let projection = PickyDockProjector.project(
            layout: PickyDockLayout(entries: [.session(id: "first"), .session(id: "second")]),
            visibleSessionIDs: ["first", "second"]
        )
        final class Frames { var values: [CGRect] = [] }
        for side: PickyHUDDockSide in [.right, .bottom] {
            let frames = Frames()
            let view = PickyHUDDockMinimizedPresentation(
                isLoading: false, isMinimized: true, dockSide: side, metrics: .medium,
                projection: projection, activeSessionIDs: ["first", "second"], availableRailLength: 400,
                activeSessionID: "first", unreadCount: 3, onRestore: {}
            ) { Color.red.frame(width: 400, height: 400) }
                .padding(20)
                .coordinateSpace(name: PickyHUDVisibleChromeCoordinateSpaceName)
                .onPreferenceChange(PickyHUDVisibleChromeFramePreferenceKey.self) { frames.values = $0 }
            let size = NSHostingView(rootView: view).fittingSize
            let bitmap = PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size,
                scale: 2, appearance: .aqua)
            #expect(bitmap != nil)
            let only = try #require(frames.values.count == 1 ? frames.values.first : nil)
            #expect(only.size == CGSize(width: 32, height: 32))
            #expect(only.width < size.width && only.height < size.height)
        }
    }

    @Test func minimizedUnreadBadgeShowsCountOnlyWhenPicklesAreUnread() {
        #expect(PickyHUDDockMinimizedUnreadBadge.label(unreadCount: 0) == nil)
        #expect(PickyHUDDockMinimizedUnreadBadge.label(unreadCount: 3) == "3")
        #expect(PickyHUDDockMinimizedUnreadBadge.label(unreadCount: 99) == "99")
        #expect(PickyHUDDockMinimizedUnreadBadge.label(unreadCount: 120) == "99+")
    }

    @Test func minimizedLogoRestoresOnClickButMovesWithoutRestoringAfterDrag() throws {
        var restores = 0
        var deltas: [CGPoint] = []
        var dragEnds = 0
        let hosting = NSHostingView(rootView: PickyHUDDockMinimizedButton(
            onRestore: { restores += 1 }, onDragChanged: { deltas.append($0) },
            onDragEnded: { dragEnds += 1 }
        ))
        hosting.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        hosting.layoutSubtreeIfNeeded()
        func findHandle(in view: NSView) -> PickyHUDDockAnchorHandleNSView? {
            if let handle = view as? PickyHUDDockAnchorHandleNSView { return handle }
            return view.subviews.lazy.compactMap { findHandle(in: $0) }.first
        }
        let handle = try #require(findHandle(in: hosting))
        var pointer = CGPoint(x: 100, y: 100)
        handle.pointerLocation = { pointer }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        handle.mouseDown(with: try event(.leftMouseDown))
        pointer = CGPoint(x: 102, y: 101)
        handle.mouseDragged(with: try event(.leftMouseDragged))
        handle.mouseUp(with: try event(.leftMouseUp))
        #expect(restores == 1)
        #expect(deltas.isEmpty && dragEnds == 0)

        pointer = CGPoint(x: 100, y: 100)
        handle.mouseDown(with: try event(.leftMouseDown))
        pointer = CGPoint(x: 130, y: 120)
        handle.mouseDragged(with: try event(.leftMouseDragged))
        // Returning to the press point must not turn a completed drag into a click.
        pointer = CGPoint(x: 100, y: 100)
        handle.mouseDragged(with: try event(.leftMouseDragged))
        handle.mouseUp(with: try event(.leftMouseUp))
        #expect(deltas == [CGPoint(x: 30, y: 20), .zero])
        #expect(dragEnds == 1)
        #expect(restores == 1)
    }

    @Test func minimizedRailPreservesTheExpandedFootprintWhenOverflowing() {
        let layout = PickyDockLayout(entries: [
            .session(id: "first"), .session(id: "second"), .session(id: "third")
        ])
        let projection = PickyDockProjector.project(
            layout: layout, visibleSessionIDs: ["first", "second", "third"]
        )
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for side: PickyHUDDockSide in [.right, .bottom] {
                let available: CGFloat = 150
                let active: Set<String> = ["first", "second", "third"]
                let size = PickyHUDDockMinimizedGeometry.railSize(
                    projection: projection, activeSessionIDs: active, dockSide: side, metrics: metrics,
                    availableRailLength: available
                )
                let content = PickyHUDDockRailLayoutPolicy.contentLength(
                    projection: projection, activeSessionIDs: active,
                    dockSide: side, metrics: metrics
                )
                let length = min(content, available)
                #expect(side.orientation == .vertical ? size.height == length : size.width == length)
                let view = PickyHUDDockMinimizedPresentation(
                    isLoading: false, isMinimized: true, dockSide: side, metrics: metrics,
                    projection: projection, activeSessionIDs: active, availableRailLength: available,
                    activeSessionID: nil, onRestore: {}
                ) { Color.red.frame(width: 500, height: 500) }
                let fitted = NSHostingView(rootView: view).fittingSize
                #expect(abs(fitted.width - size.width) < 1)
                #expect(abs(fitted.height - size.height) < 1)
            }
        }
    }
}
