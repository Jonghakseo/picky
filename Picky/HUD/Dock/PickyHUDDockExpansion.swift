import Combine
import Foundation

/// One deadline per rail. Re-entering cancels a pending collapse; interaction
/// holds open immediately, without waiting for the hover dwell.
struct PickyHUDDockExpansionState {
    private(set) var isExpanded = false
    private(set) var deadline: TimeInterval?
    private var pendingExpansion = false

    mutating func update(pointerInside: Bool, heldOpen: Bool, now: TimeInterval) {
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
        self.deadline = nil
    }
}

@MainActor
final class PickyHUDDockExpansionController: ObservableObject {
    @Published private(set) var isExpanded = false
    private var state = PickyHUDDockExpansionState()
    private var pending: Task<Void, Never>?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func update(pointerInside: Bool, heldOpen: Bool) {
        pending?.cancel()
        pending = nil
        state.update(pointerInside: pointerInside, heldOpen: heldOpen, now: now)
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
        if isExpanded != state.isExpanded { isExpanded = state.isExpanded }
    }
}
