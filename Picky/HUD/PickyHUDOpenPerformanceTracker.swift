//
//  PickyHUDOpenPerformanceTracker.swift
//  Picky
//
//  Release-safe, privacy-preserving measurement for the user-visible path from
//  clicking a Pickle dock icon until its conversation card has mounted and the
//  outer HUD panel resize has completed. Detailed rendering probes remain in
//  PickyPerf for local Instruments captures; this tracker emits one bounded,
//  scalar-only OSLog line per completed dock-click open so feedback diagnostics
//  can reveal slow-device latency without session or conversation content.
//

import Foundation
import OSLog

struct PickyHUDOpenPerformanceMeasurement: Equatable {
    let totalMilliseconds: Int
    let mountMilliseconds: Int
    let postMountMilliseconds: Int
    let panelResizeMilliseconds: Int
    let messageCount: Int
    let wasUnread: Bool

    var logMessage: String {
        [
            "event=hudDockOpen",
            "outcome=panelReady",
            "totalMs=\(totalMilliseconds)",
            "mountMs=\(mountMilliseconds)",
            "postMountMs=\(postMountMilliseconds)",
            "panelResizeMs=\(panelResizeMilliseconds)",
            "messageCount=\(messageCount)",
            "wasUnread=\(wasUnread)"
        ].joined(separator: " ")
    }
}

final class PickyHUDOpenPerformanceTracker {
    typealias Clock = () -> TimeInterval
    typealias MeasurementSink = (PickyHUDOpenPerformanceMeasurement) -> Void

    private struct Attempt {
        let sessionID: String
        let startedAt: TimeInterval
        let messageCount: Int
        let wasUnread: Bool
        var mountedAt: TimeInterval?
        var panelReadyAt: TimeInterval?
        var panelResizeMilliseconds: Int?
    }

    private let clock: Clock
    private let measurementSink: MeasurementSink
    private var activeAttempt: Attempt?

    init(
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        measurementSink: @escaping MeasurementSink = { measurement in
            PickyLog.logger(.latency).notice("\(measurement.logMessage, privacy: .public)")
        }
    ) {
        self.clock = clock
        self.measurementSink = measurementSink
    }

    func start(sessionID: String, messageCount: Int, wasUnread: Bool) {
        activeAttempt = Attempt(
            sessionID: sessionID,
            startedAt: clock(),
            messageCount: max(0, messageCount),
            wasUnread: wasUnread,
            mountedAt: nil,
            panelReadyAt: nil,
            panelResizeMilliseconds: nil
        )
    }

    func isTracking(sessionID: String) -> Bool {
        activeAttempt?.sessionID == sessionID
    }

    func markCardMounted(sessionID: String) {
        guard var attempt = activeAttempt,
              attempt.sessionID == sessionID,
              attempt.mountedAt == nil else { return }
        attempt.mountedAt = clock()
        activeAttempt = attempt
        emitIfReady()
    }

    func markPanelReady(sessionID: String, panelResizeMilliseconds: Int) {
        guard var attempt = activeAttempt,
              attempt.sessionID == sessionID,
              attempt.panelReadyAt == nil else { return }
        attempt.panelReadyAt = clock()
        attempt.panelResizeMilliseconds = max(0, panelResizeMilliseconds)
        activeAttempt = attempt
        emitIfReady()
    }

    func cancel(sessionID: String? = nil) {
        guard let activeAttempt else { return }
        if let sessionID, activeAttempt.sessionID != sessionID { return }
        self.activeAttempt = nil
    }

    private func emitIfReady() {
        guard let attempt = activeAttempt,
              let mountedAt = attempt.mountedAt,
              let panelReadyAt = attempt.panelReadyAt,
              let panelResizeMilliseconds = attempt.panelResizeMilliseconds else { return }
        activeAttempt = nil

        let finishedAt = max(mountedAt, panelReadyAt)
        measurementSink(
            PickyHUDOpenPerformanceMeasurement(
                totalMilliseconds: Self.milliseconds(from: attempt.startedAt, to: finishedAt),
                mountMilliseconds: Self.milliseconds(from: attempt.startedAt, to: mountedAt),
                postMountMilliseconds: Self.milliseconds(from: mountedAt, to: finishedAt),
                panelResizeMilliseconds: panelResizeMilliseconds,
                messageCount: attempt.messageCount,
                wasUnread: attempt.wasUnread
            )
        )
    }

    private static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        max(0, Int(((end - start) * 1_000).rounded()))
    }
}
