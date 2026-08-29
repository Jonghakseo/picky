//
//  PickyWatchdogResponderTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyWatchdogResponder")
struct PickyWatchdogResponderTests {
    private final class FakeSampleCapturer: PickyWatchdogResponder.SampleCapturing {
        private(set) var captureCount = 0
        private(set) var contexts: [PickyWatchdogCaptureContext] = []
        var nextResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/spin-fake.txt"))

        func captureSpinSample(pid: Int32, context: PickyWatchdogCaptureContext) throws -> URL {
            captureCount += 1
            contexts.append(context)
            return try nextResult.get()
        }
    }

    private final class FakeHelperLauncher: PickyWatchdogResponder.HelperLaunching {
        private(set) var invocations: [(pid: Int32, samplePath: URL)] = []
        /// Stores the completion callback so the test can simulate the helper
        /// exiting later, releasing the responder's "in-flight" state.
        private var pendingCompletions: [() -> Void] = []

        func launchHelper(parentPid: Int32, samplePath: URL, completion: @escaping () -> Void) {
            invocations.append((parentPid, samplePath))
            pendingCompletions.append(completion)
        }

        func finishOldest() {
            guard !pendingCompletions.isEmpty else { return }
            let callback = pendingCompletions.removeFirst()
            callback()
        }
    }

    /// Drives the responder without a real dispatch queue so assertions can run
    /// immediately after each call.
    private final class Harness {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let capturer = FakeSampleCapturer()
        let launcher = FakeHelperLauncher()
        let responder: PickyWatchdogResponder

        init(pid: Int32 = 4321, captureCooldown: TimeInterval = 60) {
            var capturedSelf: Harness?
            self.responder = PickyWatchdogResponder(
                pid: pid,
                capturer: capturer,
                launcher: launcher,
                clock: { capturedSelf?.now ?? Date() },
                captureCooldown: captureCooldown,
                executor: { work in work() }
            )
            capturedSelf = self
        }

        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @Test("soft stall 엣지에서 sample을 캡처하고 알림은 띄우지 않음")
    func softStallCapturesWithoutAlert() {
        let h = Harness()

        h.responder.handleSoftStallDetected(age: 2.5)

        #expect(h.capturer.captureCount == 1)
        #expect(h.capturer.contexts.first?.trigger == .softStall)
        #expect(h.capturer.contexts.first?.heartbeatAgeAtStart == 2.5)
        // Stall start is derived by rewinding the observed age.
        #expect(h.capturer.contexts.first?.stallStartedAt == h.now.addingTimeInterval(-2.5))
        #expect(h.launcher.invocations.isEmpty)
    }

    @Test("같은 스톨에서 캡처된 sample을 spin 알림이 재사용")
    func spinReusesSampleFromSameStall() {
        let h = Harness()

        h.responder.handleSoftStallDetected(age: 2.5)
        h.advance(by: 8)
        h.responder.handleSpinDetected()

        // No second capture: the soft-stall sample already covers this stall.
        #expect(h.capturer.captureCount == 1)
        #expect(h.launcher.invocations.count == 1)
        #expect(h.launcher.invocations.first?.samplePath.path == "/tmp/spin-fake.txt")
    }

    @Test("선행 캡처가 없으면 spin이 직접 캡처하되 늦은 창으로 표시")
    func spinWithoutPriorCaptureMarksItselfLate() {
        let h = Harness()
        h.responder.heartbeatAge = { 11.0 }

        h.responder.handleSpinDetected()

        #expect(h.capturer.captureCount == 1)
        #expect(h.capturer.contexts.first?.trigger == .spin)
        #expect(h.capturer.contexts.first?.heartbeatAgeAtStart == 11.0)
        #expect(h.launcher.invocations.count == 1)
    }

    @Test("회복 후 새 스톨은 이전 스톨의 sample을 재사용하지 않음")
    func recoveredStallDoesNotReusePreviousSample() {
        let h = Harness()

        h.responder.handleSoftStallDetected(age: 2.5)
        h.responder.handleStallRecovered()
        h.advance(by: 120) // clear cooldown
        h.responder.handleSpinDetected()

        // Second capture because the reusable sample belonged to the old stall.
        #expect(h.capturer.captureCount == 2)
        #expect(h.capturer.contexts.last?.trigger == .spin)
    }

    @Test("쿨다운 안에서 반복되는 soft stall은 sample을 다시 뜨지 않음")
    func repeatedSoftStallsAreRateLimited() {
        let h = Harness(captureCooldown: 60)

        h.responder.handleSoftStallDetected(age: 2.5)
        h.responder.handleStallRecovered()
        h.advance(by: 20)
        h.responder.handleSoftStallDetected(age: 2.5)
        h.responder.handleStallRecovered()
        h.advance(by: 20)
        h.responder.handleSoftStallDetected(age: 2.5)

        #expect(h.capturer.captureCount == 1)
    }

    @Test("쿨다운이 지나면 다음 스톨을 다시 캡처")
    func captureResumesAfterCooldown() {
        let h = Harness(captureCooldown: 60)

        h.responder.handleSoftStallDetected(age: 2.5)
        h.responder.handleStallRecovered()
        h.advance(by: 61)
        h.responder.handleSoftStallDetected(age: 2.5)

        #expect(h.capturer.captureCount == 2)
        #expect(h.capturer.contexts.allSatisfy { $0.trigger == .softStall })
    }

    @Test("helper in-flight 동안의 추가 spin 감지는 무시")
    func subsequentSpinsAreCoalescedWhileHelperInFlight() {
        let h = Harness()

        h.responder.handleSpinDetected()
        h.responder.handleSpinDetected()
        h.responder.handleSpinDetected()

        #expect(h.capturer.captureCount == 1)
        #expect(h.launcher.invocations.count == 1)
    }

    @Test("helper 종료 후 다음 spin 감지는 다시 알림")
    func helperExitResetsResponderState() {
        let h = Harness()

        h.responder.handleSpinDetected()
        h.launcher.finishOldest()
        h.advance(by: 120)
        h.responder.handleSpinDetected()

        #expect(h.launcher.invocations.count == 2)
    }

    @Test("sample 캡처 실패 시에도 helper는 빈 경로 없이 호출되지 않고 상태 복구")
    func sampleFailureRecoversWithoutHelper() {
        let h = Harness()
        h.capturer.nextResult = .failure(NSError(domain: "TestFailure", code: 1))

        h.responder.handleSpinDetected()
        #expect(h.launcher.invocations.isEmpty)

        // State must reset so the next spin can fire.
        h.capturer.nextResult = .success(URL(fileURLWithPath: "/tmp/spin-second.txt"))
        h.responder.handleSpinDetected()
        #expect(h.launcher.invocations.count == 1)
        #expect(h.launcher.invocations.first?.samplePath.path == "/tmp/spin-second.txt")
    }

    @Test("soft stall 캡처 실패해도 이후 spin 알림은 계속 동작")
    func softStallCaptureFailureDoesNotBlockAlert() {
        let h = Harness()
        h.capturer.nextResult = .failure(NSError(domain: "TestFailure", code: 1))

        h.responder.handleSoftStallDetected(age: 2.5)
        h.capturer.nextResult = .success(URL(fileURLWithPath: "/tmp/spin-late.txt"))
        h.advance(by: 8)
        h.responder.handleSpinDetected()

        #expect(h.launcher.invocations.count == 1)
        #expect(h.launcher.invocations.first?.samplePath.path == "/tmp/spin-late.txt")
    }
}
