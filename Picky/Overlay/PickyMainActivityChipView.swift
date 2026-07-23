//
//  PickyMainActivityChipView.swift
//  Picky
//
//  Cursor-overlay projection for live main-agent activity.
//

import Combine
import SwiftUI

struct PickyMainActivityChipPresentation: Equatable {
    let models: [PickyMainActivityChipModel]
    let isQuestionPending: Bool

    init(activities: [PickyMainActivity], isQuestionPending: Bool) {
        self.models = activities.compactMap(PickyMainActivityChipModel.chipModel(for:))
        self.isQuestionPending = isQuestionPending
    }
}

@MainActor
final class PickyMainActivityChipPresentationCache: ObservableObject {
    @Published private(set) var presentation = PickyMainActivityChipPresentation(
        activities: [],
        isQuestionPending: false
    )

    func update(activities: [PickyMainActivity], isQuestionPending: Bool) {
        let updated = PickyMainActivityChipPresentation(
            activities: activities,
            isQuestionPending: isQuestionPending
        )
        guard updated != presentation else { return }
        presentation = updated
    }
}

/// Pure projection rules shared by the cursor overlay and its focused tests.
enum PickyMainActivityOverlayPolicy {
    static func shouldShow(
        voiceState: CompanionVoiceState,
        hasActivities: Bool,
        hasPendingQuestion: Bool
    ) -> Bool {
        if case .processing = voiceState {
            return hasActivities || hasPendingQuestion
        }
        return false
    }
}

struct PickyMainActivityChipStackView: View, Equatable {
    let presentation: PickyMainActivityChipPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if presentation.isQuestionPending {
                PickyMainActivityWaitingChipView()
            } else {
                ForEach(Array(presentation.models.enumerated()), id: \.offset) { index, model in
                    PickyMainActivityChipView(model: model)
                        .opacity(index == 0 && presentation.models.count > 1 ? 0.55 : 1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct PickyMainActivityChipView: View {
    let model: PickyMainActivityChipModel

    private var colors: PickyMainActivityChipColors {
        model.category == .pickle ? .pickle : .standard
    }

    var body: some View {
        HStack(spacing: 6) {
            leadingIndicator
            Text(model.label)
                .pickyFont(size: 11, weight: .medium)
                .lineLimit(1)
            if let detail = model.detail, !detail.isEmpty {
                Text(detail)
                    .pickyFont(size: 11, weight: .regular, design: .monospaced)
                    .italic(model.category == .thinking)
                    .foregroundStyle(colors.detail)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(colors.label)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(minWidth: 132, maxWidth: 300, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(colors.border, lineWidth: 0.8)
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(model.isRunning ? "Running" : "Completed")
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if model.category == .thinking {
            HStack(spacing: 2) {
                Circle().frame(width: 3, height: 3)
                Circle().frame(width: 3, height: 3)
                Circle().frame(width: 3, height: 3)
            }
            .foregroundStyle(colors.label)
            .frame(width: 13)
        } else if model.isRunning {
            PickyMainActivityPulsingDot(color: colors.label)
        } else {
            Image(systemName: "checkmark")
                .pickyFont(size: 9, weight: .semibold)
                .frame(width: 9, height: 9)
        }
    }

    private var accessibilityLabel: String {
        [model.label, model.detail].compactMap { $0 }.joined(separator: ": ")
    }
}

private struct PickyMainActivityWaitingChipView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill")
                .pickyFont(size: 11, weight: .semibold)
            Text("질문 대기 중")
                .pickyFont(size: 11, weight: .medium)
        }
        .foregroundStyle(PickyMainActivityChipColors.waiting.label)
        .padding(.horizontal, DS.Spacing.sm)
        .frame(minWidth: 132, minHeight: 30, maxHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PickyMainActivityChipColors.waiting.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PickyMainActivityChipColors.waiting.border, lineWidth: 0.8)
        )
        .accessibilityLabel("Question waiting for an answer")
    }
}

private struct PickyMainActivityPulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.38 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onChange(of: reduceMotion) { _, enabled in
                isPulsing = false
                guard !enabled else { return }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

private struct PickyMainActivityChipColors {
    let background: Color
    let border: Color
    let label: Color
    let detail: Color

    // These component-specific colors are the approved cursor-overlay palette;
    // no existing semantic token represents its translucent desktop layer.
    static let standard = Self(
        background: Color(red: 28 / 255, green: 30 / 255, blue: 36 / 255).opacity(0.92),
        border: Color.white.opacity(0.22),
        label: Color.white.opacity(0.92),
        detail: Color.white.opacity(0.5)
    )
    static let pickle = Self(
        background: Color(red: 23 / 255, green: 52 / 255, blue: 102 / 255).opacity(0.95),
        border: Color(red: 120 / 255, green: 170 / 255, blue: 1).opacity(0.5),
        label: Color(hex: "#D6E5FF"),
        detail: Color(hex: "#D6E5FF").opacity(0.7)
    )
    static let waiting = Self(
        background: DS.Colors.surface1.opacity(0.97),
        border: Color(red: 250 / 255, green: 199 / 255, blue: 117 / 255).opacity(0.55),
        label: Color(hex: "#FAC775"),
        detail: Color(hex: "#FAC775")
    )
}
