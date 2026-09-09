//
//  PickyInkOverlayStore.swift
//  Picky
//

import Combine
import Foundation

/// Owns ink observation without invalidating unrelated CompanionManager views.
/// Capture consumers see every changed snapshot; only drawing presentation is coalesced.
@MainActor
final class PickyInkOverlayStore: ObservableObject {
    @Published private(set) var state: PickyInkOverlayState = .inactive

    /// Capture and onboarding must never read a delayed display snapshot.
    var latestState: PickyInkOverlayState { captureSubject.value }
    var captureStates: AnyPublisher<PickyInkOverlayState, Never> {
        captureSubject.eraseToAnyPublisher()
    }

    private let captureSubject = CurrentValueSubject<PickyInkOverlayState, Never>(.inactive)
    private let scheduler: any PickyInteractionTimerScheduling
    private var pendingFrameID: UUID?
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    init(scheduler: (any PickyInteractionTimerScheduling)? = nil) {
        self.scheduler = scheduler ?? PickyTaskInteractionTimerScheduler()
    }

    /// Returns whether capture activation changed, for the host's visibility effect.
    @discardableResult
    func update(_ next: PickyInkOverlayState) -> Bool {
        let previous = latestState
        guard previous != next else { return false }
        captureSubject.send(next)

        // Begin/end and threshold feedback are immediate. A delayed frame from
        // the previous capture must not revive ink after cancellation or retry.
        if previous.isActive != next.isActive || previous.source != next.source
            || previous.didCrossThreshold != next.didCrossThreshold {
            pendingFrameID = nil
            publish(next)
            return previous.isActive != next.isActive
        }
        guard pendingFrameID == nil else { return false }
        let frameID = UUID()
        pendingFrameID = frameID
        scheduler.schedule(after: Self.frameInterval) { [weak self] in
            guard let self, self.pendingFrameID == frameID else { return }
            self.pendingFrameID = nil
            self.publish(self.latestState)
        }
        return false
    }

    private func publish(_ next: PickyInkOverlayState) {
        guard state != next else { return }
        state = next
    }
}
