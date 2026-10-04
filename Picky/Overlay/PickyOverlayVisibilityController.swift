//
//  PickyOverlayVisibilityController.swift
//  Picky
//
//  Single owner of cursor overlay visibility: which reasons currently hold the
//  overlay up, whether it is on screen, and the transient-hide timer. Decisions
//  come from `PickyOverlayVisibilityPolicy`; window lifecycle runs through the
//  injected effects so this type never depends on CompanionManager.
//

import Combine
import Foundation

/// Window lifecycle hooks. Production wires these to `OverlayWindowManager`;
/// unit tests leave them at `.none` so no NSWindow is created.
@MainActor
struct PickyOverlayWindowEffects {
    var show: () -> Void
    var hide: () -> Void
    var fadeOutAndHide: () -> Void

    static let none = PickyOverlayWindowEffects(show: {}, hide: {}, fadeOutAndHide: {})
}

@MainActor
final class PickyOverlayVisibilityController: ObservableObject {
    /// Whether the blue cursor overlay is currently on screen.
    @Published private(set) var isOverlayVisible: Bool = false
    @Published private(set) var overlayVisibilityReasons: Set<PickyOverlayReason> = []

    /// Reasons driven directly by Companion state (settings, permissions, ink,
    /// voice hold, screen-context target).
    private var localReasons: Set<PickyOverlayReason> = []
    /// Reasons projected by the interaction reducer.
    private var interactionReasons: Set<PickyOverlayReason> = []
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// interacts again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// Assigned once by the owner after construction, because showing the
    /// overlay needs a reference to the fully initialized CompanionManager.
    var windowEffects: PickyOverlayWindowEffects = .none

    var hasActiveTransientBlocker: Bool {
        PickyOverlayVisibilityPolicy.blocksTransientHide(overlayVisibilityReasons)
    }

    func setLocalReason(_ reason: PickyOverlayReason, visible: Bool) {
        if visible {
            localReasons.insert(reason)
        } else {
            localReasons.remove(reason)
        }
        sync()
    }

    func applyInteractionPhase(_ phase: PickyOverlayPhase) {
        interactionReasons = PickyOverlayVisibilityPolicy.interactionReasons(for: phase)
        sync()
    }

    /// Drops every reason at once (cursor preference turned off, transient hide
    /// elapsed, main turn settled).
    func clearAllReasons(animatedHide: Bool) {
        localReasons.removeAll()
        interactionReasons.removeAll()
        sync(animatedHide: animatedHide)
    }

    func cancelTransientHide() {
        transientHideTask?.cancel()
        transientHideTask = nil
    }

    /// Waits for the pointing animation and every transient blocker to finish,
    /// pauses one second, then fades the overlay out. Replaces any pending hide.
    func scheduleTransientHide(
        whilePointingAnimationActive isPointingAnimationActive: @escaping () -> Bool
    ) {
        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while isPointingAnimationActive() || hasActiveTransientBlocker {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !hasActiveTransientBlocker else { return }
            clearAllReasons(animatedHide: true)
        }
    }

    private func sync(animatedHide: Bool = true) {
        let reasons = PickyOverlayVisibilityPolicy.visibleReasons(
            local: localReasons,
            interaction: interactionReasons
        )
        overlayVisibilityReasons = reasons
        cancelTransientHide()

        guard PickyOverlayVisibilityPolicy.shouldShowOverlay(for: reasons) else {
            if isOverlayVisible {
                if animatedHide {
                    windowEffects.fadeOutAndHide()
                } else {
                    windowEffects.hide()
                }
            }
            isOverlayVisible = false
            return
        }

        guard !isOverlayVisible else { return }
        windowEffects.show()
        isOverlayVisible = true
    }
}
