//
//  OnboardingAgentClientTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct OnboardingAgentClientTests {
    @Test func connectEmitsConnectedThenEmptySessionSnapshot() async throws {
        let client = OnboardingAgentClient(beatSleeper: { _ in })
        Task { await client.connect() }

        let firstTwo = try await collectEvents(from: client, count: 2)

        switch firstTwo[0] {
        case .connected: break
        default: Issue.record("Expected first event to be .connected, got \(firstTwo[0])")
        }
        guard case let .protocolEvent(envelope) = firstTwo[1], case let .sessionSnapshot(snapshot) = envelope.event else {
            Issue.record("Expected sessionSnapshot follow-up, got \(firstTwo[1])")
            return
        }
        #expect(snapshot.isEmpty)
    }

    @Test func submitPlaysScenarioBeatsInOrderWithStableSessionId() async throws {
        let scenario = OnboardingScenario.instantTwoBeatFixture(sessionId: "test-session")
        let client = OnboardingAgentClient(scenarioFactory: { scenario }, beatSleeper: { _ in })

        Task { await client.connect() }
        _ = try await collectEvents(from: client, count: 2) // drain connect + initial snapshot

        let receipt = try await client.submit(PickyAgentSubmission(
            transcript: "summarize",
            context: PickyContextPacket.minimalFixture()
        ))
        #expect(receipt.sessionID == "test-session")

        let beats = try await collectEvents(from: client, count: scenario.beats.count)
        let sessionUpdates = beats.compactMap { event -> PickyAgentSession? in
            guard case let .protocolEvent(envelope) = event, case let .sessionUpdated(session) = envelope.event else { return nil }
            return session
        }
        #expect(sessionUpdates.count == scenario.beats.count)
        // Every emitted session targets the same id so the HUD treats them as
        // updates to a single card rather than parallel mock sessions.
        #expect(sessionUpdates.allSatisfy { $0.id == "test-session" })
        #expect(sessionUpdates.first?.status == .queued)
        #expect(sessionUpdates.last?.status == .completed)
        #expect(sessionUpdates.last?.finalAnswer == "Done.")
    }

    @Test func submitTwiceReturnsSameReceiptAndDoesNotRestartPlayback() async throws {
        var built = 0
        let factory: () -> OnboardingScenario = {
            built += 1
            return OnboardingScenario.instantTwoBeatFixture(sessionId: "stable-id")
        }
        let client = OnboardingAgentClient(scenarioFactory: factory, beatSleeper: { _ in })
        Task { await client.connect() }
        _ = try await collectEvents(from: client, count: 2)

        let first = try await client.submit(PickyAgentSubmission(transcript: "a", context: .minimalFixture()))
        let second = try await client.submit(PickyAgentSubmission(transcript: "b", context: .minimalFixture()))

        #expect(built == 1)
        #expect(first.sessionID == second.sessionID)
    }

    @Test func disconnectCancelsInFlightPlayback() async throws {
        // Use a long sleeper that the disconnect must interrupt so we can prove
        // the playback task didn't push the second beat past the disconnect.
        let scenario = OnboardingScenario(
            sessionId: "cancel-me",
            sessionTitle: "Cancel",
            cwd: nil,
            beats: [
                OnboardingScenario.Beat(delayMs: 0, event: .sessionLogAppended(sessionId: "cancel-me", line: "first")),
                OnboardingScenario.Beat(delayMs: 100_000, event: .sessionLogAppended(sessionId: "cancel-me", line: "second"))
            ]
        )
        let didStartSecondSleep = LockedFlag()
        let client = OnboardingAgentClient(
            scenarioFactory: { scenario },
            beatSleeper: { nanoseconds in
                if nanoseconds > 0 {
                    didStartSecondSleep.set(true)
                    // Yield so the cancel can land before this sleep completes.
                    try? await Task.sleep(nanoseconds: 50_000_000_000)
                }
            }
        )
        Task { await client.connect() }
        _ = try await collectEvents(from: client, count: 2)

        _ = try await client.submit(PickyAgentSubmission(transcript: "go", context: .minimalFixture()))
        // First beat (no sleep) must land before disconnect runs.
        _ = try await collectEvents(from: client, count: 1)

        client.disconnect()
        // Drain whatever the stream emits before closing. We expect at most a
        // .disconnected event \u2014 the second beat must not have made it through.
        var trailing: [PickyClientEvent] = []
        for await event in client.events { trailing.append(event) }

        let logEvents = trailing.compactMap { event -> String? in
            guard case let .protocolEvent(envelope) = event, case let .sessionLogAppended(_, line) = envelope.event else { return nil }
            return line
        }
        #expect(!logEvents.contains("second"))
        #expect(didStartSecondSleep.value == true)
    }

    // MARK: - Helpers

    private func collectEvents(from client: OnboardingAgentClient, count: Int) async throws -> [PickyClientEvent] {
        var collected: [PickyClientEvent] = []
        for await event in client.events {
            collected.append(event)
            if collected.count == count { break }
        }
        return collected
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set(_ newValue: Bool) { lock.withLock { _value = newValue } }
}

private extension PickyContextPacket {
    /// Minimal packet fixture for tests that don't care about context content;
    /// the onboarding scenario ignores submission context so any well-formed
    /// packet works.
    static func minimalFixture() -> PickyContextPacket {
        PickyContextPacket(
            id: "ctx-onboarding-test",
            source: "onboarding-test",
            capturedAt: Date(),
            transcript: nil,
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }
}
