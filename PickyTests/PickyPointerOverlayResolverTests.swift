//
//  PickyPointerOverlayResolverTests.swift
//  PickyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyPointerOverlayResolverTests {
    @Test func convertsScreenshotPixelsToGlobalAppKitPoint() throws {
        let request = request(
            x: 200,
            y: 50,
            screenBounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 400, height: 200)
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation == CGPoint(x: 200, y: 275))
        #expect(target.displayFrame == CGRect(x: 100, y: 200, width: 200, height: 100))
        #expect(target.duration == 1.0)
    }

    @Test func resolvesSecondaryScreenScreenshotPixelCoordinates() throws {
        let request = request(
            x: 405,
            y: 180,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 1728, height: 1117),
            screenshotSize: PickyPointerScreenshotSize(width: 1280, height: 827)
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation.x.isApproximatelyEqual(to: 546.75))
        #expect(target.screenLocation.y.isApproximatelyEqual(to: 873.88, absoluteTolerance: 0.01))
        #expect(target.displayFrame == CGRect(x: 0, y: 0, width: 1728, height: 1117))
    }

    @Test func clampsCoordinatesAndNormalizesLabel() throws {
        let request = request(
            x: 999,
            y: -10,
            label: "  Try Eleven v3  ",
            screenBounds: PickyCGRect(x: 0, y: 0, width: 300, height: 400),
            screenshotSize: PickyPointerScreenshotSize(width: 600, height: 800)
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation == CGPoint(x: 300, y: 400))
        #expect(target.duration == 1.0)
        #expect(target.bubbleText == "Try Eleven v3")
    }

    @Test func rejectsInvalidScreenshotSize() {
        let request = request(
            x: 10,
            y: 10,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 300, height: 400),
            screenshotSize: PickyPointerScreenshotSize(width: 0, height: 200)
        )

        #expect(throws: PickyPointerOverlayResolveError.invalidScreenshotSize) {
            _ = try PickyPointerOverlayResolver.resolve(request)
        }
    }

    @Test func companionManagerAppliesPointerOverlayEventWithoutSpeaking() async throws {
        let manager = CompanionManager(agentClient: FakePointerClient(), selectionStore: FakePointerSelectionStore())
        let eventRequest = request(
            x: 50,
            y: 25,
            label: "Settings",
            screenBounds: PickyCGRect(x: 10, y: 20, width: 100, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 100, height: 100)
        )

        manager.applyAgentEvent(.pointerOverlayRequested(eventRequest))
        // The interaction coordinator drains events asynchronously, so the pointer
        // highlight fields land on the next MainActor tick.
        try await waitUntil { manager.detectedElementScreenLocation == CGPoint(x: 60, y: 95) }

        #expect(manager.detectedElementScreenLocation == CGPoint(x: 60, y: 95))
        #expect(manager.detectedElementDisplayFrame == CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(manager.detectedElementBubbleText == "Settings")
        #expect(manager.detectedElementDisplayDuration == 1.0)
        #expect(manager.voiceState == .idle)
    }

    @Test func dropsPointerOverlayFromAnOlderCaptureGeneration() async throws {
        let manager = CompanionManager(agentClient: FakePointerClient(), selectionStore: FakePointerSelectionStore())
        manager.applyAgentEvent(.pointerOverlayRequested(request(
            x: 50,
            y: 25,
            label: "Current",
            contextGeneration: 2,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 100, height: 100)
        )))
        try await waitUntil { manager.detectedElementBubbleText == "Current" }
        // The stale (older-generation) request is dropped synchronously before dispatch.
        manager.applyAgentEvent(.pointerOverlayRequested(request(
            x: 10,
            y: 10,
            label: "Stale",
            contextGeneration: 1,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 100, height: 100)
        )))

        #expect(manager.detectedElementBubbleText == "Current")
        #expect(manager.detectedElementScreenLocation == CGPoint(x: 50, y: 75))
    }

    @Test func clearDetectedElementResetsAllPointerFields() async throws {
        let manager = CompanionManager(agentClient: FakePointerClient(), selectionStore: FakePointerSelectionStore())
        manager.applyAgentEvent(.pointerOverlayRequested(request(
            x: 50,
            y: 25,
            label: "Reload",
            screenBounds: PickyCGRect(x: 0, y: 0, width: 200, height: 200),
            screenshotSize: PickyPointerScreenshotSize(width: 200, height: 200)
        )))
        try await waitUntil { manager.detectedElementScreenLocation != nil }

        manager.clearDetectedElementLocation()

        #expect(manager.detectedElementScreenLocation == nil)
        #expect(manager.detectedElementDisplayFrame == nil)
        #expect(manager.detectedElementBubbleText == nil)
        #expect(manager.detectedElementDisplayDuration == nil)
    }

    private func request(
        x: Double,
        y: Double,
        label: String? = nil,
        contextGeneration: Int? = nil,
        screenBounds: PickyCGRect,
        screenshotSize: PickyPointerScreenshotSize
    ) -> PickyPointerOverlayRequest {
        PickyPointerOverlayRequest(
            id: "pointer-test",
            contextId: "context-test",
            contextGeneration: contextGeneration,
            screenId: "screen1",
            x: x,
            y: y,
            label: label,
            clamped: nil,
            screenBounds: screenBounds,
            screenshotSize: screenshotSize
        )
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !predicate() {
            guard Date() < deadline else { throw PointerOverlayDrainTimeout() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private struct PointerOverlayDrainTimeout: Error {}

private final class FakePointerClient: PickyAgentClient {
    let events: AsyncStream<PickyClientEvent> = AsyncStream { _ in }
    func connect() async {}
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt { PickyAgentSubmissionReceipt(sessionID: "session", message: "") }
    func send(_ command: PickyCommandEnvelope) async throws {}
    func disconnect() {}
}

private final class FakePointerSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky: Bool = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
}

private extension CGFloat {
    func isApproximatelyEqual(to expected: CGFloat, absoluteTolerance: CGFloat = 0.001) -> Bool {
        abs(self - expected) <= absoluteTolerance
    }
}
