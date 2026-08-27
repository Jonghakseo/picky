//
//  PickyHUDDockGroupListRowPolicy.swift
//  Picky
//
//  Testable presentation projection shared by a group-list row's visible and
//  accessibility metadata.
//

import Foundation

/// Resolves panel data from the snapshot emitted by the dock publisher. The
/// publisher fires before its stored property changes, so callers must not
/// re-read the store while handling the event.
enum PickyHUDDockGroupListSnapshotPolicy {
    static func group(groupID: String, in snapshot: PickyHUDDockSnapshot) -> PickyDockGroup? {
        snapshot.dockLayout.group(withID: groupID)
    }
}

/// Projects a group's stored membership into the rows the panel renders.
///
/// Membership outlives visibility: archived members stay in `memberSessionIDs`
/// but are no longer active sessions, so they must not produce rows. Archiving
/// the last visible member therefore yields an empty row list, which the
/// overlay boundary reconciles by tearing down the child panel.
enum PickyHUDDockGroupListRowProjection {
    static func rows<Session, Row>(
        memberSessionIDs: [String],
        activeSessionsByID: [String: Session],
        updatedAt: (String) -> Date?,
        makeRow: (Session, Date) -> Row
    ) -> [Row] {
        memberSessionIDs.compactMap { sessionID in
            guard let session = activeSessionsByID[sessionID] else { return nil }
            return makeRow(session, updatedAt(sessionID) ?? .distantPast)
        }
    }
}

enum PickyHUDGroupListRowAXAction: Equatable {
    case open
    case ungroup
    case archive
    case stop
}

enum PickyHUDDockGroupListRowTrailingContent: Equatable {
    case shortcut(Int)
    case quickActions
    case empty

    static func resolve(
        isHovered: Bool,
        isHighlighted: Bool,
        shortcutNumber: Int?
    ) -> Self {
        if isHovered || isHighlighted {
            return .quickActions
        }
        if let shortcutNumber {
            return .shortcut(shortcutNumber)
        }
        return .empty
    }
}

struct PickyHUDDockGroupListRowPresentation: Equatable {
    let accessibilityLabel: String
    let accessibilityValue: String
    let subtitle: String
    let actionAvailability: PickyHUDDockSessionActionAvailability
    let accessibilityActions: [PickyHUDGroupListRowAXAction]

    static func resolve(
        title: String,
        statusText: String,
        cwdLeaf: String?,
        relativeTime: String,
        status: PickySessionStatus,
        canRequestCompaction: Bool
    ) -> Self {
        let normalizedCwdLeaf = cwdLeaf?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = (normalizedCwdLeaf?.isEmpty == false) ? normalizedCwdLeaf : nil
        let subtitle = [relativeTime, location]
            .compactMap { $0 }
            .joined(separator: " · ")
        let metadata = [relativeTime, location]
            .compactMap { $0 }
            .joined(separator: ", ")
        let value = [statusText, metadata]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let actionAvailability = PickyHUDDockSessionActionAvailability.resolve(
            status: status,
            canRequestCompaction: canRequestCompaction
        )
        return Self(
            accessibilityLabel: title,
            accessibilityValue: value,
            subtitle: subtitle,
            actionAvailability: actionAvailability,
            accessibilityActions: actionAvailability.canStop
                ? [.open, .ungroup, .archive, .stop]
                : [.open, .ungroup, .archive]
        )
    }
}
