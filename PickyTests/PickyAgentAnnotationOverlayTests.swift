import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAgentAnnotationOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func resolvesEveryV1ShapeFromScreenshotPixels() throws {
        let resolved = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "target", shape: .target, x: 200, y: 50, r: 20),
            annotation(id: "circle", shape: .circle, x: 100, y: 100, rx: 40, ry: 20),
            annotation(id: "rect", shape: .rect, x: 200, y: 50, w: 100, h: 100),
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200),
            annotation(id: "spotlight", shape: .spotlight, x: 200, y: 100, r: 40, spotlightShape: .circle),
            annotation(id: "label", shape: .label, x: 200, y: 100, label: " Save "),
        ]), now: now)

        #expect(resolved.first { $0.id == "target" }?.point == CGPoint(x: 200, y: 275))
        #expect(resolved.first { $0.id == "target" }?.radius == 10)
        #expect(resolved.first { $0.id == "circle" }?.radiusX == 20)
        #expect(resolved.first { $0.id == "circle" }?.radiusY == 10)
        #expect(resolved.first { $0.id == "rect" }?.rect == CGRect(x: 200, y: 225, width: 50, height: 50))
        #expect(resolved.first { $0.id == "line" }?.point == CGPoint(x: 100, y: 300))
        #expect(resolved.first { $0.id == "line" }?.endPoint == CGPoint(x: 300, y: 200))
        #expect(resolved.first { $0.id == "spotlight" }?.spotlightShape == .circle)
        #expect(resolved.first { $0.id == "label" }?.label == "Save")
        #expect(resolved.allSatisfy { $0.expiresAt == now.addingTimeInterval(6) })
    }

    @Test func companionManagerAppliesAnnotationOverlayEvent() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "manager-target", shape: .target, x: 200, y: 100, r: 20),
        ])))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent }

        #expect(manager.agentAnnotations.count == 1)
        #expect(manager.agentAnnotations.first?.id == "manager-target")
        #expect(manager.agentAnnotations.first?.point == CGPoint(x: 200, y: 250))
        #expect(manager.agentAnnotations.first?.radius == 10)
    }

    @Test func reducerReplacesAppendsExpiresAndClearsAnnotationsForUserInput() {
        let initial = PickyInteractionState()
        let original = resolvedAnnotation(id: "original", expiresAt: now.addingTimeInterval(10), zOrder: 1)
        let replacement = resolvedAnnotation(id: "original", expiresAt: now.addingTimeInterval(20), zOrder: 2)
        let additional = resolvedAnnotation(id: "additional", expiresAt: now.addingTimeInterval(5), zOrder: 0)

        let replaced = reduce(initial, .agentAnnotationsRequested(mode: .replace, annotations: [original, additional]))
        #expect(replaced.agentAnnotations.map(\.id) == ["additional", "original"])
        #expect(replaced.overlay == .visible(reason: [.activeAgentAnnotations]))

        let appended = reduce(replaced, .agentAnnotationsRequested(mode: .append, annotations: [replacement]))
        #expect(appended.agentAnnotations.count == 2)
        #expect(appended.agentAnnotations.first { $0.id == "original" }?.expiresAt == now.addingTimeInterval(20))

        let expired = reduce(appended, .agentAnnotationsExpired(now: now.addingTimeInterval(6)))
        #expect(expired.agentAnnotations.map(\.id) == ["original"])

        let clearedForInput = reduce(expired, .agentAnnotationsClearedForUserInput)
        #expect(clearedForInput.agentAnnotations.isEmpty)
        #expect(clearedForInput.overlay == .hidden)
    }

    @Test func decodesAnnotationOverlayProtocolEvent() throws {
        let json = """
        {
          "id":"event-annotations-001",
          "protocolVersion":"2026-07-17",
          "timestamp":"2026-07-17T00:00:00.000Z",
          "type":"annotationOverlayRequested",
          "request":{
            "id":"annotations-001","mode":"append","annotations":[{"id":"line-1","shape":"line","x1":0,"y1":0,"x2":10,"y2":10}],
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

    private func request(annotations: [PickyAnnotationOverlayAnnotation]) -> PickyAnnotationOverlayRequest {
        PickyAnnotationOverlayRequest(
            id: "annotations-request",
            mode: .replace,
            annotations: annotations,
            contextId: "context",
            screenId: "screen",
            screenBounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 400, height: 200)
        )
    }

    private func annotation(
        id: String,
        shape: PickyAnnotationOverlayShape,
        x: Double? = nil, y: Double? = nil, r: Double? = nil, rx: Double? = nil, ry: Double? = nil,
        w: Double? = nil, h: Double? = nil, x1: Double? = nil, y1: Double? = nil, x2: Double? = nil, y2: Double? = nil,
        spotlightShape: PickyAnnotationSpotlightShape? = nil, label: String? = nil
    ) -> PickyAnnotationOverlayAnnotation {
        PickyAnnotationOverlayAnnotation(id: id, shape: shape, screenId: nil, x: x, y: y, r: r, rx: rx, ry: ry, w: w, h: h, x1: x1, y1: y1, x2: x2, y2: y2, spotlightShape: spotlightShape, label: label, ttlMs: nil, zOrder: nil, clamped: nil)
    }

    private func resolvedAnnotation(id: String, expiresAt: Date, zOrder: Double) -> PickyAgentAnnotation {
        PickyAgentAnnotation(id: id, shape: .target, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), point: CGPoint(x: 50, y: 50), radius: 10, spotlightShape: nil, label: nil, expiresAt: expiresAt, zOrder: zOrder)
    }
}
