//
//  PickyHubFocusPerformanceTests.swift
//  PickyTests
//
//  WindowServer-backed performance contract for Hub activation. This test is
//  deliberately pre-push-only because it owns key windows briefly.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Picky

@Suite(.serialized)
@MainActor
struct PickyHubFocusPerformanceTests {
    @Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))
    func productionHubFocusTransitionsMeetTheLocalLatencyBudget() async throws {
        let fixture = try PickyHubRenderGalleryFixture()
        defer { fixture.removeTemporaryState() }
        fixture.navigator.select(.settings)
        let externalApplication = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
            "A logged-in Finder is required for the cross-application focus scenario; no app will be launched"
        )
        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        let hubWindow = PickyHubWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1020, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controlWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        hubWindow.isReleasedWhenClosed = false
        controlWindow.isReleasedWhenClosed = false
        hubWindow.title = "Isolated Hub settings focus measurement"
        controlWindow.title = "Isolated focus control"
        let recorder = HubFocusTransitionRecorder()
        let didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: hubWindow, queue: .main
        ) { _ in
            recorder.recordKeyAcquisition()
        }
        defer {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            hubWindow.orderOut(nil)
            controlWindow.orderOut(nil)
            hubWindow.close()
            controlWindow.close()
            if let previouslyFrontmostApplication,
               previouslyFrontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previouslyFrontmostApplication.activate(options: [])
            }
        }

        controlWindow.contentView = NSHostingView(rootView: Text("Focus control window")
            .frame(maxWidth: .infinity, maxHeight: .infinity))

        let root = PickyAppFontScaleRoot(store: fixture.fontScaleStore) {
            PickyHubRootView(dependencies: fixture.dependencies, dockDisplayIDProvider: { nil })
                .environmentObject(fixture.appearanceStore)
                .environmentObject(fixture.hudVisibilityStore)
                .environmentObject(fixture.updaterController)
                .environmentObject(fixture.pluginReloadController)
                .modifier(PickyPreferredColorSchemeModifier(store: fixture.appearanceStore))
        }
        let hubHost = NSHostingView(rootView: LocalizedHostingRoot { root })
        hubHost.frame = NSRect(origin: .zero, size: hubWindow.contentLayoutRect.size)
        hubHost.autoresizingMask = [.width, .height]
        hubWindow.contentView = hubHost

        guard !NSScreen.screens.isEmpty else {
            throw HubFocusPerformanceError.windowServerUnavailable("NSScreen returned no displays")
        }
        NSApp.activate(ignoringOtherApps: true)
        controlWindow.makeKeyAndOrderFront(nil)
        try await waitUntil("control window activation") {
            NSApp.isActive && controlWindow.isKeyWindow
        }

        // Warm-up establishes the production hierarchy and AppKit's first-use
        // resources without making the gate depend on cold process startup.
        for _ in 0..<2 {
            recorder.beginTransition()
            hubWindow.makeKeyAndOrderFront(nil)
            try await waitUntil("Hub warm-up key acquisition") { hubWindow.isKeyWindow && recorder.keyTimestamp != nil }
            hubHost.layoutSubtreeIfNeeded()
            hubHost.displayIfNeeded()
            await nextMainRunLoopTurn()
            controlWindow.makeKeyAndOrderFront(nil)
            try await waitUntil("control warm-up key acquisition") { controlWindow.isKeyWindow }
        }

        let menus = nativeMenus(in: hubHost)
        try #require(menus.contains { $0.itemTitles == ["90%", "100%", "110%", "120%", "130%"] })
        try #require(menus.filter { $0.numberOfItems == 19 && $0.itemTitles.first == "70%" }.count == 2,
                     "The real report/terminal menus must be mounted; an empty dashboard is not a valid benchmark")

        var samples: [HubFocusSample] = []
        for index in 1...7 {
            externalApplication.activate(options: [])
            try await waitUntil("external application transition \(index)") {
                externalApplication.isActive && !NSApp.isActive
            }

            let sample = try await measureHubTransition(
                index: index,
                hubWindow: hubWindow,
                hubHost: hubHost,
                recorder: recorder
            ) {
                NSApp.activate(ignoringOtherApps: true)
                hubWindow.makeKeyAndOrderFront(nil)
            }
            samples.append(sample)
        }

        // This is intentionally outside the measured samples. A synchronous
        // delay in the key-window path must move the key-acquisition metric,
        // otherwise the harness would be a blind stopwatch.
        controlWindow.makeKeyAndOrderFront(nil)
        try await waitUntil("negative-control setup") { controlWindow.isKeyWindow }
        let injectedDelayMilliseconds = HubFocusThreshold.current.keyMaxMilliseconds + 50
        let negativeControl: HubFocusSample
        do {
            let resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: controlWindow, queue: .main
            ) { _ in
                Thread.sleep(forTimeInterval: injectedDelayMilliseconds / 1_000)
            }
            defer { NotificationCenter.default.removeObserver(resignObserver) }
            negativeControl = try await measureHubTransition(
                index: 0,
                hubWindow: hubWindow,
                hubHost: hubHost,
                recorder: recorder
            ) {
                hubWindow.makeKeyAndOrderFront(nil)
            }
        }
        guard negativeControl.keyAcquisitionMilliseconds >= injectedDelayMilliseconds * 0.75 else {
            throw HubFocusPerformanceError.sensitivityNotDetected(
                expectedMilliseconds: injectedDelayMilliseconds,
                observedMilliseconds: negativeControl.keyAcquisitionMilliseconds
            )
        }

        try #require(!HubFocusThreshold.current.accepts(
            key: HubFocusSummary([negativeControl.keyAcquisitionMilliseconds]),
            render: HubFocusSummary([negativeControl.renderReadyAfterKeyMilliseconds])
        ), "The same regression gate must reject the deliberately blocked focus transition")

        let reportResult = try writeReport(
            samples: samples,
            negativeControl: negativeControl,
            injectedDelayMilliseconds: injectedDelayMilliseconds,
            hubHost: hubHost
        )
        if reportResult.mode == .calibration {
            throw HubFocusPerformanceError.calibrationCompleted(reportResult.url)
        }
        guard reportResult.report.gateStatus == .passed else {
            throw HubFocusPerformanceError.latencyBudgetExceeded(
                key: reportResult.keySummary,
                render: reportResult.renderSummary,
                threshold: HubFocusThreshold.current,
                report: reportResult.url
            )
        }
    }

    private func measureHubTransition(
        index: Int,
        hubWindow: NSWindow,
        hubHost: NSView,
        recorder: HubFocusTransitionRecorder,
        activate: () -> Void
    ) async throws -> HubFocusSample {
        recorder.beginTransition()
        let cpuStartedAt = try mainThreadCPUMilliseconds()
        let startedAt = DispatchTime.now().uptimeNanoseconds
        activate()
        try await waitUntil("Hub transition \(index) key acquisition") {
            NSApp.isActive && hubWindow.isKeyWindow && recorder.keyTimestamp != nil
        }
        guard let keyedAt = recorder.keyTimestamp, keyedAt >= startedAt else {
            throw HubFocusPerformanceError.invalidKeyTimestamp(index)
        }

        // This is the first executable main-loop/render checkpoint after the
        // actual AppKit key-window transition. It does not claim compositor or
        // input-event end-to-end latency, which macOS does not expose here.
        await nextMainRunLoopTurn()
        hubHost.layoutSubtreeIfNeeded()
        hubHost.displayIfNeeded()
        let renderedAt = DispatchTime.now().uptimeNanoseconds
        guard NSApp.isActive, hubWindow.isKeyWindow,
              hubHost.window === hubWindow, hubHost.bounds.width > 0, hubHost.bounds.height > 0 else {
            throw HubFocusPerformanceError.renderNotReady(index)
        }
        return HubFocusSample(
            transition: index,
            keyAcquisitionMilliseconds: milliseconds(from: startedAt, to: keyedAt),
            renderReadyAfterKeyMilliseconds: milliseconds(from: keyedAt, to: renderedAt),
            mainThreadCPUMilliseconds: try mainThreadCPUMilliseconds() - cpuStartedAt
        )
    }

    private func nextMainRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    private func mainThreadCPUMilliseconds() throws -> Double {
        var value = timespec()
        try #require(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0, "Thread CPU clock unavailable")
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1_000_000
    }

    private func nativeMenus(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { nativeMenus(in: $0) }
    }

    private func waitUntil(_ phase: String, condition: @escaping () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw HubFocusPerformanceError.timeout(phase)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func writeReport(
        samples: [HubFocusSample],
        negativeControl: HubFocusSample,
        injectedDelayMilliseconds: Double,
        hubHost: NSView
    ) throws -> HubFocusReportResult {
        let reportURL = hubFocusReportURL()
        let reportDirectory = reportURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let screenshotURL = reportDirectory.appendingPathComponent(
            "\(reportURL.deletingPathExtension().lastPathComponent).png"
        )
        guard let screenshot = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(hubHost.bounds.width),
            pixelsHigh: Int(hubHost.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw HubFocusPerformanceError.screenshotUnavailable
        }
        hubHost.cacheDisplay(in: hubHost.bounds, to: screenshot)
        guard let screenshotData = screenshot.representation(using: .png, properties: [:]) else {
            throw HubFocusPerformanceError.screenshotUnavailable
        }
        try screenshotData.write(to: screenshotURL, options: .atomic)

        let keySummary = HubFocusSummary(samples.map(\.keyAcquisitionMilliseconds))
        let renderSummary = HubFocusSummary(samples.map(\.renderReadyAfterKeyMilliseconds))
        let mode: HubFocusMode = ProcessInfo.processInfo.environment["PICKY_HUB_FOCUS_PERF_MODE"] == "calibrate"
            ? .calibration
            : .gate
        let threshold = HubFocusThreshold.current
        let gateStatus: HubFocusGateStatus
        if mode == .calibration {
            gateStatus = .calibration
        } else if threshold.accepts(key: keySummary, render: renderSummary) {
            gateStatus = .passed
        } else {
            gateStatus = .failed
        }
        let report = HubFocusReport(
            schemaVersion: 1,
            scenario: "finder-to-isolated-hub-settings",
            mode: mode,
            environment: HubFocusEnvironment.current,
            samples: samples,
            summary: HubFocusReportSummary(
                keyAcquisition: keySummary,
                renderReadyAfterKey: renderSummary,
                totalReady: HubFocusSummary(samples.map { $0.keyAcquisitionMilliseconds + $0.renderReadyAfterKeyMilliseconds }),
                mainThreadCPU: HubFocusSummary(samples.map(\.mainThreadCPUMilliseconds))
            ),
            thresholdProfile: HubFocusThreshold.profile,
            threshold: threshold,
            negativeControl: HubFocusNegativeControl(
                injectedDelayMilliseconds: injectedDelayMilliseconds,
                observedKeyAcquisitionMilliseconds: negativeControl.keyAcquisitionMilliseconds
            ),
            screenshot: screenshotURL.lastPathComponent,
            gateStatus: gateStatus
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("Hub focus performance report: \(reportURL.path)")
        return HubFocusReportResult(
            mode: mode,
            report: report,
            url: reportURL,
            keySummary: keySummary,
            renderSummary: renderSummary
        )
    }

    private func hubFocusReportURL() -> URL {
        if let rawPath = ProcessInfo.processInfo.environment["PICKY_HUB_FOCUS_PERF_REPORT_PATH"], !rawPath.isEmpty {
            return URL(fileURLWithPath: rawPath)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/perf/hub-focus/latest.json")
    }

    private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}

private final class HubFocusTransitionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: UInt64?

    var keyTimestamp: UInt64? {
        lock.withLock { timestamp }
    }

    func beginTransition() {
        lock.withLock { timestamp = nil }
    }

    func recordKeyAcquisition() {
        lock.withLock { timestamp = DispatchTime.now().uptimeNanoseconds }
    }
}

private struct HubFocusSample: Encodable {
    let transition: Int
    let keyAcquisitionMilliseconds: Double
    let renderReadyAfterKeyMilliseconds: Double
    let mainThreadCPUMilliseconds: Double
}

private struct HubFocusSummary: Encodable {
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        medianMilliseconds = sorted[sorted.count / 2]
        p95Milliseconds = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        maxMilliseconds = sorted.last ?? 0
    }
}

