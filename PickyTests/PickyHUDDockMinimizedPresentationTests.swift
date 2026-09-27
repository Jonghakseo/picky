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
                projection: projection, availableRailLength: 400, hasArchiveAccess: true,
                activeSessionID: "first", onRestore: {}
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
                let size = PickyHUDDockMinimizedGeometry.railSize(
                    projection: projection, dockSide: side, metrics: metrics,
                    availableRailLength: available, hasArchiveAccess: true
                )
                let content = PickyHUDDockRailLayoutPolicy.contentLength(
                    sessionCount: projection.slots.count, isAddSlotExpanded: false,
                    dockSide: side, metrics: metrics, hasArchiveAccess: true
                )
                let length = min(content, available)
                #expect(side.orientation == .vertical ? size.height == length : size.width == length)
                let view = PickyHUDDockMinimizedPresentation(
                    isLoading: false, isMinimized: true, dockSide: side, metrics: metrics,
                    projection: projection, availableRailLength: available,
                    hasArchiveAccess: true, activeSessionID: nil, onRestore: {}
                ) { Color.red.frame(width: 500, height: 500) }
                let fitted = NSHostingView(rootView: view).fittingSize
                let previewReserve = side.orientation == .horizontal
                    ? PickyHUDDockLayout.miniPreviewHorizontalReserve(metrics: metrics) : 0
                #expect(abs(fitted.width - size.width - previewReserve * 2) < 1)
                #expect(abs(fitted.height - size.height) < 1)
            }
        }
    }
}
