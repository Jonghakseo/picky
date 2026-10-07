//
//  PickyHUDArchiveHoldFeedback.swift
//  Picky
//
//  Shared visual state for the dock row's hold-to-archive interaction: the
//  press timing and the fill progress the row draws behind its content.
//

import Combine
import SwiftUI

@MainActor
final class PickyHUDArchiveHoldFeedback: ObservableObject {
    @Published private(set) var isPressing = false
    @Published private(set) var progress: Double = 0

    private var startTask: Task<Void, Never>?
    private var didComplete = false

    func setPressing(_ isPressing: Bool) {
        if isPressing {
            begin()
        } else if !didComplete {
            cancel()
        }
    }

    func complete() {
        startTask?.cancel()
        startTask = nil
        didComplete = true
        progress = 1
    }

    func cancel() {
        startTask?.cancel()
        startTask = nil
        didComplete = false
        isPressing = false
        withAnimation(.easeOut(duration: 0.18)) {
            progress = 0
        }
    }

    private func begin() {
        startTask?.cancel()
        didComplete = false
        progress = 0
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: PickyHUDArchiveHoldPolicy.feedbackStartDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.startTask = nil
            self.isPressing = true
            withAnimation(.linear(duration: PickyHUDArchiveHoldPolicy.feedbackAnimationDuration)) {
                self.progress = 1
            }
        }
    }
}
