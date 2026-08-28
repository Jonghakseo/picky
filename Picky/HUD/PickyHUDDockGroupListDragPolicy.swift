//
//  PickyHUDDockGroupListDragPolicy.swift
//  Picky
//
//  Row drag geometry for the dock group list. The list is vertical on every
//  dock side, so unlike the rail this resolves on Y alone. Everything here is
//  pure so the drop index, the pull-out decision, and the auto-scroll ramp can
//  be tested without a live panel.
//

import CoreGraphics
import Foundation

enum PickyHUDDockGroupListDragOutcome: Equatable {
    /// Reorder within the group, expressed as a position among visible rows.
    case reorder(visibleIndex: Int)
    /// Cross-axis panel exit transfers this physical press to Overlay Manager.
    case promote
    /// Released on nothing meaningful. Restore the original order.
    case cancel
}

/// Token-scoped terminal-event ownership for one physical group-list drag.
/// A list monitor must synchronously transfer before Overlay Manager can own
/// mouse-up, so late local/global monitor callbacks cannot persist a second move.
@MainActor
final class PickyHUDDockGroupListDragLease {
    enum Owner: Equatable {
        case idle
        case list(UUID)
        case external(UUID)
    }

    private(set) var owner: Owner = .idle

    func begin(token: UUID) -> Bool {
        guard owner == .idle else { return false }
        owner = .list(token)
        return true
    }

    func transferToExternal(token: UUID) -> Bool {
        guard owner == .list(token) else { return false }
        owner = .external(token)
        return true
    }

    func ownsList(token: UUID) -> Bool { owner == .list(token) }
    func ownsExternal(token: UUID) -> Bool { owner == .external(token) }

    func reset(token: UUID) {
        guard owner == .list(token) || owner == .external(token) else { return }
        owner = .idle
    }
}

enum PickyHUDDockGroupListDragPolicy {
    /// A drop lands before the first row whose center sits below the pointer,
    /// which yields `rowCenters.count` when the pointer is past the last row.
    static func insertionIndex(pointerY: CGFloat, rowCenters: [CGFloat]) -> Int {
        rowCenters.reduce(into: 0) { index, center in
            if pointerY > center { index += 1 }
        }
    }

    /// Removing the dragged row shifts every later row up by one, so an
    /// insertion index measured against the full list overshoots by one once it
    /// passes the dragged row's own position.
    static func normalizedInsertionIndex(_ index: Int, draggedRowIndex: Int) -> Int {
        index > draggedRowIndex ? index - 1 : index
    }

    /// Live preview order while a drag is in flight.
    static func previewOrder(rowIDs: [String], draggedRowID: String, insertionIndex: Int) -> [String] {
        guard let currentIndex = rowIDs.firstIndex(of: draggedRowID) else { return rowIDs }
        var reordered = rowIDs
        reordered.remove(at: currentIndex)
        let clamped = min(max(insertionIndex, 0), reordered.count)
        reordered.insert(draggedRowID, at: clamped)
        return reordered
    }

    /// Membership geometry is captured when a row drag begins. Content-only
    /// updates may continue, but any visible membership add, removal, or
    /// reorder invalidates the frozen row centers and insertion marker.
    static func shouldCancelDrag(referenceRowIDs: [String], currentRowIDs: [String]) -> Bool {
        !isCurrent(referenceRowIDs: referenceRowIDs, currentRowIDs: currentRowIDs)
    }

    /// Used by both the deferred SwiftUI observation and the synchronous
    /// mouse-monitor update/commit paths.
    static func isCurrent(referenceRowIDs: [String], currentRowIDs: [String]) -> Bool {
        referenceRowIDs == currentRowIDs
    }

    static func outcome(
        isInsidePanel: Bool,
        insertionIndex: Int,
        isDraggedRowStillPresent: Bool
    ) -> PickyHUDDockGroupListDragOutcome {
        guard isDraggedRowStillPresent else { return .cancel }
        return isInsidePanel ? .reorder(visibleIndex: insertionIndex) : .promote
    }

    static let autoScrollEdgeInset: CGFloat = 24
    static let autoScrollPointsPerSecond: CGFloat = 240

    /// A vertical list treats leaving on its horizontal cross-axis as an
    /// intentional pull-out. Moving past its top or bottom edge stays in the
    /// reorder lane so edge scrolling cannot accidentally ungroup a Pickle.
    static func isWithinReorderLane(pointerX: CGFloat, panelWidth: CGFloat) -> Bool {
        pointerX >= 0 && pointerX <= panelWidth
    }

    /// Advances a visual scroll offset by the edge velocity while respecting
    /// the document's reachable range. The AppKit bridge maps this visual
    /// offset to its flipped or unflipped document coordinates.
    static func autoScrollPosition(
        currentOffset: CGFloat,
        velocity: CGFloat,
        elapsed: TimeInterval,
        maximumOffset: CGFloat
    ) -> CGFloat {
        min(max(currentOffset + (velocity * CGFloat(elapsed)), 0), max(0, maximumOffset))
    }

    /// Native scrolling moves the row visuals before SwiftUI publishes fresh
    /// preferences. Apply this exact visual-coordinate delta immediately so a
    /// mouse-up in that gap resolves against the visible rows.
    static func rowCenters(
        afterVisualOffsetDelta visualOffsetDelta: CGFloat,
        from rowCenters: [String: CGFloat]
    ) -> [String: CGFloat] {
        rowCenters.mapValues { $0 + visualOffsetDelta }
    }

    /// Keep full row geometry in the same visual coordinate space as centers
    /// until the next SwiftUI preference pass replaces both measurements.
    static func rowFrames(
        afterVisualOffsetDelta visualOffsetDelta: CGFloat,
        from rowFrames: [String: CGRect]
    ) -> [String: CGRect] {
        rowFrames.mapValues { $0.offsetBy(dx: 0, dy: visualOffsetDelta) }
    }

    /// Resolves edge velocity against the actual visible viewport, not the
    /// whole panel. The panel also contains header and padding chrome above the
    /// scroll view, so this frame must share the pointer's panel-local space.
    static func autoScrollVelocity(pointerY: CGFloat, viewportFrame: CGRect) -> CGFloat {
        guard viewportFrame.height > 0 else { return 0 }
        return autoScrollVelocity(
            pointerY: pointerY - viewportFrame.minY,
            panelHeight: viewportFrame.height
        )
    }

    /// Negative scrolls toward the top, positive toward the bottom, zero in the
    /// middle of the viewport. Only the edge bands scroll, and the ramp is linear
    /// so the speed is predictable near the boundary.
    static func autoScrollVelocity(pointerY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        guard panelHeight > autoScrollEdgeInset * 2 else { return 0 }
        if pointerY < autoScrollEdgeInset {
            let depth = (autoScrollEdgeInset - max(pointerY, 0)) / autoScrollEdgeInset
            return -autoScrollPointsPerSecond * min(depth, 1)
        }
        let bottomBand = panelHeight - autoScrollEdgeInset
        if pointerY > bottomBand {
            let depth = (min(pointerY, panelHeight) - bottomBand) / autoScrollEdgeInset
            return autoScrollPointsPerSecond * min(depth, 1)
        }
        return 0
    }
}
