//
//  PickyHUDArchiveHoldFeedback.swift
//  Picky
//
//  Shared visual state for the Dock tile and group-list row hold-to-archive
//  interaction. Both surfaces use the same timing, animation, and ring.
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

struct PickyHUDArchiveHoldProgressRing: View {
    let isPressing: Bool
    let progress: Double
    let side: CGFloat

    var body: some View {
        ZStack {
            arc(progress: 1)
                .opacity(0.18)
            arc(progress: progress)
        }
        .frame(width: side, height: side)
        .opacity(isPressing || progress > 0 ? 1 : 0)
        .shadow(
            color: DS.Colors.warning.opacity(DS.Elevation.archiveHoldRingShadowOpacity),
            radius: DS.Elevation.archiveHoldRingShadowRadius
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arc(progress: Double) -> some View {
        Circle()
            .trim(
                from: PickyHUDArchiveHoldPolicy.ringGapStartFraction,
                to: PickyHUDArchiveHoldPolicy.ringGapStartFraction + (max(0, min(progress, 1)) * PickyHUDArchiveHoldPolicy.ringUsableFraction)
            )
            .stroke(
                DS.Colors.warning,
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
            )
            .rotationEffect(.degrees(-90))
    }
}
