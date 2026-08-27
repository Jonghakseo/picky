//
//  PickyHUDArchiveUndoToastRemovalPolicy.swift
//  Picky
//
//  Prevents a stale undo control from reviving an authoritatively removed
//  session.
//

import Foundation

enum PickyHUDArchiveUndoToastRemovalPolicy {
    static func shouldInvalidate(toastSessionID: String, removedSessionIDs: Set<String>) -> Bool {
        removedSessionIDs.contains(toastSessionID)
    }
}
