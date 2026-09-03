//
//  PickyDockManualOrderPolicy.swift
//  Picky
//
//  Pure ordering rules for the user-draggable dock order.
//

import Foundation

/// Owns the rules for `manualOrder`, the persisted dock ordering a user creates
/// by dragging Pickle icons.
///
/// Two coordinate spaces meet here and the difference is the source of most
/// ordering bugs, so it stays in one place:
///
/// - **Underlying space** is `sessions`, newest first.
/// - **Visible space** is `sessions.reversed()`, so the newest Pickle sits at
///   the visually-end slot. Index `0` in `manualOrder` is the newest entry.
///
/// `manualOrder` may also interleave archived ids. Keeping their slots is what
/// lets unarchive restore a Pickle to where the user last put it, which is why
/// a drop index cannot be used as a direct `manualOrder` index.
enum PickyDockManualOrderPolicy {
    /// Drops ids that left the active+archived universe and files unknown
    /// active ids into the newest slot, preserving their newest-first batch
    /// order.
    static func reconciled(
        manualOrder: [String],
        activeIDsNewestFirst: [String],
        archivedIDs: Set<String>
    ) -> [String] {
        var order = manualOrder
        let universe = Set(activeIDsNewestFirst).union(archivedIDs)
        order.removeAll { !universe.contains($0) }

        let knownIDs = Set(order)
        let missingActiveIDs = activeIDsNewestFirst.filter { !knownIDs.contains($0) }
        guard !missingActiveIDs.isEmpty else { return order }
        order.insert(contentsOf: missingActiveIDs, at: 0)
        return order
    }

    /// Moves `sessionID` so that it lands at `underlyingTarget` counted over
    /// active ids only. Returns `nil` when the id is absent, which leaves the
    /// caller's persisted order untouched.
    ///
    /// The insert index is found by counting active ids rather than by direct
    /// indexing, because interleaved archived ids would otherwise shift the
    /// drop by the number of archived slots it crossed.
    static func moved(
        manualOrder: [String],
        sessionID: String,
        activeIDs: Set<String>,
        underlyingTarget: Int
    ) -> [String]? {
        var order = manualOrder
        guard let currentIndex = order.firstIndex(of: sessionID) else { return nil }
        order.remove(at: currentIndex)

        let otherActiveIDs = activeIDs.subtracting([sessionID])
        var activeSeen = 0
        var insertIndex = order.count
        for (index, id) in order.enumerated() {
            if activeSeen == underlyingTarget {
                insertIndex = index
                break
            }
            if otherActiveIDs.contains(id) { activeSeen += 1 }
        }
        order.insert(sessionID, at: insertIndex)
        return order
    }

    /// Restores an unarchived session to the newest slot while keeping every
    /// other slot intact.
    static func promotedToNewest(manualOrder: [String], sessionID: String) -> [String] {
        var order = manualOrder
        order.removeAll { $0 == sessionID }
        order.insert(sessionID, at: 0)
        return order
    }

    /// Visible space is `sessions.reversed()`, so both translations are the
    /// same reflection.
    static func underlyingIndex(visibleIndex: Int, count: Int) -> Int {
        (count - 1) - visibleIndex
    }

    /// Clamps a raw drop index into visible space before translation.
    static func clampedVisibleIndex(_ rawIndex: Int, count: Int) -> Int {
        max(0, min(count - 1, rawIndex))
    }
}
