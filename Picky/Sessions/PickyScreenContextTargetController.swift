//
//  PickyScreenContextTargetController.swift
//  Picky
//
//  Single owner of the Companion-side view of the armed screen-context target.
//  `PickySessionSelectionStoring` stays the source of truth; this type keeps the
//  cursor/voice-routing projection in sync, disarms the target when a dispatch
//  finishes, and drives the matching overlay reason.
//

import Combine
import Foundation

@MainActor
final class PickyScreenContextTargetController: ObservableObject {
    /// Normalized session id of the armed target, or nil when nothing is armed.
    /// Observed by the cursor overlay.
    @Published private(set) var targetSessionID: String?
    /// Display name supplied by the HUD when it arms a target. Dropped whenever
    /// the target changes without a fresh label, so a stale Pickle name can
    /// never be shown next to a different session.
    private(set) var targetLabel: String?

    private let selectionStore: PickySessionSelectionStoring
    private let overlayVisibility: PickyOverlayVisibilityController
    private var changeCancellable: AnyCancellable?

    init(
        selectionStore: PickySessionSelectionStoring,
        overlayVisibility: PickyOverlayVisibilityController
    ) {
        self.selectionStore = selectionStore
        self.overlayVisibility = overlayVisibility
        self.targetSessionID = selectionStore.screenContextTargetSessionID
        self.targetLabel = (selectionStore as? PickyScreenContextTargetLabelStoring)?.screenContextTargetLabel
    }

    /// Adopts the store's current target and follows later HUD changes.
    func bind() {
        apply(selectionStore.screenContextTargetSessionID)
        changeCancellable = NotificationCenter.default.publisher(for: .pickyScreenContextTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let sessionID = notification.userInfo?[PickyScreenContextTargetNotification.sessionIDKey] as? String
                let label = notification.userInfo?[PickyScreenContextTargetNotification.labelKey] as? String
                self?.apply(sessionID, label: label)
            }
    }

    func unbind() {
        changeCancellable?.cancel()
        changeCancellable = nil
    }

    func apply(_ sessionID: String?, label: String? = nil) {
        let normalized = PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(sessionID)
        let targetChanged = targetSessionID != normalized
        targetSessionID = normalized
        targetLabel = normalized == nil
            ? nil
            : label ?? (targetChanged ? nil : targetLabel)
        overlayVisibility.setLocalReason(.screenContextTarget, visible: normalized != nil)
    }

    /// Disarms after a dispatch the caller identified only by session id. A
    /// sticky target survives: normal completion never disarms it.
    func clearIfCurrent(_ sessionID: String?) {
        guard let sessionID else { return }
        clear(
            sessionID: sessionID,
            requiredRevision: nil,
            isSticky: selectionStore.screenContextTargetSticky,
            includingSticky: false
        )
    }

    /// Disarms using the snapshot captured when the dispatch was armed. The
    /// revision check keeps a late completion from disarming a target the user
    /// re-armed in the meantime. Hard failures pass `includingSticky: true` so a
    /// locked target does not stay armed after the dispatch could not be sent.
    func clearIfCurrent(
        _ snapshot: PickyVoiceInputTargetSnapshot?,
        includingSticky: Bool = false
    ) {
        guard case .pickle(let sessionID, .armed(_, let sticky, let revision)) = snapshot?.target else { return }
        clear(
            sessionID: sessionID,
            requiredRevision: revision,
            isSticky: sticky,
            includingSticky: includingSticky
        )
    }

    private func clear(
        sessionID: String,
        requiredRevision: UInt64?,
        isSticky: Bool,
        includingSticky: Bool
    ) {
        guard !isSticky || includingSticky else { return }
        guard selectionStore.screenContextTargetSessionID == sessionID else { return }
        if let requiredRevision, selectionStore.screenContextTargetRevision != requiredRevision { return }
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        apply(nil)
    }
}
