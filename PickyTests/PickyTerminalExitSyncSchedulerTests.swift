//
//  PickyTerminalExitSyncSchedulerTests.swift
//  PickyTests
//
//  Verifies the scheduler that waits for the pi child process to exit before
//  triggering the post-overlay session sync.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyTerminalExitSyncSchedulerTests {
    @Test func firesImmediatelyWhenProcessNeverStarted() async {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 1.0)
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        #expect(fired == 1)
        #expect(!scheduler.hasPendingSync)
    }

    @Test func firesImmediatelyWhenProcessAlreadyExited() async {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 1.0)
        scheduler.markStarted()
        scheduler.markExited()
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        #expect(fired == 1)
    }

    @Test func waitsForMarkExitedWhenProcessIsRunning() async {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 1.0)
        scheduler.markStarted()
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        #expect(fired == 0)
        #expect(scheduler.hasPendingSync)

        scheduler.markExited()
        #expect(fired == 1)
        #expect(!scheduler.hasPendingSync)
    }

    @Test func laterScheduleReplacesEarlierBlock() async {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 1.0)
        scheduler.markStarted()
        var firstFired = 0
        var secondFired = 0
        scheduler.scheduleOnExit { firstFired += 1 }
        scheduler.scheduleOnExit { secondFired += 1 }
        scheduler.markExited()
        #expect(firstFired == 0)
        #expect(secondFired == 1)
    }

    @Test func fallbackTimerFiresWhenMarkExitedNeverArrives() async throws {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 0.05)
        scheduler.markStarted()
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        #expect(fired == 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 1)
        #expect(!scheduler.hasPendingSync)
    }

    @Test func markExitedCancelsFallbackTimer() async throws {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 0.05)
        scheduler.markStarted()
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        scheduler.markExited()
        #expect(fired == 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 1) // fallback should not fire after exit
    }

    @Test func markExitedAfterFiringIsNoop() async {
        let scheduler = PickyTerminalExitSyncScheduler(fallbackInterval: 1.0)
        scheduler.markStarted()
        var fired = 0
        scheduler.scheduleOnExit { fired += 1 }
        scheduler.markExited()
        scheduler.markExited()
        #expect(fired == 1)
    }
}
