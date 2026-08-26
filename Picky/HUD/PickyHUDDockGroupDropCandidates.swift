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
        groupDropFrames: [String: CGRect],
        orientation: PickyHUDDockOrientation
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            orientation: orientation,
            wantsVisibleMembers: false
        )
    }

    static func nonEmptyCandidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        groupDropFrames: [String: CGRect],
        orientation: PickyHUDDockOrientation
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            orientation: orientation,
            wantsVisibleMembers: true
        )
    }

    private static func candidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        groupDropFrames: [String: CGRect],
        orientation: PickyHUDDockOrientation,
        wantsVisibleMembers: Bool
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        slots.compactMap { slot in
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID),
                  group.memberSessionIDs.contains(where: activeSessionIDs.contains) == wantsVisibleMembers,
                  let frame = groupDropFrames[groupID]
            else { return nil }
            let center: CGFloat
            let halfExtent: CGFloat
            switch orientation {
            case .horizontal:
                center = frame.midX
                halfExtent = frame.width * 0.5
            case .vertical:
                center = frame.midY
                halfExtent = frame.height * 0.5
            }
            return .init(
                groupID: groupID,
                memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: 0,
                    memberSessionIDs: group.memberSessionIDs,
                    activeSessionIDs: activeSessionIDs
                ),
                center: center,
                halfExtent: halfExtent
            )
        }
    }
}
