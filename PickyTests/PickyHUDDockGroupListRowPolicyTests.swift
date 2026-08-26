//
//  PickyHUDDockGroupListRowPolicyTests.swift
//  PickyTests
//
//  Contract for a group-list row's accessibility projection and for the
//  action-enablement policy the row shares with the rail tile. The sharing is
//  the point: a row menu that can stop a finished Pickle, or a rail tile that
//  cannot stop a running one, is the drift these tests exist to catch.
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListRowPolicyTests {
    private func presentation(
        title: String = "Refactor the dock rail",
        statusText: String = "Running",
        cwdLeaf: String? = "picky",
        relativeTime: String = "2 minutes ago",
        status: PickySessionStatus = .running,
        canRequestCompaction: Bool = false
    ) -> PickyHUDDockGroupListRowPresentation {
        PickyHUDDockGroupListRowPresentation.resolve(
            title: title,
            statusText: statusText,
            cwdLeaf: cwdLeaf,
            relativeTime: relativeTime,
            status: status,
            canRequestCompaction: canRequestCompaction
        )
    }

    // MARK: - Accessibility projection

    @Test func accessibilityLabelKeepsTheFullTitleEvenThoughTheRowTruncatesIt() {
        let longTitle = String(repeating: "Investigate the flaky dock drag test ", count: 4)
        let resolved = presentation(title: longTitle)

        #expect(resolved.accessibilityLabel == longTitle)
    }

    @Test func accessibilityValueReadsStatusThenLocationThenTime() {
        let resolved = presentation()

        #expect(resolved.accessibilityValue == "Running, picky, 2 minutes ago")
    }

    @Test func accessibilityValueOmitsMissingOrBlankLocation() {
        #expect(presentation(cwdLeaf: nil).accessibilityValue == "Running, 2 minutes ago")
        #expect(presentation(cwdLeaf: "   ").accessibilityValue == "Running, 2 minutes ago")
    }

    // MARK: - Shared action enablement

    @Test func stopIsOfferedForLivePicklesAndWithheldForTerminalOnes() {
        let live: [PickySessionStatus] = [.queued, .running, .waiting_for_input, .blocked]
        let terminal: [PickySessionStatus] = [.completed, .failed, .cancelled]

        for status in live {
            #expect(presentation(status: status).actionAvailability.canStop, "\(status) should be stoppable")
        }
        for status in terminal {
            #expect(presentation(status: status).actionAvailability.canStop == false, "\(status) should not be stoppable")
        }
    }

    @Test func compactionFollowsTheSessionCapabilityRatherThanTheStatus() {
        #expect(presentation(canRequestCompaction: true).actionAvailability.canCompact)
        #expect(presentation(canRequestCompaction: false).actionAvailability.canCompact == false)
    }

    /// The rail tile builds its menu from the same policy call. If either
    /// surface ever grows its own rules, this equivalence breaks first.
    @Test func rowAndRailTileResolveIdenticalAvailabilityForEveryStatus() {
        let statuses: [PickySessionStatus] = [
            .queued, .running, .waiting_for_input, .blocked, .completed, .failed, .cancelled,
        ]

        for status in statuses {
            for canRequestCompaction in [true, false] {
                let railTile = PickyHUDDockSessionActionAvailability.resolve(
                    status: status,
                    canRequestCompaction: canRequestCompaction
                )
                let row = presentation(status: status, canRequestCompaction: canRequestCompaction)
                    .actionAvailability

                #expect(row == railTile, "drift for \(status), compaction=\(canRequestCompaction)")
            }
        }
    }

    @Test func terminalStatusMatchesTheStatusPresentationSourceOfTruth() {
        let statuses: [PickySessionStatus] = [
            .queued, .running, .waiting_for_input, .blocked, .completed, .failed, .cancelled,
        ]

        for status in statuses {
            let availability = PickyHUDDockSessionActionAvailability.resolve(
                status: status,
                canRequestCompaction: false
            )
            #expect(availability.canStop == !status.isTerminal)
        }
    }
}

struct PickyHUDDockGroupListRowProjectionTests {
    private struct StubSession: Equatable {
        let id: String
    }

    private struct StubRow: Equatable {
        let id: String
        let updatedAt: Date
    }

    private func project(
        memberSessionIDs: [String],
        activeSessionIDs: [String],
        updatedAt: [String: Date] = [:]
    ) -> [StubRow] {
        let sessions = Dictionary(uniqueKeysWithValues: activeSessionIDs.map { ($0, StubSession(id: $0)) })
        return PickyHUDDockGroupListRowProjection.rows(
            memberSessionIDs: memberSessionIDs,
            activeSessionsByID: sessions,
            updatedAt: { updatedAt[$0] },
            makeRow: { session, date in StubRow(id: session.id, updatedAt: date) }
        )
    }

    @Test func rowsFollowStoredMembershipOrder() {
        let rows = project(memberSessionIDs: ["c", "a", "b"], activeSessionIDs: ["a", "b", "c"])

        #expect(rows.map(\.id) == ["c", "a", "b"])
    }

    /// Archived members stay in `memberSessionIDs` but stop being active
    /// sessions, so they must never render a row.
    @Test func archivedMembersAreSkippedWhileMembershipIsPreserved() {
        let memberSessionIDs = ["archived", "live", "also-archived"]
        let rows = project(memberSessionIDs: memberSessionIDs, activeSessionIDs: ["live"])

        #expect(rows.map(\.id) == ["live"])
        #expect(memberSessionIDs.count == 3)
    }

    @Test func archivingTheLastVisibleMemberYieldsTheEmptyState() {
        let before = project(memberSessionIDs: ["only"], activeSessionIDs: ["only"])
        let after = project(memberSessionIDs: ["only"], activeSessionIDs: [])

        #expect(before.count == 1)
        #expect(after.isEmpty)
    }

    @Test func missingTimestampsFallBackToDistantPastRatherThanDroppingTheRow() {
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = project(
            memberSessionIDs: ["stamped", "unstamped"],
            activeSessionIDs: ["stamped", "unstamped"],
            updatedAt: ["stamped": stamped]
        )

        #expect(rows.map(\.id) == ["stamped", "unstamped"])
        #expect(rows[0].updatedAt == stamped)
        #expect(rows[1].updatedAt == .distantPast)
    }
}