private struct HubFocusThreshold: Encodable {
    let keyMedianMilliseconds: Double
    let keyP95Milliseconds: Double
    let keyMaxMilliseconds: Double
    let renderP95Milliseconds: Double

    static var profile: String {
        let environment = ProcessInfo.processInfo.environment
        return environment["PICKY_UI_TEST_SESSION"] == "isolated"
            && environment["PICKY_HUB_FOCUS_PERF_PROFILE"] == "github-hosted"
            ? "github-hosted" : "local"
    }

    // Separate VM budget, not a change to the local reference or key timing.
    // See docs/hub-focus-perf.md for the measured baseline and approval.
    static var current: HubFocusThreshold {
        HubFocusThreshold(
            keyMedianMilliseconds: 100,
            keyP95Milliseconds: 150,
            keyMaxMilliseconds: 250,
            renderP95Milliseconds: profile == "github-hosted" ? 250 : 100
        )
    }

    func accepts(key: HubFocusSummary, render: HubFocusSummary) -> Bool {
        key.medianMilliseconds <= keyMedianMilliseconds
            && key.p95Milliseconds <= keyP95Milliseconds
            && key.maxMilliseconds <= keyMaxMilliseconds
            && render.p95Milliseconds <= renderP95Milliseconds
    }
}

private enum HubFocusMode: String, Encodable {
    case gate
    case calibration
}

