//
//  PickyHUDOpenPerformanceTracker.swift
//  Picky
//
//  Release-safe, privacy-preserving measurement for the user-visible path from
//  clicking a Pickle dock icon until its conversation card has mounted, the
//  initial bottom-pin geometry is interactive, and the outer HUD panel has
//  settled. Detailed rendering probes remain in PickyPerf for local Instruments
//  captures; this tracker emits one bounded, scalar-only OSLog line per completed
//  dock-click open without session or conversation content.
//

import Foundation
import OSLog

struct PickyHUDOpenPerformanceMeasurement: Equatable {
    let cardMountedMilliseconds: Int
    let interactiveMilliseconds: Int
    let postMountInteractiveMilliseconds: Int
    let panelSettledMilliseconds: Int
    let panelSettleAfterInteractiveMilliseconds: Int
    let panelResizeMilliseconds: Int
    let messageCount: Int
    let wasUnread: Bool

    var logMessage: String {
        [
            "event=hudDockOpen",
            "outcome=interactiveAndPanelSettled",
            "cardMountedMs=\(cardMountedMilliseconds)",
            "interactiveMs=\(interactiveMilliseconds)",
            "postMountInteractiveMs=\(postMountInteractiveMilliseconds)",
            "panelSettledMs=\(panelSettledMilliseconds)",
            "panelSettleAfterInteractiveMs=\(panelSettleAfterInteractiveMilliseconds)",
            "panelResizeMs=\(panelResizeMilliseconds)",
            "messageCount=\(messageCount)",
            "wasUnread=\(wasUnread)"
        ].joined(separator: " ")
    }
}

final class PickyHUDOpenPerformanceTracker {
    struct AttemptToken: Equatable, Hashable {
        fileprivate let generation: UInt64
    }

    typealias Clock = () -> TimeInterval
    typealias MeasurementSink = (PickyHUDOpenPerformanceMeasurement) -> Void

    private struct Attempt {
        let token: AttemptToken
        let sessionID: String
        let startedAt: TimeInterval
        let messageCount: Int
        let wasUnread: Bool
        var mountedAt: TimeInterval?
        var interactiveAt: TimeInterval?
        var panelSettledAt: TimeInterval?
        var panelResizeMilliseconds: Int?
    }

    private let clock: Clock
    private let measurementSink: MeasurementSink
    private var nextGeneration: UInt64 = 0
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

    @discardableResult
    func start(sessionID: String, messageCount: Int, wasUnread: Bool) -> AttemptToken {
        nextGeneration &+= 1
        let token = AttemptToken(generation: nextGeneration)
        activeAttempt = Attempt(
            token: token,
            sessionID: sessionID,
            startedAt: clock(),
            messageCount: max(0, messageCount),
            wasUnread: wasUnread,
            mountedAt: nil,
            interactiveAt: nil,
            panelSettledAt: nil,
            panelResizeMilliseconds: nil
        )
        return token
    }

    func activeToken(sessionID: String) -> AttemptToken? {
        guard activeAttempt?.sessionID == sessionID else { return nil }
        return activeAttempt?.token
    }

    func markCardMounted(token: AttemptToken) {
        guard var attempt = matchingAttempt(token: token), attempt.mountedAt == nil else { return }
        attempt.mountedAt = clock()
        activeAttempt = attempt
        emitIfReady()
    }

    func markInteractive(token: AttemptToken) {
        guard var attempt = matchingAttempt(token: token), attempt.interactiveAt == nil else { return }
        attempt.interactiveAt = clock()
        activeAttempt = attempt
        emitIfReady()
    }

    func markPanelSettled(token: AttemptToken, panelResizeMilliseconds: Int) {
        guard var attempt = matchingAttempt(token: token), attempt.panelSettledAt == nil else { return }
        attempt.panelSettledAt = clock()
        attempt.panelResizeMilliseconds = max(0, panelResizeMilliseconds)
        activeAttempt = attempt
        emitIfReady()
    }

    func cancel(sessionID: String? = nil) {
        guard let activeAttempt else { return }
        if let sessionID, activeAttempt.sessionID != sessionID { return }
        self.activeAttempt = nil
    }

    private func matchingAttempt(token: AttemptToken) -> Attempt? {
        guard let activeAttempt, activeAttempt.token == token else { return nil }
        return activeAttempt
    }

    private func emitIfReady() {
        guard let attempt = activeAttempt,
              let mountedAt = attempt.mountedAt,
              let reportedInteractiveAt = attempt.interactiveAt,
              let panelSettledAt = attempt.panelSettledAt,
              let panelResizeMilliseconds = attempt.panelResizeMilliseconds else { return }
        activeAttempt = nil

        // Geometry callbacks can be delivered before the parent onAppear callback
        // even though the card cannot be interactive before it is mounted. Clamp
        // the semantic milestone to mount so callback ordering never produces a
        // negative phase or an impossible interactive-before-mounted record.
        let interactiveAt = max(mountedAt, reportedInteractiveAt)
        measurementSink(
            PickyHUDOpenPerformanceMeasurement(
                cardMountedMilliseconds: Self.milliseconds(from: attempt.startedAt, to: mountedAt),
                interactiveMilliseconds: Self.milliseconds(from: attempt.startedAt, to: interactiveAt),
                postMountInteractiveMilliseconds: Self.milliseconds(from: mountedAt, to: interactiveAt),
                panelSettledMilliseconds: Self.milliseconds(from: attempt.startedAt, to: panelSettledAt),
                panelSettleAfterInteractiveMilliseconds: Self.milliseconds(
                    from: interactiveAt,
                    to: max(interactiveAt, panelSettledAt)
                ),
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
