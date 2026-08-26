//
//  PickyDockGroupMemberIndexPolicy.swift
//  Picky
//
//  Translates between the group rows a user can see and the stored member
//  array. A group keeps archived members in `memberSessionIDs` even though
//  they are not rendered, so a visible drop position is not a stored index.
//

enum PickyDockGroupMemberIndexPolicy {
    /// Members the group list renders, in stored order.
    static func visibleMemberIDs(
        memberSessionIDs: [String],
        activeSessionIDs: Set<String>
    ) -> [String] {
        memberSessionIDs.filter { activeSessionIDs.contains($0) }
    }

    /// Stored index that lands a Pickle at `visibleIndex` among the rendered
    /// rows. `visibleIndex == visibleCount` appends after the last member,
    /// including any trailing archived ones, so an append never jumps a
    /// hidden member.
    static func fullMemberIndex(
        forVisibleIndex visibleIndex: Int,
        memberSessionIDs: [String],
        activeSessionIDs: Set<String>
    ) -> Int {
        let visible = visibleMemberIDs(
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: activeSessionIDs
        )
        let clamped = min(max(visibleIndex, 0), visible.count)
        guard clamped < visible.count else { return memberSessionIDs.count }
        let targetID = visible[clamped]
        return memberSessionIDs.firstIndex(of: targetID) ?? memberSessionIDs.count
    }

    /// Visible row position of a stored member, or nil when it is not rendered.
    static func visibleIndex(
        forMemberID memberID: String,
        memberSessionIDs: [String],
        activeSessionIDs: Set<String>
    ) -> Int? {
        visibleMemberIDs(
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: activeSessionIDs
        )
        .firstIndex(of: memberID)
    }
}
