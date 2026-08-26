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
        topEntryCenters: [String: CGFloat],
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            topEntryCenters: topEntryCenters,
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
        topEntryCenters: [String: CGFloat],
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> [PickyDockDropResolver.EmptyGroupCandidate] {
        candidates(
            slots: slots,
            layout: layout,
            activeSessionIDs: activeSessionIDs,
            groupDropFrames: groupDropFrames,
            topEntryCenters: topEntryCenters,
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
        topEntryCenters: [String: CGFloat],
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
                    topEntryCenter: topEntryCenters["group:\(groupID)"],
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
        topEntryCenter: CGFloat?,
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
        // badge frame lands, so recover the same visible badge range from the
        // already-established top-entry center instead of dropping the folder
        // from the candidate list. The title is rendered above the badge.
        guard let topEntryCenter else { return nil }
        switch orientation {
        case .horizontal:
            return (topEntryCenter, metrics.sessionTileWidth * 0.5)
        case .vertical:
            let titleAndSpacing = PickyHUDDockGroupHeaderPresentation.labelHeight(
                metrics: metrics,
                fontScale: fontScale
            ) + metrics.groupHeaderContentSpacing
            return (
                topEntryCenter + titleAndSpacing * 0.5,
                metrics.sessionTileHeight * 0.5
            )
        }
    }
}
