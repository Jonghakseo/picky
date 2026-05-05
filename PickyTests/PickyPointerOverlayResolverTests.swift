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
            coordinateSpace: .screenshotPixel,
            screenBounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 400, height: 200)
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation == CGPoint(x: 200, y: 275))
        #expect(target.displayFrame == CGRect(x: 100, y: 200, width: 200, height: 100))
        #expect(target.duration == PickyPointerOverlayResolver.defaultDuration)
    }

    @Test func resolvesSecondaryScreenScreenshotPixelCoordinates() throws {
        let request = request(
            x: 405,
            y: 180,
            coordinateSpace: .screenshotPixel,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 1728, height: 1117),
            screenshotSize: PickyPointerScreenshotSize(width: 1280, height: 827)
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation.x.isApproximatelyEqual(to: 546.75))
        #expect(target.screenLocation.y.isApproximatelyEqual(to: 873.88, absoluteTolerance: 0.01))
        #expect(target.displayFrame == CGRect(x: 0, y: 0, width: 1728, height: 1117))
    }

    @Test func clampsCoordinatesAndDuration() throws {
        let request = request(
            x: 999,
            y: -10,
            coordinateSpace: .displayPoint,
            label: "  Try Eleven v3  ",
            durationMs: 99_999,
            confidence: 1.4,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 300, height: 400),
            screenshotSize: nil
        )

        let target = try PickyPointerOverlayResolver.resolve(request)

        #expect(target.screenLocation == CGPoint(x: 300, y: 400))
        #expect(target.duration == PickyPointerOverlayResolver.maximumDuration)
        #expect(target.bubbleText == "Try Eleven v3 · 100%")
    }

    @Test func rejectsScreenshotPixelsWithoutScreenshotSize() {
        let request = request(
            x: 10,
            y: 10,
            coordinateSpace: .screenshotPixel,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 300, height: 400),
            screenshotSize: nil
        )

        #expect(throws: PickyPointerOverlayResolveError.invalidScreenshotSize) {
            _ = try PickyPointerOverlayResolver.resolve(request)
        }
    }

    @Test func companionManagerAppliesPointerOverlayEventWithoutSpeaking() {
        let manager = CompanionManager(agentClient: FakePointerClient(), selectionStore: FakePointerSelectionStore())
        let eventRequest = request(
            x: 50,
            y: 25,
            coordinateSpace: .displayPoint,
            label: "Settings",
            durationMs: 1_500,
            confidence: 0.75,
            screenBounds: PickyCGRect(x: 10, y: 20, width: 100, height: 100),
            screenshotSize: nil
        )

        manager.applyAgentEvent(.pointerOverlayRequested(eventRequest))

        #expect(manager.detectedElementScreenLocation == CGPoint(x: 60, y: 95))
        #expect(manager.detectedElementDisplayFrame == CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(manager.detectedElementBubbleText == "Settings · 75%")
        #expect(manager.detectedElementDisplayDuration == 1.5)
        #expect(manager.detectedElementHighlightKind == .screenElement)
        #expect(manager.detectedElementTargetFrame == nil)
        #expect(manager.voiceState == .idle)
    }

    @Test func clearDetectedElementResetsAllHighlightFields() {
        let manager = CompanionManager(agentClient: FakePointerClient(), selectionStore: FakePointerSelectionStore())
        manager.applyAgentEvent(.pointerOverlayRequested(request(
            x: 50,
            y: 25,
            coordinateSpace: .displayPoint,
            label: "Reload",
            durationMs: 1_000,
            confidence: 0.5,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 200, height: 200),
            screenshotSize: nil
        )))
        #expect(manager.detectedElementHighlightKind == .screenElement)

        manager.clearDetectedElementLocation()

        #expect(manager.detectedElementScreenLocation == nil)
        #expect(manager.detectedElementDisplayFrame == nil)
        #expect(manager.detectedElementBubbleText == nil)
        #expect(manager.detectedElementDisplayDuration == nil)
        #expect(manager.detectedElementTargetFrame == nil)
        #expect(manager.detectedElementHighlightKind == nil)
    }

    private func request(
        x: Double,
        y: Double,
        coordinateSpace: PickyPointerCoordinateSpace,
        label: String? = nil,
        durationMs: Int? = nil,
        confidence: Double? = nil,
        screenBounds: PickyCGRect,
        screenshotSize: PickyPointerScreenshotSize?
    ) -> PickyPointerOverlayRequest {
        PickyPointerOverlayRequest(
            id: "pointer-test",
            contextId: "context-test",
            sourceSessionId: "session-test",
            screenId: "screen1",
            screenIndex: 1,
            x: x,
            y: y,
            coordinateSpace: coordinateSpace,
            label: label,
            durationMs: durationMs,
            confidence: confidence,
            dryRun: false,
            clamped: nil,
            screenBounds: screenBounds,
            screenshotSize: screenshotSize
        )
    }
}

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
}

private extension CGFloat {
    func isApproximatelyEqual(to expected: CGFloat, absoluteTolerance: CGFloat = 0.001) -> Bool {
        abs(self - expected) <= absoluteTolerance
    }
}
