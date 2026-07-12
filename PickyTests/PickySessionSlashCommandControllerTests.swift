//
//  PickySessionSlashCommandControllerTests.swift
//  PickyTests
//
//  Characterization coverage for the slash-command controller that owns
//  cache, request, and epoch state for the session list facade.
//

import XCTest
@testable import Picky

@MainActor
final class PickySessionSlashCommandControllerTests: XCTestCase {
    func testEnsureLoadedSendsOnlyOneRequestUntilStateChanges() async throws {
        let harness = Harness()

        harness.controller.ensureLoaded(sessionID: "session-1")
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)

        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertEqual(harness.sent[0].type, .listSlashCommands)
        XCTAssertEqual(harness.sent[0].sessionId, "session-1")
    }

    func testMatchingSnapshotStoresCommandsAndMarksLoaded() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)

        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: harness.sent[0].id,
            commands: [command("deploy")]
        )

        XCTAssertEqual(harness.controller.commands(for: "session-1").map(\.name), ["deploy"])
        XCTAssertTrue(harness.controller.hasLoaded(sessionID: "session-1"))
    }

    func testUnknownAndDifferentSessionRequestIDsAreDiscarded() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)

        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: "unknown-request",
            commands: [command("unknown")]
        )
        harness.controller.applySnapshot(
            sessionID: "session-2",
            requestID: harness.sent[0].id,
            commands: [command("wrong-session")]
        )

        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-1"))
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-2"))
    }

    func testDifferentSessionSnapshotPreservesRequestedMarkerAfterDiscardingRequest() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-a")
        try await harness.waitForSentCount(1)

        harness.controller.applySnapshot(
            sessionID: "session-b",
            requestID: harness.sent[0].id,
            commands: [command("wrong-session")]
        )
        harness.controller.ensureLoaded(sessionID: "session-a")
        await Task.yield()

        // Characterize pre-existing behavior: discarding a request attributed to another
        // session clears request bookkeeping but leaves session A marked as requested.
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-a"))
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-b"))
    }

    func testSnapshotWithoutRequestIDRequiresCurrentEpochInFlightRequest() async throws {
        let harness = Harness()
        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: nil,
            commands: [command("no-request")]
        )
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-1"))

        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)
        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: nil,
            commands: [command("current")]
        )

        XCTAssertEqual(harness.controller.commands(for: "session-1").map(\.name), ["current"])
    }

    func testSnapshotWithoutRequestIDCleansStaleEpochBeforeAcceptingCurrentEpoch() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)
        harness.controller.invalidate(sessionID: "session-1")
        try await harness.waitForSentCount(2)

        harness.controller.applySnapshot(sessionID: "session-1", requestID: nil, commands: [command("stale")])
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-1"))

        harness.controller.applySnapshot(sessionID: "session-1", requestID: nil, commands: [command("fresh")])
        XCTAssertEqual(harness.controller.commands(for: "session-1").map(\.name), ["fresh"])
    }

    func testEpochMismatchDiscardsPreviousRequestResponse() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)
        let staleRequestID = harness.sent[0].id

        harness.controller.invalidate(sessionID: "session-1")
        try await harness.waitForSentCount(2)
        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: staleRequestID,
            commands: [command("stale")]
        )

        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-1"))
    }

    func testInvalidateRefreshRulesPreserveExistingBehavior() async throws {
        let inFlight = Harness()
        inFlight.controller.ensureLoaded(sessionID: "in-flight")
        try await inFlight.waitForSentCount(1)
        inFlight.controller.invalidate(sessionID: "in-flight")
        try await inFlight.waitForSentCount(2)

        let loaded = Harness()
        loaded.controller.ensureLoaded(sessionID: "loaded")
        try await loaded.waitForSentCount(1)
        loaded.controller.applySnapshot(
            sessionID: "loaded",
            requestID: loaded.sent[0].id,
            commands: [command("loaded")]
        )
        loaded.controller.invalidate(sessionID: "loaded", refreshIfPreviouslyRequested: true)
        try await loaded.waitForSentCount(2)
        XCTAssertFalse(loaded.controller.hasLoaded(sessionID: "loaded"))

        let untouched = Harness()
        untouched.controller.invalidate(sessionID: "untouched", refreshIfPreviouslyRequested: true)
        await Task.yield()
        XCTAssertTrue(untouched.sent.isEmpty)
    }

    func testSendFailureClearsBookkeepingReportsErrorAndAllowsRetry() async throws {
        let harness = Harness(failuresRemaining: 1)
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForFailureCount(1)

        XCTAssertEqual(harness.failures, [TestError.send.localizedDescription])

        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(2)
        XCTAssertEqual(harness.sent.count, 2)
    }

    func testRefreshWhileLoadingReRequestsAndEitherResponseCanWin() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)
        harness.controller.refreshIfStillLoading(sessionID: "session-1")
        try await harness.waitForSentCount(2)

        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: harness.sent[0].id,
            commands: [command("slow")]
        )
        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: harness.sent[1].id,
            commands: [command("polling")]
        )

        XCTAssertEqual(harness.controller.commands(for: "session-1").map(\.name), ["slow"])
        harness.controller.refreshIfStillLoading(sessionID: "session-1")
        await Task.yield()
        XCTAssertEqual(harness.sent.count, 2)
    }

    func testPruneRemovesUnknownSessionStateAndRequests() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "keep")
        harness.controller.ensureLoaded(sessionID: "remove")
        try await harness.waitForSentCount(2)
        let keepRequest = try XCTUnwrap(harness.sent.first { $0.sessionId == "keep" })
        harness.controller.applySnapshot(
            sessionID: "keep",
            requestID: keepRequest.id,
            commands: [command("keep")]
        )

        harness.controller.prune(knownSessionIDs: ["keep"])
        harness.controller.ensureLoaded(sessionID: "remove")
        try await harness.waitForSentCount(3)

        XCTAssertEqual(harness.controller.commands(for: "keep").map(\.name), ["keep"])
        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "remove"))
        XCTAssertEqual(harness.sent.filter { $0.sessionId == "remove" }.count, 2)
    }

    func testClearRemovesAllStateForSession() async throws {
        let harness = Harness()
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(1)
        harness.controller.applySnapshot(
            sessionID: "session-1",
            requestID: harness.sent[0].id,
            commands: [command("loaded")]
        )

        harness.controller.clear(sessionID: "session-1")
        harness.controller.ensureLoaded(sessionID: "session-1")
        try await harness.waitForSentCount(2)

        XCTAssertFalse(harness.controller.hasLoaded(sessionID: "session-1"))
        XCTAssertTrue(harness.controller.commands(for: "session-1").isEmpty)
    }

    private static func command(_ name: String) -> PickySlashCommand {
        PickySlashCommand(name: name, description: nil, source: .builtin)
    }

    private func command(_ name: String) -> PickySlashCommand {
        Self.command(name)
    }
}

@MainActor
private final class Harness {
    private(set) var sent: [PickyCommandEnvelope] = []
    private(set) var failures: [String] = []
    private var failuresRemaining: Int
    private(set) var controller: PickySessionSlashCommandController!

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
        self.controller = PickySessionSlashCommandController(
            sendCommand: { [weak self] command in
                guard let self else { return }
                sent.append(command)
                if self.failuresRemaining > 0 {
                    self.failuresRemaining -= 1
                    throw TestError.send
                }
            },
            onSendFailure: { [weak self] in self?.failures.append($0) }
        )
    }

    func waitForSentCount(_ count: Int) async throws {
        try await wait { self.sent.count == count }
    }

    func waitForFailureCount(_ count: Int) async throws {
        try await wait { self.failures.count == count }
    }

    private func wait(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - startedAt > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("Timed out waiting for slash-command controller state")
                return
            }
            await Task.yield()
        }
    }
}

private enum TestError: LocalizedError {
    case send

    var errorDescription: String? { "send failed" }
}
