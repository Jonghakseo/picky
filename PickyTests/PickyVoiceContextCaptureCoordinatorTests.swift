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
        var didAssemble = false
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return []
            },
            contextAssembler: { _, _, _, _ in
                didAssemble = true
                return PickyContextPacket(
                    id: "context-cancelled",
                    source: "voice",
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    transcript: "cancel me",
                    selectedText: nil,
                    cwd: nil,
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    screenshots: [],
                    warnings: []
                )
            }
        )

        let result = try await coordinator.captureContext(transcript: "cancel me", voiceFollowUpSessionID: nil)

        if let result {
            Issue.record("Expected cancelled capture to return nil before assembly, got context \(result.contextPacket.id)")
        }
        #expect(!didAssemble)
    }

    @Test func preparedCaptureDefersTranscriptAssemblyUntilSTTCompletes() async throws {
        var assembledTranscripts: [String] = []
        let coordinator = PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            contextAssembler: { _, source, transcript, _ in
                assembledTranscripts.append(transcript)
                return Self.stubPacket(source: source, transcript: transcript, screenshotPaths: [], inkMarks: [])
            }
        )

        let maybePrepared = try await coordinator.prepareContext(source: "voice")
        let prepared = try #require(maybePrepared)
        #expect(assembledTranscripts.isEmpty)

        let result = try await coordinator.assembleContext(prepared, transcript: "transcript arrived later")

        #expect(result?.contextPacket.transcript == "transcript arrived later")
        #expect(assembledTranscripts == ["transcript arrived later"])
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
            contextAssembler: { _, source, transcript, _ in
                PickyContextPacket(
                    id: "context-focused-screen",
                    source: source,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    transcript: transcript,
                    selectedText: nil,
                    cwd: nil,
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    screenshots: [],
                    warnings: []
                )
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
            contextAssembler: { _, source, transcript, _ in
                Self.stubPacket(source: source, transcript: transcript, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [])
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
            contextAssembler: { _, source, transcript, _ in
                Self.stubPacket(source: source, transcript: transcript, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [])
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
            contextAssembler: { _, source, transcript, _ in
                Self.stubPacket(source: source, transcript: transcript, screenshotPaths: ["/tmp/shot-1.jpg"], inkMarks: [inkMark])
            }
        )

        let result = try await coordinator.captureContext(transcript: "with ink", voiceFollowUpSessionID: nil)

        #expect(result?.contextPacket.screenshots.count == 1)
        #expect(result?.contextPacket.inkMarks.count == 1)
    }

    private static func stubPacket(
        source: String,
        transcript: String,
        screenshotPaths: [String],
        inkMarks: [PickyInkMarkContext]
    ) -> PickyContextPacket {
        PickyContextPacket(
            id: "context-test",
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: transcript,
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
