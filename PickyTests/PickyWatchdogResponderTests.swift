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
        var nextResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/spin-fake.txt"))

        func captureSpinSample(pid: Int32) throws -> URL {
            captureCount += 1
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

    @Test("첫 spin 감지 시 sample 캡처 + helper 한 번 띄움")
    func firstSpinTriggersCaptureAndHelper() {
        let capturer = FakeSampleCapturer()
        let launcher = FakeHelperLauncher()
        let responder = PickyWatchdogResponder(pid: 4321, capturer: capturer, launcher: launcher)

        responder.handleSpinDetected()

        #expect(capturer.captureCount == 1)
        #expect(launcher.invocations.count == 1)
        #expect(launcher.invocations.first?.pid == 4321)
        #expect(launcher.invocations.first?.samplePath.path == "/tmp/spin-fake.txt")
    }

    @Test("helper in-flight 동안의 추가 spin 감지는 무시")
    func subsequentSpinsAreCoalescedWhileHelperInFlight() {
        let capturer = FakeSampleCapturer()
        let launcher = FakeHelperLauncher()
        let responder = PickyWatchdogResponder(pid: 1, capturer: capturer, launcher: launcher)

        responder.handleSpinDetected()
        responder.handleSpinDetected()
        responder.handleSpinDetected()

        #expect(capturer.captureCount == 1)
        #expect(launcher.invocations.count == 1)
    }

    @Test("helper 종료 후 다음 spin 감지는 다시 알림")
    func helperExitResetsResponderState() {
        let capturer = FakeSampleCapturer()
        let launcher = FakeHelperLauncher()
        let responder = PickyWatchdogResponder(pid: 1, capturer: capturer, launcher: launcher)

        responder.handleSpinDetected()
        launcher.finishOldest()
        responder.handleSpinDetected()

        #expect(capturer.captureCount == 2)
        #expect(launcher.invocations.count == 2)
    }

    @Test("sample 캡처 실패 시에도 helper는 빈 경로 없이 호출되지 않고 상태 복구")
    func sampleFailureRecoversWithoutHelper() {
        let capturer = FakeSampleCapturer()
        capturer.nextResult = .failure(NSError(domain: "TestFailure", code: 1))
        let launcher = FakeHelperLauncher()
        let responder = PickyWatchdogResponder(pid: 1, capturer: capturer, launcher: launcher)

        responder.handleSpinDetected()
        // No helper because capture failed.
        #expect(launcher.invocations.isEmpty)
        // State must reset so the next spin can fire.
        capturer.nextResult = .success(URL(fileURLWithPath: "/tmp/spin-second.txt"))
        responder.handleSpinDetected()
        #expect(launcher.invocations.count == 1)
    }
}
