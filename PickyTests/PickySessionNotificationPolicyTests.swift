//
//  PickySessionNotificationPolicyTests.swift
//  PickyTests
//
//  Characterization coverage for session notification eligibility, dedupe
//  keys, bodies, and terminal-key reset policy.
//

import XCTest
@testable import Picky

final class PickySessionNotificationPolicyTests: XCTestCase {
    func testCompletedNotificationUsesSummaryAndHonorsPreference() {
        let input = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Fallback title",
            status: .completed,
            lastSummary: "Done summary"
        )

        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(
                for: input,
                preferences: PickyNotificationPreferences(
                    notifyOnCompleted: true,
                    notifyOnFailed: true,
                    notifyOnWaitingForInput: true
                )
            ),
            PickySessionNotificationPolicy.Notification(
                key: "session-1:completed",
                title: L10n.t("notif.session.completed.title"),
                body: "Done summary"
            )
        )

        XCTAssertNil(PickySessionNotificationPolicy.notification(for: input, preferences: .defaults))
    }

    func testCompletedNotificationFallsBackToTitleAndSkipsPinnedSessions() {
        let preferences = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        let unpinned = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Pickle title",
            status: .completed,
            lastSummary: "",
            pinned: false
        )
        let pinned = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Pickle title",
            status: .completed,
            lastSummary: "Pinned summary",
            pinned: true
        )

        XCTAssertEqual(PickySessionNotificationPolicy.notification(for: unpinned, preferences: preferences)?.body, "Pickle title")
        XCTAssertNil(PickySessionNotificationPolicy.notification(for: pinned, preferences: preferences))
    }

    func testFailedNotificationUsesFallbackBodyAndHonorsPreference() {
        let input = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Failure title",
            status: .failed,
            lastSummary: ""
        )
        let enabled = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        let disabled = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: false,
            notifyOnWaitingForInput: true
        )

        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(for: input, preferences: enabled),
            PickySessionNotificationPolicy.Notification(
                key: "session-1:failed",
                title: L10n.t("notif.session.failed.title"),
                body: L10n.t("notif.session.failed.fallbackBody")
            )
        )
        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(
                for: PickySessionNotificationPolicy.Input(
                    sessionID: "session-1",
                    title: "Failure title",
                    status: .failed,
                    lastSummary: "Error detail"
                ),
                preferences: enabled
            )?.body,
            "Error detail"
        )
        XCTAssertNil(PickySessionNotificationPolicy.notification(for: input, preferences: disabled))
    }

    func testWaitingNotificationRequiresPendingRequestAndKeysByRequestID() {
        let preferences = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        let pending = PickySessionNotificationPolicy.Input.PendingRequest(
            id: "ui-form",
            title: "Form title",
            prompt: "Pick one"
        )
        let input = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Session title",
            status: .waiting_for_input,
            pendingRequest: pending
        )
        let missingRequest = PickySessionNotificationPolicy.Input(
            sessionID: "session-1",
            title: "Session title",
            status: .waiting_for_input
        )

        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(for: input, preferences: preferences),
            PickySessionNotificationPolicy.Notification(
                key: "session-1:waiting:ui-form",
                title: L10n.t("notif.session.waiting.title"),
                body: "Pick one"
            )
        )
        XCTAssertNil(PickySessionNotificationPolicy.notification(for: missingRequest, preferences: preferences))
    }

    func testWaitingNotificationFallsBackFromPromptToTitleToSessionTitle() {
        let preferences = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        let requestWithTitle = PickySessionNotificationPolicy.Input.PendingRequest(
            id: "ui-title",
            title: "Request title",
            prompt: nil
        )
        let requestWithoutText = PickySessionNotificationPolicy.Input.PendingRequest(
            id: "ui-session",
            title: nil,
            prompt: nil
        )

        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(
                for: PickySessionNotificationPolicy.Input(
                    sessionID: "session-1",
                    title: "Session title",
                    status: .waiting_for_input,
                    pendingRequest: requestWithTitle
                ),
                preferences: preferences
            )?.body,
            "Request title"
        )
        XCTAssertEqual(
            PickySessionNotificationPolicy.notification(
                for: PickySessionNotificationPolicy.Input(
                    sessionID: "session-1",
                    title: "Session title",
                    status: .waiting_for_input,
                    pendingRequest: requestWithoutText
                ),
                preferences: preferences
            )?.body,
            "Session title"
        )
    }

    func testNotificationCopyCanUseInjectedLocalizer() {
        let preferences = PickyNotificationPreferences(
            notifyOnCompleted: true,
            notifyOnFailed: true,
            notifyOnWaitingForInput: true
        )
        let notification = PickySessionNotificationPolicy.notification(
            for: PickySessionNotificationPolicy.Input(
                sessionID: "session-1",
                title: "Session title",
                status: .failed,
                lastSummary: ""
            ),
            preferences: preferences,
            localizer: { "localized:\($0)" }
        )

        XCTAssertEqual(notification?.title, "localized:notif.session.failed.title")
        XCTAssertEqual(notification?.body, "localized:notif.session.failed.fallbackBody")
    }

    func testRunningQueuedBlockedAndCancelledHaveNoNotification() {
        for status in [PickySessionStatus.running, .queued, .blocked, .cancelled] {
            let input = PickySessionNotificationPolicy.Input(
                sessionID: "session-1",
                title: "Title",
                status: status
            )

            XCTAssertNil(PickySessionNotificationPolicy.notification(for: input, preferences: .defaults))
        }
    }

    func testTerminalDedupKeysResetOnlyForNonTerminalStatuses() {
        for status in [PickySessionStatus.queued, .running, .waiting_for_input, .blocked] {
            XCTAssertEqual(
                PickySessionNotificationPolicy.terminalDedupKeysToReset(sessionID: "session-1", status: status),
                ["session-1:completed", "session-1:failed"]
            )
        }
        for status in [PickySessionStatus.completed, .failed, .cancelled] {
            XCTAssertEqual(
                PickySessionNotificationPolicy.terminalDedupKeysToReset(sessionID: "session-1", status: status),
                []
            )
        }
    }
}
