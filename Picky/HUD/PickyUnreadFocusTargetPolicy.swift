import Foundation

enum PickyUnreadFocusTargetPolicy {
    static func targetSessionID(
        layout: PickyDockLayout,
        activeSessionIDs: [String],
        unreadSessionIDs: Set<String>,
        lastActualConversationCardOpenedID: String?
    ) -> String? {
        let orderedActiveIDs = PickyDockProjector.cycleSessionIDs(
            layout: layout,
            activeSessionIDs: activeSessionIDs
        )
        guard !orderedActiveIDs.isEmpty else { return nil }

        if let unread = orderedActiveIDs.first(where: unreadSessionIDs.contains) {
            return unread
        }
        if let lastActualConversationCardOpenedID,
           orderedActiveIDs.contains(lastActualConversationCardOpenedID) {
            return lastActualConversationCardOpenedID
        }
        return orderedActiveIDs.first
    }
}
