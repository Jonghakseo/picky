//
//  PickyHUDArchiveHoverReveal.swift
//  Picky
//
//  Delays the dock row's archive button until the pointer has rested on the
//  row. A pointer that merely passes over or clicks the row never meets the
//  button, so archiving needs a deliberate pause first.
//

import Combine
import Foundation

@MainActor
final class PickyHUDArchiveHoverReveal: ObservableObject {
    @Published private(set) var isRevealed = false

    private let delay: Duration
    private var revealTask: Task<Void, Never>?

    init(delay: Duration = PickyHUDDockHoverDisclosurePolicy.archiveRevealDelay) {
        self.delay = delay
    }

    /// Starts the wait when the pointer enters and hides the button as soon as it leaves.
    func setHovering(_ hovering: Bool) {
        if hovering {
            guard revealTask == nil, !isRevealed else { return }
            revealTask = Task { @MainActor [weak self, delay] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.revealTask = nil
                self.isRevealed = true
            }
        } else {
            cancel()
        }
    }

    func cancel() {
        revealTask?.cancel()
        revealTask = nil
        if isRevealed { isRevealed = false }
    }
}
