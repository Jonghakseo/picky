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
    let availableRailLength: CGFloat
    let hasArchiveAccess: Bool
    let activeSessionID: String?
    let onRestore: () -> Void
    @ViewBuilder var expandedRail: () -> ExpandedRail

    private var previewReserve: CGFloat {
        dockSide.orientation == .horizontal
            ? PickyHUDDockLayout.miniPreviewHorizontalReserve(metrics: metrics) : 0
    }

    @ViewBuilder var body: some View {
        if !isLoading {
            Group {
            if isMinimized {
                let size = PickyHUDDockMinimizedGeometry.railSize(
                    projection: projection, dockSide: dockSide, metrics: metrics,
                    availableRailLength: availableRailLength, hasArchiveAccess: hasArchiveAccess
                )
                let origin = PickyHUDPlacement.minimizedButtonOrigin(
                    dockSide: dockSide, metrics: metrics, railSize: size
                )
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                    .overlay(alignment: .topLeading) {
                        PickyHUDDockMinimizedButton(onRestore: onRestore)
                            .background(PickyHUDVisibleChromeFrameReporter())
                            .offset(x: origin.x, y: origin.y)
                    }
                    .padding(.horizontal, previewReserve)
            } else {
                expandedRail()
                    .background(PickyHUDVisibleChromeFrameReporter())
                    .padding(.horizontal, previewReserve)
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
    /// Reserve the hover card's full extent past a horizontal rail, even while minimized.
    static func horizontalPreviewReserveHeight(metrics: PickyHUDDockMetrics) -> CGFloat {
        let estimatedPreviewHalfHeight = max(20, 25 * metrics.scale)
        return (estimatedPreviewHalfHeight * 2) + PickyHUDDockLayout.panelGap + 8
    }

    static func railSize(
        projection: PickyDockProjection,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        availableRailLength: CGFloat,
        hasArchiveAccess: Bool
    ) -> CGSize {
        let groups = PickyHUDDockRailLayoutPolicy.groupCount(in: projection)
        let contentLength = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: projection.slots.count, groupCount: groups,
            isAddSlotExpanded: false, dockSide: dockSide,
            metrics: metrics, hasArchiveAccess: hasArchiveAccess
        )
        let fixedChrome = PickyHUDDockRailLayoutPolicy.fixedChromeLength(
            isAddSlotExpanded: false, dockSide: dockSide,
            metrics: metrics, hasArchiveAccess: hasArchiveAccess
        )
        let length = PickyHUDDockOverflowPolicy.layout(
            contentLength: contentLength, availableLength: availableRailLength,
            fixedChromeLength: fixedChrome
        ).railLength
        let cross = PickyHUDDockRailLayoutPolicy.crossSize(
            groupCount: groups, dockSide: dockSide, metrics: metrics
        )
        return dockSide.orientation == .horizontal
            ? CGSize(width: length, height: cross)
            : CGSize(width: cross, height: length)
    }
}
