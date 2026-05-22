//
//  PickySystemCaptureMonitorTests.swift
//  PickyTests
//

import Testing
@testable import Picky

@MainActor
struct PickySystemCaptureMonitorTests {
    @Test func matcherRecognizesBuiltInScreenshotApplications() {
        #expect(PickySystemCaptureApplicationMatcher.isSystemCaptureApplication(
            PickyRunningApplicationSnapshot(
                bundleIdentifier: "com.apple.screencaptureui",
                localizedName: nil,
                bundleURLLastPathComponent: nil
            )
        ))
        #expect(PickySystemCaptureApplicationMatcher.isSystemCaptureApplication(
            PickyRunningApplicationSnapshot(
                bundleIdentifier: "com.apple.screenshot.launcher",
                localizedName: nil,
                bundleURLLastPathComponent: nil
            )
        ))
        #expect(PickySystemCaptureApplicationMatcher.isSystemCaptureApplication(
            PickyRunningApplicationSnapshot(
                bundleIdentifier: nil,
                localizedName: "screencaptureui",
                bundleURLLastPathComponent: nil
            )
        ))
        #expect(PickySystemCaptureApplicationMatcher.isSystemCaptureApplication(
            PickyRunningApplicationSnapshot(
                bundleIdentifier: nil,
                localizedName: nil,
                bundleURLLastPathComponent: "Screenshot.app"
            )
        ))
    }

    @Test func matcherIgnoresUnrelatedApplications() {
        #expect(!PickySystemCaptureApplicationMatcher.isSystemCaptureApplication(
            PickyRunningApplicationSnapshot(
                bundleIdentifier: "com.apple.finder",
                localizedName: "Finder",
                bundleURLLastPathComponent: "Finder.app"
            )
        ))
    }

    @Test func monitorSuppressesImmediatelyAndRestoresAfterDebounce() async throws {
        var runningApplications = [
            PickyRunningApplicationSnapshot(
                bundleIdentifier: "com.apple.screencaptureui",
                localizedName: "screencaptureui",
                bundleURLLastPathComponent: "screencaptureui.app"
            )
        ]
        var changes: [Bool] = []
        let monitor = PickySystemCaptureMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationsProvider: { runningApplications },
            restoreDelayNanoseconds: 1_000_000,
            suppressionHandler: { changes.append($0) }
        )

        monitor.start()
        #expect(monitor.isSystemCaptureActive)
        #expect(changes == [true])

        runningApplications = []
        monitor.evaluateRunningApplications()
        #expect(monitor.isSystemCaptureActive)
        #expect(changes == [true])

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!monitor.isSystemCaptureActive)
        #expect(changes == [true, false])

        monitor.stop()
    }
}