private enum HubFocusGateStatus: String, Encodable {
    case passed
    case failed
    case calibration
}

private struct HubFocusEnvironment: Encodable {
    let operatingSystem: String
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let displayCount: Int
    let mainDisplayScale: Double?

    @MainActor static var current: HubFocusEnvironment {
        HubFocusEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            logicalProcessorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            displayCount: NSScreen.screens.count,
            mainDisplayScale: NSScreen.main.map { Double($0.backingScaleFactor) }
        )
    }
}

private struct HubFocusReportSummary: Encodable {
    let keyAcquisition: HubFocusSummary
    let renderReadyAfterKey: HubFocusSummary
    let totalReady: HubFocusSummary
    let mainThreadCPU: HubFocusSummary
}

private struct HubFocusNegativeControl: Encodable {
    let injectedDelayMilliseconds: Double
    let observedKeyAcquisitionMilliseconds: Double
}

private struct HubFocusReport: Encodable {
    let schemaVersion: Int
    let scenario: String
    let mode: HubFocusMode
    let environment: HubFocusEnvironment
    let samples: [HubFocusSample]
    let summary: HubFocusReportSummary
    let thresholdProfile: String
    let threshold: HubFocusThreshold
    let negativeControl: HubFocusNegativeControl
    let screenshot: String
    let gateStatus: HubFocusGateStatus
}

