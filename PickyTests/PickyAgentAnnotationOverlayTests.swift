import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAgentAnnotationOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func resolvesSupportedOverlayShapesFromScreenshotPixels() throws {
        let resolved = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "rect", shape: .rect, x: 200, y: 50, w: 100, h: 100, spotlight: true),
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200, spotlight: false),
            annotation(id: "label", shape: .label, x: 200, y: 100, label: " Save "),
        ]), now: now)

        #expect(resolved.first { $0.id == "rect" }?.rect == CGRect(x: 200, y: 225, width: 50, height: 50))
        #expect(resolved.first { $0.id == "rect" }?.spotlight == true)
        #expect(resolved.first { $0.id == "line" }?.point == CGPoint(x: 100, y: 300))
        #expect(resolved.first { $0.id == "line" }?.endPoint == CGPoint(x: 300, y: 200))
        #expect(resolved.first { $0.id == "line" }?.spotlight == false)
        #expect(resolved.first { $0.id == "label" }?.label == "Save")
        #expect(resolved.allSatisfy { $0.expiresAt == now.addingTimeInterval(66) && $0.pendingTTL == 6 })
    }

    @Test func firstSpeechStartActivatesDeferredAnnotationTTL() {
        let pending = resolvedAnnotation(id: "pending", expiresAt: now.addingTimeInterval(66), pendingTTL: 6)
        let requested = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .append, annotations: [pending]))
        #expect(requested.agentAnnotations.first?.expiresAt == now.addingTimeInterval(66))

        let started = reduce(requested, .speechStarted(text: "Look here.", speechID: UUID(), sourceContextID: "context"))
        #expect(started.agentAnnotations.first?.expiresAt == now.addingTimeInterval(6))
        #expect(started.agentAnnotations.first?.pendingTTL == nil)

        let expired = reduce(started, .agentAnnotationsExpired(now: now.addingTimeInterval(5.9)))
        #expect(expired.agentAnnotations.count == 1)
    }

    @Test func companionManagerAppliesAnnotationOverlayEvent() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "manager-rect", shape: .rect, x: 200, y: 100, w: 40, h: 20),
        ])))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent }

        #expect(manager.agentAnnotations.count == 1)
        #expect(manager.agentAnnotations.first?.id == "manager-rect")
        #expect(manager.agentAnnotations.first?.rect == CGRect(x: 200, y: 240, width: 20, height: 10))
    }

    @Test func clearsAnnotationOverlayWithoutScreenGeometry() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "visible", shape: .rect, x: 200, y: 100, w: 20, h: 20),
        ])))
        try await waitUntil { manager.agentAnnotations.count == 1 }

        manager.applyAgentEvent(.annotationOverlayRequested(PickyAnnotationOverlayRequest(
            id: "annotations-clear",
            mode: .clear,
            annotations: [],
            contextId: nil,
            contextGeneration: nil,
            screenId: nil,
            screenBounds: nil,
            screenshotSize: nil
        )))
        try await waitUntil { manager.agentAnnotations.isEmpty }

        #expect(manager.agentAnnotations.isEmpty)
    }

    @Test func dropsAnnotationOverlayFromAnOlderCaptureGeneration() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "current", shape: .rect, x: 200, y: 100, w: 20, h: 20)],
            contextGeneration: 2
        )))
        try await waitUntil { manager.agentAnnotations.first?.id == "current" }
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "stale", shape: .rect, x: 100, y: 100, w: 20, h: 20)],
            contextGeneration: 1
        )))

        #expect(manager.agentAnnotations.map(\.id) == ["current"])
    }

    @Test func reducerReplacesAppendsExpiresAndClearsAnnotationsForUserInput() {
        let initial = PickyInteractionState()
        let original = resolvedAnnotation(id: "original", expiresAt: now.addingTimeInterval(10))
        let replacement = resolvedAnnotation(id: "original", expiresAt: now.addingTimeInterval(20))
        let additional = resolvedAnnotation(id: "additional", expiresAt: now.addingTimeInterval(5))

        let replaced = reduce(initial, .agentAnnotationsRequested(mode: .replace, annotations: [original, additional]))
        #expect(replaced.agentAnnotations.map(\.id) == ["original", "additional"])
        #expect(replaced.overlay == .visible(reason: [.activeAgentAnnotations, .activePointerAnimation]))

        let appended = reduce(replaced, .agentAnnotationsRequested(mode: .append, annotations: [replacement]))
        #expect(appended.agentAnnotations.count == 2)
        #expect(appended.agentAnnotations.first { $0.id == "original" }?.expiresAt == now.addingTimeInterval(20))

        let expired = reduce(appended, .agentAnnotationsExpired(now: now.addingTimeInterval(6)))
        #expect(expired.agentAnnotations.map(\.id) == ["original"])

        let clearedForInput = reduce(expired, .agentAnnotationsClearedForUserInput)
        #expect(clearedForInput.agentAnnotations.isEmpty)
        // User input ends the turn: the annotation buddy springs back to the cursor,
        // so its pointer overlay stays active until the fly-back animation finishes.
        #expect(clearedForInput.overlay == .visible(reason: [.activePointerAnimation]))
    }

    @Test func reducerBoundsAppendedAnnotationsAndClearsThemForCLIInput() {
        let existing = (0..<PickyInteractionReducer.maximumAgentAnnotationCount)
            .map { resolvedAnnotation(id: "existing-\($0)", expiresAt: now.addingTimeInterval(10)) }
        let initial = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .replace, annotations: existing))
        let appended = reduce(initial, .agentAnnotationsRequested(mode: .append, annotations: [
            resolvedAnnotation(id: "new", expiresAt: now.addingTimeInterval(10)),
        ]))

        #expect(appended.agentAnnotations.count == PickyInteractionReducer.maximumAgentAnnotationCount)
        #expect(!appended.agentAnnotations.contains(where: { $0.id == "existing-0" }))
        #expect(appended.agentAnnotations.contains(where: { $0.id == "new" }))

        let cliContext = PickyContextPacket(
            id: "cli-context",
            source: "cli",
            capturedAt: now,
            transcript: "next",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
        let clearedForCLI = reduce(appended, .externalContextCaptured(inputID: UUID(), text: "next", context: cliContext))
        #expect(clearedForCLI.agentAnnotations.isEmpty)
    }

    @Test func roughGeometryIsStableForAnAnnotationIDAndVariesAcrossIDs() {
        let first = PickyAnnotationRoughGeometry.linePaths(
            id: "save-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )
        let repeated = PickyAnnotationRoughGeometry.linePaths(
            id: "save-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )
        let other = PickyAnnotationRoughGeometry.linePaths(
            id: "cancel-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )

        #expect(first == repeated)
        #expect(first != other)
    }

    @Test func rectLabelsAnchorAboveTheOutlineInsteadOfCoveringItsStroke() {
        let annotation = PickyAgentAnnotation(
            id: "save-area",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 20, y: 30, width: 40, height: 20),
            label: "Save",
            expiresAt: now
        )

        let anchor = PickyAnnotationLabelGeometry.outlineAnchor(for: annotation, screenFrame: annotation.displayFrame)

        #expect(anchor == CGPoint(x: 20, y: 36))
    }

    @Test func spotlightMaskUsesShapeMatchedHolesAndOmitsPlainAnnotations() {
        let screenFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let annotations = [
            PickyAgentAnnotation(
                id: "rect-hole",
                shape: .rect,
                displayFrame: screenFrame,
                rect: CGRect(x: 60, y: 30, width: 20, height: 10),
                spotlight: true,
                label: nil,
                expiresAt: now
            ),
            PickyAgentAnnotation(
                id: "line-hole",
                shape: .line,
                displayFrame: screenFrame,
                point: CGPoint(x: 20, y: 20),
                endPoint: CGPoint(x: 40, y: 50),
                spotlight: true,
                label: nil,
                expiresAt: now
            ),
            PickyAgentAnnotation(
                id: "plain-rect",
                shape: .rect,
                displayFrame: screenFrame,
                rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                label: nil,
                expiresAt: now
            ),
        ]

        let holes = PickyAnnotationSpotlightMaskGeometry.holes(for: annotations, screenFrame: screenFrame)

        #expect(holes == [
            .roundedRect(CGRect(x: 52, y: 52, width: 36, height: 26), cornerRadius: 6),
            .rect(CGRect(x: 8, y: 38, width: 44, height: 54)),
        ])
        #expect(PickyAnnotationSpotlightMaskGeometry.holes(for: [annotations[2]], screenFrame: screenFrame).isEmpty)
        #expect(PickyAnnotationSpotlightMaskGeometry.dimmingOpacity == 0.38)
    }

    @Test func decodesAnnotationOverlayProtocolEvent() throws {
        let json = """
        {
          "id":"event-annotations-001",
          "protocolVersion":"2026-07-17",
          "timestamp":"2026-07-17T00:00:00.000Z",
          "type":"annotationOverlayRequested",
          "request":{
            "id":"annotations-001","mode":"append","annotations":[{"id":"line-1","shape":"line","x1":0,"y1":0,"x2":10,"y2":10,"spotlight":true}],
            "screenBounds":{"x":0,"y":0,"width":100,"height":100},"screenshotSize":{"width":100,"height":100}
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .annotationOverlayRequested(let eventRequest) = envelope.event else {
            Issue.record("Expected annotationOverlayRequested")
            return
        }
        #expect(eventRequest.mode == .append)
        #expect(eventRequest.annotations.first?.shape == .line)
        #expect(eventRequest.annotations.first?.spotlight == true)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !predicate() {
            guard Date() < deadline else {
                throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: "test", field: "projection timeout")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func reduce(_ state: PickyInteractionState, _ event: PickyInteractionEvent) -> PickyInteractionState {
        PickyInteractionReducer.reduce(
            state: state,
            envelope: PickyInteractionEnvelope(id: UUID(), occurredAt: now, event: event, correlation: .init(source: .agent))
        ).state
    }

    private func request(
        annotations: [PickyAnnotationOverlayAnnotation],
        mode: PickyAnnotationOverlayMode = .replace,
        contextGeneration: Int? = nil
    ) -> PickyAnnotationOverlayRequest {
        PickyAnnotationOverlayRequest(
            id: "annotations-request",
            mode: mode,
            annotations: annotations,
            contextId: "context",
            contextGeneration: contextGeneration,
            screenId: "screen",
            screenBounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 400, height: 200)
        )
    }

    private func annotation(
        id: String,
        shape: PickyAnnotationOverlayShape,
        x: Double? = nil, y: Double? = nil,
        w: Double? = nil, h: Double? = nil, x1: Double? = nil, y1: Double? = nil, x2: Double? = nil, y2: Double? = nil,
        spotlight: Bool? = nil, label: String? = nil
    ) -> PickyAnnotationOverlayAnnotation {
        PickyAnnotationOverlayAnnotation(id: id, shape: shape, x: x, y: y, w: w, h: h, x1: x1, y1: y1, x2: x2, y2: y2, spotlight: spotlight, label: label, ttlMs: nil, clamped: nil)
    }

    private func resolvedAnnotation(id: String, expiresAt: Date, pendingTTL: TimeInterval? = nil) -> PickyAgentAnnotation {
        PickyAgentAnnotation(id: id, shape: .rect, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: CGRect(x: 40, y: 40, width: 20, height: 20), label: nil, expiresAt: expiresAt, pendingTTL: pendingTTL)
    }
}
