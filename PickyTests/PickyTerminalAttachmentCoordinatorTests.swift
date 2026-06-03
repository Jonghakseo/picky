//
//  PickyTerminalAttachmentCoordinatorTests.swift
//  PickyTests
//
//  Characterization coverage for the inline/shell terminal attachment stack:
//  latest visible attachment is active, releasing/removing the active one
//  promotes the most recent still-eligible attachment.
//

import XCTest
@testable import Picky

final class PickyTerminalAttachmentCoordinatorTests: XCTestCase {
    func testActivateIgnoresIneligibleSessions() {
        var coordinator = PickyTerminalAttachmentCoordinator()

        coordinator.activate(sessionID: "missing", attachmentID: "screen-a", eligibleSessionIDs: ["pickle-1"])

        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertNil(coordinator.activeAttachmentID)
        XCTAssertFalse(coordinator.isActive(sessionID: "missing", attachmentID: "screen-a"))
    }

    func testLatestActivatedAttachmentBecomesActive() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let eligible: Set<String> = ["pickle-1", "pickle-2"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: eligible)

        XCTAssertFalse(coordinator.isActive(sessionID: "pickle-1", attachmentID: "screen-a"))
        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))
        XCTAssertEqual(coordinator.activeSessionID, "pickle-2")
        XCTAssertEqual(coordinator.activeAttachmentID, "screen-b")
    }

    func testReactivatingExistingAttachmentMovesItToTopWithoutDuplicates() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let eligible: Set<String> = ["pickle-1", "pickle-2"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)

        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-1", attachmentID: "screen-a"))
        coordinator.release(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))

        coordinator.release(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))
    }

    func testReleasingInactiveAttachmentKeepsCurrentActive() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let eligible: Set<String> = ["pickle-1", "pickle-2"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: eligible)
        coordinator.release(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)

        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))
    }

    func testReleasingActiveAttachmentPromotesMostRecentEligibleAttachment() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let initialEligible: Set<String> = ["pickle-1", "pickle-2", "pickle-3"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: initialEligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: initialEligible)
        coordinator.activate(sessionID: "pickle-3", attachmentID: "screen-c", eligibleSessionIDs: initialEligible)
        coordinator.release(sessionID: "pickle-3", attachmentID: "screen-c", eligibleSessionIDs: ["pickle-1"])

        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-1", attachmentID: "screen-a"))
        XCTAssertFalse(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))
    }

    func testRemovingActiveSessionPromotesPreviousEligibleAttachment() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let eligible: Set<String> = ["pickle-1", "pickle-2"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: eligible)
        coordinator.removeSession(sessionID: "pickle-2", eligibleSessionIDs: ["pickle-1"])

        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-1", attachmentID: "screen-a"))
    }

    func testRemovingInactiveSessionKeepsCurrentActive() {
        var coordinator = PickyTerminalAttachmentCoordinator()
        let eligible: Set<String> = ["pickle-1", "pickle-2"]

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: eligible)
        coordinator.activate(sessionID: "pickle-2", attachmentID: "screen-b", eligibleSessionIDs: eligible)
        coordinator.removeSession(sessionID: "pickle-1", eligibleSessionIDs: eligible)

        XCTAssertTrue(coordinator.isActive(sessionID: "pickle-2", attachmentID: "screen-b"))
    }

    func testReleasingLastVisibleAttachmentClearsActiveState() {
        var coordinator = PickyTerminalAttachmentCoordinator()

        coordinator.activate(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: ["pickle-1"])
        coordinator.release(sessionID: "pickle-1", attachmentID: "screen-a", eligibleSessionIDs: ["pickle-1"])

        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertNil(coordinator.activeAttachmentID)
        XCTAssertFalse(coordinator.isActive(sessionID: "pickle-1", attachmentID: "screen-a"))
    }
}