private struct HubFocusReportResult {
    let mode: HubFocusMode
    let report: HubFocusReport
    let url: URL
    let keySummary: HubFocusSummary
    let renderSummary: HubFocusSummary
}

private enum HubFocusPerformanceError: LocalizedError {
    case windowServerUnavailable(String)
    case timeout(String)
    case invalidKeyTimestamp(Int)
    case renderNotReady(Int)
    case screenshotUnavailable
    case sensitivityNotDetected(expectedMilliseconds: Double, observedMilliseconds: Double)
    case latencyBudgetExceeded(
        key: HubFocusSummary,
        render: HubFocusSummary,
        threshold: HubFocusThreshold,
        report: URL
    )
    case calibrationCompleted(URL)

    var errorDescription: String? {
        switch self {
        case .windowServerUnavailable(let details):
            "Hub focus performance is inconclusive: WindowServer is unavailable (\(details))."
        case .timeout(let phase):
            "Hub focus performance is inconclusive: timed out waiting for \(phase)."
        case .invalidKeyTimestamp(let transition):
            "Hub focus performance is inconclusive: transition \(transition) did not emit a valid key-window timestamp."
        case .renderNotReady(let transition):
            "Hub focus performance is inconclusive: Hub render checkpoint \(transition) was unavailable."
        case .screenshotUnavailable:
            "Hub focus performance is inconclusive: could not capture the owned Hub fixture."
        case .sensitivityNotDetected(let expected, let observed):
            "Hub focus performance is inconclusive: injected \(expected) ms, observed \(observed) ms."
        case .latencyBudgetExceeded(let key, let render, let threshold, let report):
            "Hub focus latency gate failed: "
                + latencyDescription(key: key, render: render, threshold: threshold)
                + ". Report: \(report.path)"
        case .calibrationCompleted(let report):
            "Hub focus calibration recorded at \(report.path). It never passes the gate."
        }
    }

    private func latencyDescription(
        key: HubFocusSummary,
        render: HubFocusSummary,
        threshold: HubFocusThreshold
    ) -> String {
        "key median/p95/max \(key.medianMilliseconds)/\(key.p95Milliseconds)/\(key.maxMilliseconds) ms; "
            + "render p95 \(render.p95Milliseconds) ms; limits "
            + "\(threshold.keyMedianMilliseconds)/\(threshold.keyP95Milliseconds)/"
            + "\(threshold.keyMaxMilliseconds)/\(threshold.renderP95Milliseconds) ms"
    }
}
