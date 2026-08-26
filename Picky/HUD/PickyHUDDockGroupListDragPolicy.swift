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
    /// Pulled clear of the panel long enough to mean "leave this group".
    case ungroup
    /// Released too early, or on nothing meaningful. Restore the original order.
    case cancel
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

    /// Pull-out is deliberately slower than a flick: a pointer that merely
    /// clips the panel edge mid-reorder must not silently ungroup the Pickle.
    static let pullOutDwell: TimeInterval = 0.25

    static func outcome(
        isInsidePanel: Bool,
        timeOutsidePanel: TimeInterval,
        insertionIndex: Int,
        isDraggedRowStillPresent: Bool
    ) -> PickyHUDDockGroupListDragOutcome {
        guard isDraggedRowStillPresent else { return .cancel }
        if isInsidePanel { return .reorder(visibleIndex: insertionIndex) }
        return timeOutsidePanel >= pullOutDwell ? .ungroup : .cancel
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

    /// Negative scrolls toward the top, positive toward the bottom, zero in the
    /// middle of the panel. Only the edge bands scroll, and the ramp is linear
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
