//
//  PickyMainThreadWatchdogTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyMainThreadWatchdog")
struct PickyMainThreadWatchdogTests {
    /// Driver that lets tests drive `clock` and observe `onSpinDetected` calls
    /// without spinning a real run loop or dispatch queue. The watchdog under
    /// test exposes `heartbeat(at:)` and `checkForSpin(at:)` as the seams the
    /// production timer/observer would call.
    private final class TestHarness {
        var currentTime = Date(timeIntervalSinceReferenceDate: 1_000)
        var spinCount = 0
        let watchdog: PickyMainThreadWatchdog

        init(threshold: TimeInterval = 10, grace: TimeInterval = 30, sleepCooldown: TimeInterval = 5) {
            var capturedSelf: TestHarness?
            let now: () -> Date = { capturedSelf?.currentTime ?? Date() }
            self.watchdog = PickyMainThreadWatchdog(
                clock: now,
                threshold: threshold,
                grace: grace,
                sleepCooldown: sleepCooldown,
                onSpinDetected: { /* set after init */ }
            )
            capturedSelf = self
            // Inject the spin counter callback now that `self` is fully initialized.
            self.watchdog.onSpinDetected = { [weak self] in self?.spinCount += 1 }
            self.watchdog.startedAt = currentTime
        }

        func advance(by seconds: TimeInterval) {
            currentTime = currentTime.addingTimeInterval(seconds)
        }

        func heartbeat() { watchdog.heartbeat(at: currentTime) }
        func check() { watchdog.checkForSpin(at: currentTime) }
        func suspend(_ reason: PickyMainThreadWatchdog.SuspensionReason) {
            watchdog.suspendMonitoring(for: reason, at: currentTime)
        }
        func resume(_ reason: PickyMainThreadWatchdog.SuspensionReason) {
            watchdog.resumeMonitoring(for: reason, at: currentTime)
        }
    }

    @Test("heartbeat이 임계값 안에서 갱신되면 spin 콜백 호출 안 함")
    func heartbeatWithinThresholdDoesNotTrigger() {
        let h = TestHarness()
        h.advance(by: 60) // past grace
        h.heartbeat()
        h.advance(by: 2)
        h.heartbeat()
        h.advance(by: 2)
        h.check()
        #expect(h.spinCount == 0)
    }

    @Test("heartbeat가 임계값 초과 시 spin 콜백 1회 호출")
    func heartbeatStaleTriggersSpin() {
        let h = TestHarness()
        h.advance(by: 60)
        h.heartbeat()
        h.advance(by: 11) // > threshold 10
        h.check()
        #expect(h.spinCount == 1)
    }

    @Test("grace period 안에서는 stale 상태여도 콜백 호출 안 함")
    func graceSuppressesEarlySpin() {
        let h = TestHarness(grace: 30)
        // No heartbeat at all; immediately at t=0 we're stale by definition.
        h.advance(by: 10) // still within grace
        h.check()
        #expect(h.spinCount == 0)
    }

    @Test("spin 콜백은 같은 stale 윈도우에서 한 번만 호출")
    func spinFiresOncePerStaleWindow() {
        let h = TestHarness()
        h.advance(by: 60)
        h.heartbeat()
        h.advance(by: 11)
        h.check()
        h.check()
        h.check()
        #expect(h.spinCount == 1)
    }

    @Test("heartbeat 회복 후 다음 stale에 다시 트리거")
    func recoverThenSpinAgainFires() {
        let h = TestHarness()
        h.advance(by: 60)
        h.heartbeat()
        h.advance(by: 11)
        h.check() // first spin
        // Recover
        h.advance(by: 1)
        h.heartbeat()
        h.advance(by: 11)
        h.check() // second spin
        #expect(h.spinCount == 2)
    }

    @Test("메인 큐 heartbeat가 1초 주기로 갱신되면 idle 상태에서도 spin 콜백 호출 안 함")
    func mainQueueHeartbeatPreventsIdleFalsePositive() {
        // Simulates the production behavior where the main-queue heartbeat
        // timer fires at 1Hz even when the CFRunLoopObserver gets no
        // beforeWaiting/afterWaiting callbacks (UIElement app idle in
        // mach_msg). The utility poller should never see a stale heartbeat.
        let h = TestHarness()
        h.advance(by: 60) // past grace
        for _ in 0..<10 {
            h.heartbeat() // proxy for main-queue 1Hz heartbeat tick
            h.advance(by: 1)
            h.check()    // proxy for utility 1Hz poll
        }
        #expect(h.spinCount == 0)
    }

    @Test("메인 큐 heartbeat가 멈추면 utility 폴러가 spin 감지")
    func mainQueueHeartbeatStallStillTriggers() {
        // If main is truly pegged the main-queue timer also stops firing.
        // Utility poller must still see the heartbeat go stale and trip.
        let h = TestHarness()
        h.advance(by: 60)
        h.heartbeat()
        // No further heartbeats — emulate main pegged.
        h.advance(by: 11)
        h.check()
        #expect(h.spinCount == 1)
    }

    @Test("sleep wake 통지 후 cooldown 동안은 spin 콜백 호출 안 함")
    func sleepCooldownSuppressesSpin() {
        let h = TestHarness(sleepCooldown: 5)
        h.advance(by: 60)
        h.heartbeat()
        // System wakes; heartbeat hasn't caught up yet, but cooldown is active.
        h.watchdog.noteWoke(at: h.currentTime)
        h.advance(by: 11) // beyond threshold but still protected by wake cooldown reference
        h.check()
        #expect(h.spinCount == 0)
        // After cooldown plus another threshold without heartbeat, spin should fire.
        h.advance(by: 11)
        h.check()
        #expect(h.spinCount == 1)
    }

    @Test("screen lock 중에는 stale heartbeat여도 spin 콜백 호출 안 함")
    func screenLockSuspensionSuppressesSpinUntilUnlockCooldownExpires() {
        let h = TestHarness(sleepCooldown: 5)
        h.advance(by: 60)
        h.heartbeat()
        h.suspend(.screenLock)

        h.advance(by: 60)
        h.check()
        #expect(h.spinCount == 0)

        h.resume(.screenLock)
        h.advance(by: 11) // resume time + cooldown is still within threshold
        h.check()
        #expect(h.spinCount == 0)

        h.advance(by: 5)
        h.check()
        #expect(h.spinCount == 1)
    }

    @Test("display sleep과 screen lock이 겹치면 모든 suspension이 해제될 때까지 spin 감지 안 함")
    func overlappingSuspensionsRequireAllReasonsToResume() {
        let h = TestHarness(sleepCooldown: 5)
        h.advance(by: 60)
        h.heartbeat()
        h.suspend(.displaySleep)
        h.suspend(.screenLock)

        h.advance(by: 60)
        h.resume(.displaySleep)
        h.check()
        #expect(h.spinCount == 0)

        h.advance(by: 60)
        h.check()
        #expect(h.spinCount == 0)

        h.resume(.screenLock)
        h.advance(by: 11)
        h.check()
        #expect(h.spinCount == 0)

        h.advance(by: 5)
        h.check()
        #expect(h.spinCount == 1)
    }
}
