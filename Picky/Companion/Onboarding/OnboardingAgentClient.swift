//
//  OnboardingAgentClient.swift
//  Picky
//
//  PickyAgentClient implementation that replays a scripted OnboardingScenario
//  instead of talking to picky-agentd. The takeover overlay (Phase 4) swaps
//  this in for the real router for the duration of the demo so the user can
//  see the full Pickle lifecycle land in the HUD with zero LLM calls and no
//  daemon traffic. The events stream stays format-compatible with what the
//  HUD viewModel already consumes, so the same SessionCard / tool / log
//  rendering paths handle the demo unchanged.
//
//  The client is fire-and-forget by design:
//
//  - `connect()` yields `.connected` and an empty session snapshot so the
//    viewModel's loading watchdog clears even though there is no daemon.
//  - The first `submit()` starts replaying the scenario beats; any further
//    `submit()`/`send()` calls just no-op so a user mashing the panel during
//    the demo cannot spawn parallel mock sessions.
//  - `disconnect()` cancels the in-flight playback task and closes the stream.
//

import Foundation

final class OnboardingAgentClient: PickyAgentClient, @unchecked Sendable {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>

    /// Built fresh on every replay so the scenario can re-randomize its
    /// session id when the demo is restarted without giving the client itself
    /// a mutable state field. The closure shape also keeps tests in control
    /// of the playback contents.
    private let scenarioFactory: () -> OnboardingScenario

    // Tasks/state mutate from `Task` continuations, which run off the calling
    // thread. The lock keeps observation/cancellation deterministic across
    // those hops without forcing `OnboardingAgentClient` onto a specific actor.
    private let lock = NSLock()
    private var playbackTask: Task<Void, Never>?
    private var activeScenario: OnboardingScenario?
    private var didReceiveSubmission = false

    /// Per-test/per-demo override of the wait-between-beats mechanism. The
    /// production default is `Task.sleep(nanoseconds:)`; tests inject a no-op
    /// (or a custom clock) so beat ordering is checked without burning real
    /// wall-clock seconds.
    private let beatSleeper: @Sendable (UInt64) async -> Void

    init(
        scenarioFactory: @escaping () -> OnboardingScenario = { OnboardingScenario.piReleaseSummary() },
        beatSleeper: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.scenarioFactory = scenarioFactory
        self.beatSleeper = beatSleeper
    }

    func connect() async {
        continuation.yield(.connected)
        // Mimic the daemon snapshot the HUD viewModel waits for on first
        // connect. An empty snapshot is what a fresh Picky install would see
        // anyway, and it clears the "loading initial sessions" watchdog so the
        // dock is responsive while the user works through the takeover.
        emit(.sessionSnapshot(PickySessionSnapshot(sessions: [])))
    }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        // Only the first submission drives the scenario; subsequent calls reuse
        // the same receipt so the HUD never sees a second mock session spawn.
        let result: (scenario: OnboardingScenario, isFirstSubmission: Bool) = lock.withLock {
            if let existing = activeScenario {
                return (existing, false)
            }
            let built = scenarioFactory()
            didReceiveSubmission = true
            activeScenario = built
            return (built, true)
        }

        if result.isFirstSubmission {
            startPlayback(of: result.scenario)
        }
        return PickyAgentSubmissionReceipt(
            sessionID: result.scenario.sessionId,
            message: result.scenario.sessionTitle
        )
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        // The onboarding doesn't surface daemon-bound commands. Archive,
        // follow-up, steer, and the rest get swallowed so the HUD doesn't see
        // transport errors during the demo. Archive in particular goes through
        // the local archive store first; ignoring the daemon hop is harmless.
    }

    func disconnect() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let captured = playbackTask
            playbackTask = nil
            return captured
        }
        task?.cancel()
        continuation.yield(.disconnected)
        continuation.finish()
    }

    /// Test hook: drives a scenario without going through `submit()`. Use this
    /// when the scenario must be replayed against a known continuation in a
    /// unit test that already drained the events stream once.
    func startScenarioForTesting(_ scenario: OnboardingScenario) {
        lock.withLock {
            didReceiveSubmission = true
            activeScenario = scenario
        }
        startPlayback(of: scenario)
    }

    private func startPlayback(of scenario: OnboardingScenario) {
        let task = Task { [weak self] in
            guard let self else { return }
            for beat in scenario.beats {
                if Task.isCancelled { return }
                if beat.delayMs > 0 {
                    await self.beatSleeper(UInt64(beat.delayMs) * 1_000_000)
                }
                if Task.isCancelled { return }
                self.emit(beat.event)
            }
        }
        lock.withLock { playbackTask = task }
    }

    private func emit(_ event: PickyEvent) {
        let envelope = PickyEventEnvelope(
            id: UUID().uuidString,
            protocolVersion: pickyAgentProtocolVersion,
            timestamp: Date(),
            event: event
        )
        continuation.yield(.protocolEvent(envelope))
    }
}
