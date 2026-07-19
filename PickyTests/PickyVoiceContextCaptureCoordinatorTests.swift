//
//  PickyVoiceContextCaptureCoordinatorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyVoiceContextCaptureCoordinatorTests {
    @Test func cancellationAfterScreenCaptureSkipsContextAssembly() async throws {
        var didPrepare = false
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in
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
            screenCapture: { _, _ in
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
            screenCapture: { _, _ in [] },
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
            screenCapture: { scope, maximumDimension in
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

    // MARK: - attachScreenshotsOnlyWhenInked gate

    @Test func attachScreenshotsOnlyWhenInked_offByDefault_keepsScreenshots() async throws {
        let settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        // Sanity: feature is opt-in. If the default flips, this test must be
        // updated together with the matching user manual entry.
        #expect(settings.attachScreenshotsOnlyWhenInked == false)

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, source, _, _ in
                Self.preparedPacket(source: source, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [])
            }
        )

        let result = try await coordinator.captureContext(transcript: "with image", voiceFollowUpSessionID: nil)

        #expect(result?.contextPacket.screenshots.count == 1)
    }

    @Test func attachScreenshotsOnlyWhenInked_onWithoutInk_dropsScreenshots() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.attachScreenshotsOnlyWhenInked = true

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, source, _, _ in
                Self.preparedPacket(source: source, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [])
            }
        )

        let result = try await coordinator.captureContext(transcript: "no ink", voiceFollowUpSessionID: nil)

        #expect(result?.contextPacket.screenshots.isEmpty == true)
        #expect(result?.contextPacket.inkMarks.isEmpty == true)
        // Non-visual fields are untouched.
        #expect(result?.contextPacket.transcript ?? "" == "no ink")
    }

    @Test func attachScreenshotsOnlyWhenInked_onWithInk_keepsScreenshots() async throws {
        var settings = PickySettings.defaults(appSupportRoot: FileManager.default.temporaryDirectory)
        settings.attachScreenshotsOnlyWhenInked = true

        let inkMark = PickyInkMarkContext(
            id: "ink-1",
            source: .text,
            screenId: "screen1",
            points: [PickyCGPoint(x: 10, y: 10), PickyCGPoint(x: 20, y: 20)],
            bounds: PickyCGRect(x: 10, y: 10, width: 10, height: 10),
            strokeWidth: 6,
            opacity: 0.5
        )

        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            settingsProvider: { settings },
            contextPreflightCapture: { Self.preflight() },
            contextPreparer: { _, source, _, _ in
                Self.preparedPacket(source: source, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [inkMark])
            }
        )

        let result = try await coordinator.captureContext(transcript: "with ink", voiceFollowUpSessionID: nil)

        #expect(result?.contextPacket.screenshots.count == 1)
        #expect(result?.contextPacket.inkMarks.count == 1)
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
