//
//  PickyHUDDockGroupDropCandidates.swift
//  Picky
//

import CoreGraphics

/// Builds group candidates from the rail's actual frozen slot projection.
enum PickyHUDDockGroupDropCandidateBuilder {
    static func emptyCandidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        topEntryCenters: [String: CGFloat]
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            topEntryCenters: topEntryCenters,
            wantsVisibleMembers: false
        )
    }

    static func nonEmptyCandidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        topEntryCenters: [String: CGFloat]
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            topEntryCenters: topEntryCenters,
            wantsVisibleMembers: true
        )
    }

    private static func candidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        topEntryCenters: [String: CGFloat],
        wantsVisibleMembers: Bool
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        slots.compactMap { slot in
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID),
                  group.memberSessionIDs.contains(where: activeSessionIDs.contains) == wantsVisibleMembers,
                  let center = topEntryCenters["group:\(groupID)"]
            else { return nil }
            return .init(
                groupID: groupID,
                memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: 0,
                    memberSessionIDs: group.memberSessionIDs,
                    activeSessionIDs: activeSessionIDs
                ),
                center: center
            )
        }
    }
}
