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
            screenCapture: {
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
}
