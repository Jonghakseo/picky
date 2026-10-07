import CoreGraphics
import SwiftUI

/// Keeps the expanded rail's footprint while replacing its interactive subtree with one restore control.
/// This leaves the display-local NSPanel anchored at the same handle in either orientation.
struct PickyHUDDockMinimizedPresentation<ExpandedRail: View>: View {
    let isLoading: Bool
    let isMinimized: Bool
    let dockSide: PickyHUDDockSide
    let metrics: PickyHUDDockMetrics
    let projection: PickyDockProjection
    let activeSessionIDs: Set<String>
    let availableRailLength: CGFloat
    let activeSessionID: String?
    var unreadCount: Int = 0
    let onRestore: () -> Void
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    @ViewBuilder var expandedRail: () -> ExpandedRail

    @ViewBuilder var body: some View {
        if !isLoading {
            Group {
            if isMinimized {
                let size = PickyHUDDockMinimizedGeometry.railSize(
                    projection: projection, activeSessionIDs: activeSessionIDs,
                    dockSide: dockSide, metrics: metrics,
                    availableRailLength: availableRailLength
                )
                let origin = PickyHUDPlacement.minimizedButtonOrigin(
                    dockSide: dockSide, metrics: metrics, railSize: size
                )
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                    .overlay(alignment: .topLeading) {
                        PickyHUDDockMinimizedButton(onRestore: onRestore, unreadCount: unreadCount,
                            onDragChanged: onDragChanged, onDragEnded: onDragEnded)
                            .background(PickyHUDVisibleChromeFrameReporter())
                            .offset(x: origin.x, y: origin.y)
                    }
            } else {
                expandedRail()
                    .background(PickyHUDVisibleChromeFrameReporter())
            }
            }
            .zIndex(10)
            .transaction(value: activeSessionID) { transaction in
                transaction.animation = nil
            }
        }
    }
}

/// An open request restores its target display before the pending card is resolved.
enum PickyHUDDockOpenRequestEffect: Equatable {
    case open(String)
    case close(String)
}

@MainActor
enum PickyHUDDockOpenRequestPolicy {
    static func apply(
        _ request: PickyHUDOpenSessionRequest?,
        displayID: CGDirectDisplayID?,
        openedSessionID: String?,
        placement: PickyHUDPlacement
    ) -> PickyHUDDockOpenRequestEffect? {
        guard let request else { return nil }
        if let target = request.targetDisplayID, target != displayID { return nil }
        switch request.action {
        case .open:
            placement.isMinimized = false
            return .open(request.sessionID)
        case .close:
            guard openedSessionID == request.sessionID else { return nil }
            return .close(request.sessionID)
        }
    }
}

@MainActor
enum PickyHUDDockMinimizedGeometry {
    static func railSize(
        projection: PickyDockProjection,
        activeSessionIDs: Set<String>,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        availableRailLength: CGFloat,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGSize {
        let contentLength = PickyHUDDockRailLayoutPolicy.contentLength(
            projection: projection, activeSessionIDs: activeSessionIDs,
            dockSide: dockSide, metrics: metrics, fontScale: fontScale
        )
        let length = PickyHUDDockOverflowPolicy.layout(
            contentLength: contentLength, availableLength: availableRailLength,
            fixedChromeLength: PickyHUDDockRailLayoutPolicy.fixedChromeLength(dockSide: dockSide, metrics: metrics)
        ).railLength
        let cross = PickyHUDDockRailLayoutPolicy.crossSize(dockSide: dockSide, metrics: metrics, fontScale: fontScale)
        return dockSide.orientation == .horizontal
            ? CGSize(width: length, height: cross)
            : CGSize(width: cross, height: length)
    }
}
