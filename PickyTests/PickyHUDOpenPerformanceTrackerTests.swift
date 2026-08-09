import Testing
@testable import Picky

@Suite("HUD open performance tracker")
struct PickyHUDOpenPerformanceTrackerTests {
    @Test func completedDockOpenEmitsInteractiveAndPanelSettledMilestones() throws {
        var now: TimeInterval = 100
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        let token = tracker.start(sessionID: "private-session-id", messageCount: 37, wasUnread: true)
        now = 100.125
        tracker.markCardMounted(token: token)
        now = 100.410
        tracker.markInteractive(token: token)
        now = 100.580
        tracker.markPanelSettled(token: token, panelResizeMilliseconds: 12)

        let measurement = try #require(measurements.first)
        #expect(measurements.count == 1)
        #expect(measurement.cardMountedMilliseconds == 125)
        #expect(measurement.interactiveMilliseconds == 410)
        #expect(measurement.postMountInteractiveMilliseconds == 285)
        #expect(measurement.panelSettledMilliseconds == 580)
        #expect(measurement.panelSettleAfterInteractiveMilliseconds == 170)
        #expect(measurement.panelResizeMilliseconds == 12)
        #expect(measurement.messageCount == 37)
        #expect(measurement.wasUnread)
        #expect(!measurement.logMessage.contains("private-session-id"))
        #expect(measurement.logMessage.contains("event=hudDockOpen"))
        #expect(measurement.logMessage.contains("interactiveMs=410"))
        #expect(measurement.logMessage.contains("panelSettledMs=580"))
    }

    @Test func signalsCanArriveInAnyOrderButAllAreRequired() {
        var now: TimeInterval = 10
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        let token = tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)
        now = 10.100
        tracker.markPanelSettled(token: token, panelResizeMilliseconds: 5)
        now = 10.120
        tracker.markInteractive(token: token)
        #expect(measurements.isEmpty)

        now = 10.150
        tracker.markCardMounted(token: token)

        #expect(measurements.count == 1)
        #expect(measurements.first?.cardMountedMilliseconds == 150)
        #expect(measurements.first?.interactiveMilliseconds == 150)
        #expect(measurements.first?.postMountInteractiveMilliseconds == 0)
        #expect(measurements.first?.panelSettledMilliseconds == 100)
        #expect(measurements.first?.panelSettleAfterInteractiveMilliseconds == 0)
    }

    @Test func duplicateSignalsDoNotEmitTwice() {
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { 10 },
            measurementSink: { measurements.append($0) }
        )

        let token = tracker.start(sessionID: "session-a", messageCount: 1, wasUnread: false)
        tracker.markCardMounted(token: token)
        tracker.markInteractive(token: token)
        tracker.markPanelSettled(token: token, panelResizeMilliseconds: 1)
        tracker.markCardMounted(token: token)
        tracker.markInteractive(token: token)
        tracker.markPanelSettled(token: token, panelResizeMilliseconds: 2)

        #expect(measurements.count == 1)
    }

    @Test func staleTokenForSameSessionCannotCompleteNewAttempt() {
        var now: TimeInterval = 10
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        let staleToken = tracker.start(sessionID: "session-a", messageCount: 80, wasUnread: true)
        now = 11
        let currentToken = tracker.start(sessionID: "session-a", messageCount: 4, wasUnread: false)

        tracker.markCardMounted(token: staleToken)
        tracker.markInteractive(token: staleToken)
        tracker.markPanelSettled(token: staleToken, panelResizeMilliseconds: 9)
        #expect(measurements.isEmpty)

        now = 11.020
        tracker.markCardMounted(token: currentToken)
        now = 11.040
        tracker.markInteractive(token: currentToken)
        now = 11.060
        tracker.markPanelSettled(token: currentToken, panelResizeMilliseconds: 2)

        #expect(measurements.count == 1)
        #expect(measurements.first?.messageCount == 4)
        #expect(measurements.first?.interactiveMilliseconds == 40)
        #expect(measurements.first?.panelSettledMilliseconds == 60)
    }

    @Test func activeTokenIsExposedOnlyForMatchingSession() {
        let tracker = PickyHUDOpenPerformanceTracker(clock: { 10 }, measurementSink: { _ in })
        let token = tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)

        #expect(tracker.activeToken(sessionID: "session-a") == token)
        #expect(tracker.activeToken(sessionID: "session-b") == nil)
    }

    @Test func cancelledAttemptIgnoresLateCallbacks() {
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { 10 },
            measurementSink: { measurements.append($0) }
        )

        let token = tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)
        tracker.cancel(sessionID: "session-a")
        tracker.markCardMounted(token: token)
        tracker.markInteractive(token: token)
        tracker.markPanelSettled(token: token, panelResizeMilliseconds: 4)

        #expect(measurements.isEmpty)
    }
}
