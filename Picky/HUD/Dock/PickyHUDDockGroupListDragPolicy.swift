//
//  PickyHUDDockGroupListDragPolicy.swift
//  Picky
//
//  Row drag policy for the dock group list. Rows can be pulled out to the
//  external dock drag coordinator, but never reordered within this list.
//

import Foundation

enum PickyHUDDockGroupListDragOutcome: Equatable {
    /// Cross-axis panel exit transfers this physical press to Overlay Manager.
    case promote
    /// Released in the source panel or after its source row disappeared.
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

enum PickyHUDDockGroupListDragMonitorPolicy {
    private static let requiredMonitorCount = 4

    static func completeSet(
        from monitors: [Any?],
        remove: (Any) -> Void
    ) -> [Any]? {
        let installed = monitors.compactMap { $0 }
        guard monitors.count == requiredMonitorCount,
              installed.count == requiredMonitorCount
        else {
            installed.forEach(remove)
            return nil
        }
        return installed
    }
}

enum PickyHUDDockGroupListDragPolicy {
    /// Membership is captured when a row drag begins. Content-only updates may
    /// continue, but a visible member add, removal, or order change cancels the
    /// drag before it can be promoted with a stale source snapshot.
    static func shouldCancelDrag(referenceRowIDs: [String], currentRowIDs: [String]) -> Bool {
        !isCurrent(referenceRowIDs: referenceRowIDs, currentRowIDs: currentRowIDs)
    }

    /// Used by both the deferred SwiftUI observation and the synchronous
    /// mouse-monitor update/commit paths.
    static func isCurrent(referenceRowIDs: [String], currentRowIDs: [String]) -> Bool {
        referenceRowIDs == currentRowIDs
    }

    /// A vertical group list treats leaving its horizontal bounds as an
    /// intentional pull-out. Vertical travel remains in the source panel so a
    /// release there simply cancels rather than changing the member order.
    static func isOutsidePanelHorizontally(pointerX: CGFloat, panelWidth: CGFloat) -> Bool {
        pointerX < 0 || pointerX > panelWidth
    }

    static func outcome(
        isOutsidePanelHorizontally: Bool,
        isDraggedRowStillPresent: Bool
    ) -> PickyHUDDockGroupListDragOutcome {
        guard isDraggedRowStillPresent else { return .cancel }
        return isOutsidePanelHorizontally ? .promote : .cancel
    }
}
