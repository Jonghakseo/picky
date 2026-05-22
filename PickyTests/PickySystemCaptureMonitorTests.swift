//
//  PickySystemCaptureMonitorTests.swift
//  PickyTests
//

import CoreGraphics
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

    @Test func shortcutMatcherRecognizesMacOSScreenshotShortcuts() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        #expect(PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 20, flags: flags))
        #expect(PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 21, flags: flags))
        #expect(PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 22, flags: flags))
        #expect(PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 23, flags: flags))
        #expect(!PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 21, flags: [.maskCommand]))
        #expect(!PickySystemCaptureShortcutMatcher.isScreenshotShortcut(keyCode: 0, flags: flags))
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
            pollingInterval: 0,
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

    @Test func shortcutSuppressionStartsBeforeScreenshotAppAppears() async throws {
        var changes: [Bool] = []
        let monitor = PickySystemCaptureMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationsProvider: { [] },
            shortcutFallbackNanoseconds: 1_000_000,
            pollingInterval: 0,
            suppressionHandler: { changes.append($0) }
        )

        monitor.start()
        #expect(!monitor.isSystemCaptureActive)
        #expect(changes == [])

        monitor.noteScreenshotShortcutStartedForTesting()
        #expect(monitor.isSystemCaptureActive)
        #expect(changes == [true])

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!monitor.isSystemCaptureActive)
        #expect(changes == [true, false])

        monitor.stop()
    }

    @Test func shortcutSuppressionSurvivesUntilCaptureInteractionCompletes() async throws {
        var changes: [Bool] = []
        let monitor = PickySystemCaptureMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationsProvider: { [] },
            shortcutFallbackNanoseconds: 1_000_000_000,
            shortcutCompletionDelayNanoseconds: 1_000_000,
            pollingInterval: 0,
            suppressionHandler: { changes.append($0) }
        )

        monitor.start()
        monitor.noteScreenshotShortcutStartedForTesting()
        monitor.noteCaptureInteractionCompletedForTesting()
        #expect(monitor.isSystemCaptureActive)

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!monitor.isSystemCaptureActive)
        #expect(changes == [true, false])

        monitor.stop()
    }
}
