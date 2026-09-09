import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
private final class InkFrameScheduler: PickyInteractionTimerScheduling {
    private var operations: [@MainActor () -> Void] = []

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        operations.append(operation)
    }

    func advanceFrame() {
        let ready = operations
        operations.removeAll()
        for operation in ready { operation() }
    }
}

@MainActor
struct PickyInkOverlayStoreTests {
    @Test func burstPublishesOneDisplaySnapshotWithoutLosingCapturePoints() {
        let scheduler = InkFrameScheduler()
        let store = PickyInkOverlayStore(scheduler: scheduler)
        let first = drawing(points: [CGPoint(x: 0, y: 0)])
        store.update(first)
        var captureStates: [PickyInkOverlayState] = []
        var displayStates: [PickyInkOverlayState] = []
        let captureObservation = store.captureStates.dropFirst().sink { captureStates.append($0) }
        let displayObservation = store.$state.dropFirst().sink { displayStates.append($0) }
        var points = [CGPoint(x: 0, y: 0)]
        for x in 1...100 {
            points.append(CGPoint(x: x * 4, y: 20))
            store.update(drawing(points: points))
        }

        #expect(captureStates.count == 100)
        #expect(store.latestState.strokes.first?.points == points)
        #expect(displayStates.isEmpty)
        scheduler.advanceFrame()
        #expect(displayStates.count == 1)
        #expect(displayStates.first?.strokes.first?.points == points)
        #expect(store.state == store.latestState)
        withExtendedLifetime((captureObservation, displayObservation)) {}
    }

    @Test func cancellationClearsInkImmediatelyAndPendingFrameCannotReviveIt() {
        let scheduler = InkFrameScheduler()
        let store = PickyInkOverlayStore(scheduler: scheduler)
        store.update(drawing(points: [CGPoint(x: 0, y: 0)]))
        store.update(drawing(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]))
        store.update(.inactive)

        #expect(store.state == .inactive)
        #expect(store.latestState == .inactive)
        scheduler.advanceFrame()
        #expect(store.state == .inactive)
    }

    @Test func staleFrameCannotOverwriteANewCapture() {
        let scheduler = InkFrameScheduler()
        let store = PickyInkOverlayStore(scheduler: scheduler)
        store.update(drawing(points: [CGPoint(x: 0, y: 0)]))
        store.update(drawing(points: [CGPoint(x: 40, y: 10)]))
        store.update(.inactive)
        let restarted = drawing(points: [CGPoint(x: 200, y: 300)], source: .voice)
        store.update(restarted)

        scheduler.advanceFrame()
        #expect(store.state == restarted)
        #expect(store.latestState == restarted)
    }

    @Test func thresholdFeedbackAndCompletedStrokeAreNotLostBetweenFrames() {
        let scheduler = InkFrameScheduler()
        let store = PickyInkOverlayStore(scheduler: scheduler)
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]
        store.update(drawing(points: [], crossedThreshold: false))
        var crossedThreshold = false
        let observation = store.captureStates.sink {
            if $0.didCrossThreshold && !$0.strokes.isEmpty { crossedThreshold = true }
        }
        let crossing = drawing(points: points)
        store.update(crossing)
        #expect(store.state == crossing)
        let completed = drawing(points: points, crossedThreshold: false)
        store.update(completed)

        #expect(crossedThreshold)
        #expect(store.state == completed)
        scheduler.advanceFrame()
        #expect(store.state.strokes.first?.points == points)
        withExtendedLifetime(observation) {}
    }

    @Test func unchangedPointerSnapshotDoesNotInvalidateDisplay() {
        let scheduler = InkFrameScheduler()
        let store = PickyInkOverlayStore(scheduler: scheduler)
        let snapshot = drawing(points: [CGPoint(x: 0, y: 0)])
        store.update(snapshot)
        var displayUpdates = 0
        let observation = store.objectWillChange.sink { displayUpdates += 1 }
        for _ in 0..<100 { store.update(snapshot) }
        scheduler.advanceFrame()
        #expect(displayUpdates == 0)
        withExtendedLifetime(observation) {}
    }

    private func drawing(
        points: [CGPoint],
        source: PickyInkCaptureSource = .text,
        crossedThreshold: Bool = true
    ) -> PickyInkOverlayState {
        PickyInkOverlayState(
            isActive: true, source: source, virtualCursorGlobalPoint: points.last,
            strokes: points.isEmpty ? [] : [PickyInkOverlayStroke(
                id: "stroke", points: points, strokeWidth: 8, opacity: 0.34
            )],
            didCrossThreshold: crossedThreshold,
            thresholdFeedbackGlobalPoint: crossedThreshold ? points.last : nil,
            cursorTrailPoints: []
        )
    }
}
