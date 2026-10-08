import Combine
import Foundation

/// One deadline per rail. Re-entering cancels a pending collapse; interaction
/// holds open immediately, without waiting for the hover dwell.
struct PickyHUDDockExpansionState {
    private(set) var isExpanded = false
    private(set) var deadline: TimeInterval?
    private(set) var centersControls = false
    private var pendingExpansion = false

    mutating func update(pointerInside: Bool, heldOpen: Bool, now: TimeInterval, conversationOpen: Bool = false) {
        // Keep the centered lane until collapse starts, including the exit grace period.
        if conversationOpen { centersControls = true }
        if heldOpen {
            isExpanded = true
            deadline = nil
        } else if pointerInside == isExpanded {
            deadline = nil
        } else if deadline == nil || pendingExpansion != pointerInside {
            pendingExpansion = pointerInside
            deadline = now + (pointerInside ? 0.2 : 0.3)
        }
    }

    mutating func advance(now: TimeInterval) {
        guard let deadline, now >= deadline else { return }
        isExpanded = pendingExpansion
        if !isExpanded { centersControls = false }
        self.deadline = nil
    }
}

enum PickyHUDDockPreviewTarget: Equatable {
    case session(String)
    case group(String)
    /// The `+` slot at the end of an expanded group in the horizontal rail.
    case groupAdd(String)
    case newPickle
    case archive
}

@MainActor
final class PickyHUDDockExpansionController: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var centersControls = false
    @Published private(set) var previewTarget: PickyHUDDockPreviewTarget?

    func preview(_ target: PickyHUDDockPreviewTarget) {
        if previewTarget != target { previewTarget = target }
    }
    private var state = PickyHUDDockExpansionState()
    private var pending: Task<Void, Never>?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func update(pointerInside: Bool, heldOpen: Bool, conversationOpen: Bool = false) {
        pending?.cancel()
        pending = nil
        state.update(pointerInside: pointerInside, heldOpen: heldOpen, now: now, conversationOpen: conversationOpen)
        publish()
        guard let deadline = state.deadline else { return }
        let duration = Duration.seconds(max(0, deadline - now))
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.state.advance(now: self.now)
            self.publish()
            self.pending = nil
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
    }

    private func publish() {
        if centersControls != state.centersControls { centersControls = state.centersControls }
        if isExpanded != state.isExpanded {
            isExpanded = state.isExpanded
            if !isExpanded { previewTarget = nil }
        }
    }
}
