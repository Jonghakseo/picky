import Testing
@testable import Picky

@Suite("HUD open performance tracker")
struct PickyHUDOpenPerformanceTrackerTests {
    @Test func completedDockOpenEmitsOneScalarMeasurement() throws {
        var now: TimeInterval = 100
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "private-session-id", messageCount: 37, wasUnread: true)
        now = 100.125
        tracker.markCardMounted(sessionID: "private-session-id")
        now = 100.180
        tracker.markPanelReady(sessionID: "private-session-id", panelResizeMilliseconds: 12)

        let measurement = try #require(measurements.first)
        #expect(measurements.count == 1)
        #expect(measurement.totalMilliseconds == 180)
        #expect(measurement.mountMilliseconds == 125)
        #expect(measurement.postMountMilliseconds == 55)
        #expect(measurement.panelResizeMilliseconds == 12)
        #expect(measurement.messageCount == 37)
        #expect(measurement.wasUnread)
        #expect(!measurement.logMessage.contains("private-session-id"))
        #expect(measurement.logMessage.contains("event=hudDockOpen"))
    }

    @Test func duplicatePanelReadyDoesNotEmitTwice() {
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { 10 },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "session-a", messageCount: 1, wasUnread: false)
        tracker.markCardMounted(sessionID: "session-a")
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 1)
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 2)

        #expect(measurements.count == 1)
    }

    @Test func staleCallbacksDoNotCompleteCurrentAttempt() {
        var now: TimeInterval = 10
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)
        now = 10.050
        tracker.markCardMounted(sessionID: "session-b")
        tracker.markPanelReady(sessionID: "session-b", panelResizeMilliseconds: 4)
        #expect(measurements.isEmpty)

        tracker.markCardMounted(sessionID: "session-a")
        now = 10.100
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 5)

        #expect(measurements.count == 1)
    }

    @Test func panelReadyBeforeMountWaitsForBothSignals() {
        var now: TimeInterval = 10
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)
        now = 10.100
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 5)
        #expect(measurements.isEmpty)

        now = 10.120
        tracker.markCardMounted(sessionID: "session-a")

        #expect(measurements.count == 1)
        #expect(measurements.first?.mountMilliseconds == 120)
        #expect(measurements.first?.postMountMilliseconds == 0)
        #expect(measurements.first?.totalMilliseconds == 120)
    }

    @Test func cancelledAttemptIgnoresLatePanelResize() {
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { 10 },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "session-a", messageCount: 3, wasUnread: false)
        tracker.cancel(sessionID: "session-a")
        tracker.markCardMounted(sessionID: "session-a")
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 4)

        #expect(measurements.isEmpty)
    }

    @Test func newerDockClickReplacesUnfinishedAttempt() {
        var now: TimeInterval = 10
        var measurements: [PickyHUDOpenPerformanceMeasurement] = []
        let tracker = PickyHUDOpenPerformanceTracker(
            clock: { now },
            measurementSink: { measurements.append($0) }
        )

        tracker.start(sessionID: "session-a", messageCount: 80, wasUnread: true)
        now = 11
        tracker.start(sessionID: "session-b", messageCount: 4, wasUnread: false)
        tracker.markCardMounted(sessionID: "session-a")
        tracker.markPanelReady(sessionID: "session-a", panelResizeMilliseconds: 9)
        #expect(measurements.isEmpty)

        now = 11.020
        tracker.markCardMounted(sessionID: "session-b")
        now = 11.040
        tracker.markPanelReady(sessionID: "session-b", panelResizeMilliseconds: 2)

        #expect(measurements.count == 1)
        #expect(measurements.first?.messageCount == 4)
        #expect(measurements.first?.totalMilliseconds == 40)
    }
}
