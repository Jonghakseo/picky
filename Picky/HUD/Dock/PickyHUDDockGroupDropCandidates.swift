//
//  PickyHUDDockGroupDropCandidates.swift
//  Picky
//

import CoreGraphics

/// Builds group-header drop candidates from the rail's frozen slot projection.
enum PickyHUDDockGroupDropCandidateBuilder {
    static func emptyCandidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        groupDropFrames: [String: CGRect],
        topEntryExtents: [String: PickyDockAxisExtent],
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            topEntryExtents: topEntryExtents,
            orientation: orientation,
            metrics: metrics,
            fontScale: fontScale,
            wantsVisibleMembers: false
        )
    }

    static func nonEmptyCandidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        groupDropFrames: [String: CGRect],
        topEntryExtents: [String: PickyDockAxisExtent],
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            topEntryExtents: topEntryExtents,
            orientation: orientation,
            metrics: metrics,
            fontScale: fontScale,
            wantsVisibleMembers: true
        )
    }

    private static func candidates(
        slots: [PickyDockSlot],
        layout: PickyDockLayout,
        activeSessionIDs: Set<String>,
        groupDropFrames: [String: CGRect],
        topEntryExtents: [String: PickyDockAxisExtent],
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        wantsVisibleMembers: Bool
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        slots.compactMap { slot in
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID),
                  group.memberSessionIDs.contains(where: activeSessionIDs.contains) == wantsVisibleMembers,
                  let axisGeometry = axisGeometry(
                    measuredFrame: groupDropFrames[groupID],
                    topEntryLeadingEdge: topEntryExtents["group:\(groupID)"]?.lower,
                    orientation: orientation,
                    metrics: metrics,
                    fontScale: fontScale
                  )
            else { return nil }
            return .init(
                groupID: groupID,
                memberIndex: PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: 0,
                    memberSessionIDs: group.memberSessionIDs,
                    activeSessionIDs: activeSessionIDs
                ),
                center: axisGeometry.center,
                halfExtent: axisGeometry.halfExtent
            )
        }
    }

    private static func axisGeometry(
        measuredFrame: CGRect?,
        topEntryLeadingEdge: CGFloat?,
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> (center: CGFloat, halfExtent: CGFloat)? {
        if let measuredFrame {
            switch orientation {
            case .horizontal where measuredFrame.width > 0 && measuredFrame.midX.isFinite:
                return (measuredFrame.midX, measuredFrame.width * 0.5)
            case .vertical where measuredFrame.height > 0 && measuredFrame.midY.isFinite:
                return (measuredFrame.midY, measuredFrame.height * 0.5)
            default:
                break
            }
        }

        // Preference publication is asynchronous. A drag can begin before the
        // header frame lands, so derive the header's span from the leading edge
        // of its group block instead of dropping the group from the list.
        guard let topEntryLeadingEdge else { return nil }
        switch orientation {
        case .horizontal:
            let half = metrics.chipWidth * 0.5
            return (topEntryLeadingEdge + half, half)
        case .vertical:
            let half = metrics.groupHeaderHeight(fontScale: fontScale) * 0.5
            return (topEntryLeadingEdge + half, half)
        }
    }
}
