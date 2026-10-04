//
//  PickyMainAgentActivityStore.swift
//  Picky
//
//  Owner of the main agent's live turn presence: the activity chips rendered
//  beside the cursor and the extension-UI question awaiting an answer. Sibling
//  of `PickyMainAgentConversationStore`, which owns the durable transcript.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class PickyMainAgentActivityStore: ObservableObject {
    /// How long finished chips linger beside the response bubble before fading.
    static let lingerDelay: Duration = .seconds(2)

    @Published private(set) var liveActivities: [PickyMainActivity] = []
    @Published private(set) var pendingQuestion: PickyExtensionUiRequest?

    private var clearTask: Task<Void, Never>?

    /// Called whenever live-turn presence changes so the owner can refresh
    /// presentation that depends on it (the main cancel pill).
    var onLiveTurnPresenceChanged: (() -> Void)?

    /// Chips that still belong to an in-flight turn. A deferred clear is a
    /// purely visual afterglow, so lingering chips must not keep a finished
    /// turn's cancel affordance alive.
    var hasLiveTurnActivities: Bool {
        clearTask == nil && !liveActivities.isEmpty
    }

    func apply(_ activity: PickyMainActivity) {
        clearTask?.cancel()
        clearTask = nil
        liveActivities = PickyMainActivityStack.apply(activity, to: liveActivities)
        onLiveTurnPresenceChanged?()
    }

    /// Defers clearing the chips so they briefly linger beside the response
    /// bubble, then fade. Cancelled by a fresh activity or a hard reset.
    func scheduleClear() {
        guard !liveActivities.isEmpty else { return }
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lingerDelay)
            guard !Task.isCancelled, let self else { return }
            // Animate the removal so the chips fade via their `.transition(.opacity)`
            // instead of cutting out. Only the presence changes here; chip layout is
            // unaffected, so this does not reintroduce the height-bounce the chips
            // otherwise guard against.
            withAnimation(.easeOut(duration: 0.25)) {
                self.liveActivities = []
            }
            self.clearTask = nil
            self.onLiveTurnPresenceChanged?()
        }
    }

    /// Clears chips now and cancels any pending deferred clear (hard reset
    /// paths: connection loss, new session).
    func clearImmediately() {
        clearTask?.cancel()
        clearTask = nil
        liveActivities = []
        onLiveTurnPresenceChanged?()
    }

    func setPendingQuestion(_ request: PickyExtensionUiRequest?) {
        pendingQuestion = request
    }

    func clearPendingQuestion(id: String) {
        guard pendingQuestion?.id == id else { return }
        pendingQuestion = nil
    }
}
