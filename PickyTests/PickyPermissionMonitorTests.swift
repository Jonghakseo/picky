import Combine
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyPermissionMonitorTests {
    private final class ProbeState {
        var accessibility = false
        var screenRecording = false
        var microphone = false
        var persistedScreenContent = false
        var persistCalls = 0
    }

    private func makeMonitor(forceMissing: Bool = false) -> (PickyPermissionMonitor, ProbeState) {
        let state = ProbeState()
        var probes = PickyPermissionMonitor.Probes()
        probes.accessibility = { state.accessibility }
        probes.screenRecording = { state.screenRecording }
        probes.microphone = { state.microphone }
        probes.persistedScreenContent = { state.persistedScreenContent }
        probes.persistScreenContent = { state.persistCalls += 1 }
        return (PickyPermissionMonitor(probes: probes, forceMissing: forceMissing), state)
    }

    @Test func refreshPublishesAccessibilityOnEveryProbe() {
        let (monitor, state) = makeMonitor()
        var probed: [Bool] = []
        let cancellable = monitor.accessibilityProbed.sink { probed.append($0) }
        defer { cancellable.cancel() }

        monitor.refresh()
        state.accessibility = true
        monitor.refresh()
        monitor.refresh()

        #expect(probed == [false, true, true])
        #expect(monitor.hasAccessibility)
    }

    @Test func becameAllGrantedFiresOnceAcrossRefreshAndScreenContentGrant() {
        let (monitor, state) = makeMonitor()
        var fired = 0
        let cancellable = monitor.becameAllGranted.sink { fired += 1 }
        defer { cancellable.cancel() }

        state.accessibility = true
        state.screenRecording = true
        state.microphone = true
        monitor.refresh()
        #expect(fired == 0)
        #expect(!monitor.allGranted)

        monitor.markScreenContentGranted()
        #expect(fired == 1)
        #expect(monitor.allGranted)
        #expect(state.persistCalls == 1)

        monitor.refresh()
        #expect(fired == 1)
    }

    @Test func persistedScreenContentGrantIsReadOnceAndSticks() {
        let (monitor, state) = makeMonitor()
        state.persistedScreenContent = true
        monitor.refresh()
        #expect(monitor.hasScreenContent)

        state.persistedScreenContent = false
        monitor.refresh()
        #expect(monitor.hasScreenContent)
    }

    @Test func forceMissingReportsFalseButStillProbesRealState() {
        let (monitor, state) = makeMonitor(forceMissing: true)
        var probed: [Bool] = []
        let cancellable = monitor.accessibilityProbed.sink { probed.append($0) }
        defer { cancellable.cancel() }

        state.accessibility = true
        state.screenRecording = true
        state.microphone = true
        state.persistedScreenContent = true
        monitor.refresh()

        #expect(probed == [true])
        #expect(!monitor.hasAccessibility)
        #expect(!monitor.allGranted)
    }
}
