//
//  PickyVoiceContextCaptureCoordinatorTests.swift
//  PickyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyVoiceContextCaptureCoordinatorTests {
    @Test func cancellationAfterScreenCaptureSkipsContextAssembly() async throws {
        var didPrepare = false
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return []
            },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, _, _, _ in
                didPrepare = true
                return Self.preparedPacket(source: "voice", screenshotPaths: [], inkMarks: [])
            }
        )

        let result = try await coordinator.captureContext(transcript: "cancel me", voiceFollowUpSessionID: nil)

        if let result {
            Issue.record("Expected cancelled capture to return nil before assembly, got context \(result.contextPacket.id)")
        }
        #expect(!didPrepare)
    }

    @Test func preflightStartsWhileScreenCaptureIsPending() async throws {
        var didStartPreflight = false
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in
                await Task.yield()
                #expect(didStartPreflight)
                return []
            },
            contextPreflightCapture: {
                didStartPreflight = true
                return Self.preflight()
            },
            contextPreparer: { _, source, _, _ in
                Self.preparedPacket(source: source, screenshotPaths: [], inkMarks: [])
            }
        )

        _ = try await coordinator.prepareContext(source: "voice")
    }

    @Test func preparedCaptureCollectsContextBeforeTranscriptArrives() async throws {
        var preparationCount = 0
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in [] },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, source, _, _ in
                preparationCount += 1
                return Self.preparedPacket(source: source, screenshotPaths: [], inkMarks: [])
            }
        )

        let maybePrepared = try await coordinator.prepareContext(source: "voice")
        let prepared = try #require(maybePrepared)
        #expect(preparationCount == 1)

        let result = try await coordinator.assembleContext(prepared, transcript: "transcript arrived later")

        #expect(result?.contextPacket.transcript == "transcript arrived later")
        #expect(preparationCount == 1)
    }

    @Test func usesConfiguredScreenContextScopeWhenCapturing() async throws {
        var capturedScope: PickyScreenContextScope?
        var capturedMaximumDimension: Int?
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.screenContextScope = .focusedScreen
        settings.screenshotQuality = .onePointFive
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { scope, maximumDimension, _, _, _ in
                capturedScope = scope
                capturedMaximumDimension = maximumDimension
                return []
            },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, source, _, _ in
                Self.preparedPacket(source: source, screenshotPaths: [], inkMarks: [])
            }
        )

        _ = try await coordinator.captureContext(transcript: "look here", voiceFollowUpSessionID: nil)

        #expect(capturedScope == .focusedScreen)
        #expect(capturedMaximumDimension == 1920)
    }

    // MARK: - Per-display attachment filtering

    @Test func attachScreenshotsOnlyWhenInked_offByDefault_keepsScreenshots() async throws {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        #expect(settings.attachScreenshotsOnlyWhenInked == false)
        let capture = Self.capture(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in [capture] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { captures, source, _, _ in
                Self.preparedPacketForCaptures(captures, source: source)
            }
        )

        let result = try await coordinator.captureContext(transcript: "with image", voiceFollowUpSessionID: nil)

        #expect(result?.contextPacket.screenshots.count == 1)
    }

    @Test func attachScreenshotsOnlyWhenInked_onWithoutInk_dropsScreenshotsBeforeAssembly() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.attachScreenshotsOnlyWhenInked = true
        let capture = Self.capture(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var assembledDisplayIDs: [CGDirectDisplayID] = []

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in [capture] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { captures, source, _, _ in
                assembledDisplayIDs = captures.map(\.displayID)
                return Self.preparedPacketForCaptures(captures, source: source)
            }
        )

        let result = try await coordinator.captureContext(transcript: "no ink", voiceFollowUpSessionID: nil)

        #expect(assembledDisplayIDs.isEmpty)
        #expect(result?.contextPacket.screenshots.isEmpty == true)
        #expect(result?.contextPacket.transcript == "no ink")
    }

    @Test func attachScreenshotsOnlyWhenInked_keepsOnlyTheInkedDisplay() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.attachScreenshotsOnlyWhenInked = true
        let first = Self.capture(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = Self.capture(displayID: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        let inkCapture = Self.inkCapture(points: [CGPoint(x: 120, y: 20), CGPoint(x: 140, y: 40)])
        var assembledDisplayIDs: [CGDirectDisplayID] = []

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, _ in [first, second] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { captures, source, _, _ in
                assembledDisplayIDs = captures.map(\.displayID)
                return Self.preparedPacketForCaptures(captures, source: source)
            }
        )

        let result = try await coordinator.captureContext(
            transcript: "two screens",
            source: "text",
            inkCapture: inkCapture
        )

        #expect(assembledDisplayIDs == [2])
        #expect(result?.contextPacket.screenshots.count == 1)
    }

    @Test func includedOverrideKeepsUninkedDisplayAndExcludedOverrideDropsInkedDisplay() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.attachScreenshotsOnlyWhenInked = true
        let included = Self.capture(displayID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let excluded = Self.capture(displayID: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        let inkCapture = Self.inkCapture(points: [CGPoint(x: 120, y: 20), CGPoint(x: 140, y: 40)])
        var capturedOverrides: PickyScreenContextDisplayOverrides = [:]
        var assembledDisplayIDs: [CGDirectDisplayID] = []

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _, _, displayOverrides in
                capturedOverrides = displayOverrides
                return [included, excluded]
            },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { captures, source, _, _ in
                assembledDisplayIDs = captures.map(\.displayID)
                return Self.preparedPacketForCaptures(captures, source: source)
            }
        )
        let displayOverrides: PickyScreenContextDisplayOverrides = [
            1: .included,
            2: .excluded
        ]

        _ = try await coordinator.captureContext(
            transcript: "manual display choices",
            source: "text",
            inkCapture: inkCapture,
            displayOverrides: displayOverrides
        )

        #expect(capturedOverrides == displayOverrides)
        #expect(assembledDisplayIDs == [1])
    }

    private static func capture(
        displayID: CGDirectDisplayID,
        frame: CGRect
    ) -> CompanionScreenCapture {
        CompanionScreenCapture(
            displayID: displayID,
            imageData: Data(),
            label: "Display \(displayID)",
            isCursorScreen: displayID == 1,
            displayWidthInPoints: Int(frame.width),
            displayHeightInPoints: Int(frame.height),
            displayFrame: frame,
            screenshotWidthInPixels: Int(frame.width),
            screenshotHeightInPixels: Int(frame.height),
            cursor: nil
        )
    }

    private static func inkCapture(points: [CGPoint]) -> PickyInkCapture {
        PickyInkCapture(
            id: "ink-capture",
            source: .text,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_001),
            strokes: [
                PickyInkCaptureStroke(
                    id: "stroke",
                    source: .text,
                    points: points.map(PickyCGPoint.init),
                    strokeWidth: 6,
                    opacity: 0.5
                )
            ]
        )
    }

    private static func preparedPacketForCaptures(
        _ captures: [CompanionScreenCapture],
        source: String
    ) -> PickyPreparedContextPacket {
        preparedPacket(
            source: source,
            screenshotPaths: captures.map { "/tmp/display-\($0.displayID).jpg" },
            inkMarks: []
        )
    }

    private static func preflight() -> PickyContextPacketPreflight {
        PickyContextPacketPreflight(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            selectedText: nil,
            warnings: []
        )
    }

    private static func preparedPacket(
        source: String,
        screenshotPaths: [String],
        inkMarks: [PickyInkMarkContext]
    ) -> PickyPreparedContextPacket {
        PickyPreparedContextPacket(
            id: "context-test",
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: screenshotPaths.enumerated().map { index, path in
                PickyScreenshotContext(
                    id: "shot-\(index)",
                    label: "Screen \(index + 1)",
                    path: path,
                    screenId: "screen\(index + 1)",
                    bounds: nil
                )
            },
            inkMarks: inkMarks,
            warnings: []
        )
    }
}
