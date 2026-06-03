//
//  PickyHUDDockGroupCollapsePolicy.swift
//  Picky
//
//  Pure per-display collapse transition policy for HUD dock groups.
//

struct PickyHUDDockGroupCollapsePolicy {
    struct ToggleResult: Equatable {
        var overrides: [String: Bool]
        var willCollapse: Bool
        var sessionIDToClose: String?
    }

    struct ExpandResult: Equatable {
        var overrides: [String: Bool]
        var didExpand: Bool
    }

    static func toggleResult(
        groupID: String,
        groups: [PickyDockGroup],
        overrides: [String: Bool],
        openedSessionID: String?
    ) -> ToggleResult {
        let group = groups.first { $0.id == groupID }
        let current = isCollapsed(groupID: groupID, groups: groups, overrides: overrides)
        let willCollapse = !current
        var nextOverrides = overrides
        nextOverrides[groupID] = willCollapse

        let sessionIDToClose: String?
        if willCollapse,
           let openedSessionID,
           group?.memberSessionIDs.contains(openedSessionID) == true {
            sessionIDToClose = openedSessionID
        } else {
            sessionIDToClose = nil
        }

        return ToggleResult(
            overrides: nextOverrides,
            willCollapse: willCollapse,
            sessionIDToClose: sessionIDToClose
        )
    }

    static func expandResultForOpening(
        sessionID: String,
        groups: [PickyDockGroup],
        overrides: [String: Bool]
    ) -> ExpandResult {
        guard let group = groups.first(where: { $0.memberSessionIDs.contains(sessionID) }) else {
            return ExpandResult(overrides: overrides, didExpand: false)
        }
        guard isCollapsed(groupID: group.id, groups: groups, overrides: overrides) else {
            return ExpandResult(overrides: overrides, didExpand: false)
        }

        var nextOverrides = overrides
        nextOverrides[group.id] = false
        return ExpandResult(overrides: nextOverrides, didExpand: true)
    }

    static func isCollapsed(
        groupID: String,
        groups: [PickyDockGroup],
        overrides: [String: Bool]
    ) -> Bool {
        overrides[groupID] ?? groups.first { $0.id == groupID }?.isCollapsed ?? false
    }
}
