//
//  PickyHUDDockGroupListRowPolicy.swift
//  Picky
//
//  Testable presentation projection shared by a group-list row's visible and
//  accessibility metadata.
//

import Foundation

/// Projects a group's stored membership into the rows the panel renders.
///
/// Membership outlives visibility: archived members stay in `memberSessionIDs`
/// but are no longer active sessions, so they must not produce rows. Archiving
/// the last visible member therefore yields an empty row list, which is what
/// drives the panel's empty state instead of a stale or zero-height panel.
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

struct PickyHUDDockGroupListRowPresentation: Equatable {
    let accessibilityLabel: String
    let accessibilityValue: String
    let actionAvailability: PickyHUDDockSessionActionAvailability

    static func resolve(
        title: String,
        statusText: String,
        cwdLeaf: String?,
        relativeTime: String,
        status: PickySessionStatus,
        canRequestCompaction: Bool
    ) -> Self {
        let metadata = [cwdLeaf, relativeTime]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let value = [statusText, metadata]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return Self(
            accessibilityLabel: title,
            accessibilityValue: value,
            actionAvailability: PickyHUDDockSessionActionAvailability.resolve(
                status: status,
                canRequestCompaction: canRequestCompaction
            )
        )
    }
}
