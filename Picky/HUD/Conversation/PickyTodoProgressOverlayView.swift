//
//  PickyTodoProgressOverlayView.swift
//  Picky
//
//  Read-only native HUD projection of todo_write state. The Pi extension stays
//  the sole mutation owner; this view only presents its latest session snapshot.
//

import SwiftUI

private struct PickyTodoProgressAdaptiveWidthLayout: Layout {
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard let first = subviews.first else { return .zero }

        let availableWidth = proposal.width ?? CGFloat.greatestFiniteMagnitude
        let naturalWidth = first.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width
        let resolvedWidth = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: naturalWidth,
            availableWidth: availableWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
        let size = first.sizeThatFits(ProposedViewSize(width: resolvedWidth, height: proposal.height))

        return CGSize(width: resolvedWidth, height: size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard let first = subviews.first else { return }

        let availableWidth = bounds.width
        let naturalWidth = first.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width
        let resolvedWidth = PickyTodoProgressAdaptiveWidthPolicy.resolveWidth(
            idealWidth: naturalWidth,
            availableWidth: availableWidth,
            minimumWidth: minimumWidth,
            maximumWidth: maximumWidth
        )
        let size = first.sizeThatFits(ProposedViewSize(width: resolvedWidth, height: nil))
        let x = bounds.maxX - resolvedWidth
        first.place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: resolvedWidth, height: size.height)
        )
    }
}

enum PickyTodoProgressAdaptiveWidthPolicy {
    static func resolveWidth(
        idealWidth: CGFloat,
        availableWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth.isFinite else {
            return min(max(idealWidth, minimumWidth), maximumWidth)
        }

        let boundedMaxWidth = min(availableWidth, maximumWidth)
        guard boundedMaxWidth > 0 else { return 0 }

        if boundedMaxWidth <= minimumWidth {
            return boundedMaxWidth
        }

        return max(minimumWidth, min(idealWidth, boundedMaxWidth))
    }
}

struct PickyTodoCircularProgressView: View {
    let fraction: Double
    let isComplete: Bool
    let side: CGFloat
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: lineWidth)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        isComplete ? DS.Colors.success : DS.Colors.info,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal),
                        value: fraction
                    )
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct PickyTodoProgressOverlayView: View {
    static let minimumCardWidth: CGFloat = 280
    static let maximumCardWidth: CGFloat = 700

    let presentation: PickyTodoProgressPresentation
    let isSessionRunning: Bool
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        if isExpanded {
            expandedCard
                .transition(expandedTransition)
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal),
                    value: isExpanded
                )
        }
    }

    private var expandedCard: some View {
        PickyTodoProgressAdaptiveWidthLayout(
            minimumWidth: Self.minimumCardWidth,
            maximumWidth: Self.maximumCardWidth
        ) {
            Group {
                if presentation.usesScrollableExpandedList {
                    ScrollView(.vertical, showsIndicators: true) {
                        expandedTaskRows
                    }
                    .frame(height: PickyFocusStackTodoDrawerLayoutPolicy.viewportHeight)
                } else {
                    expandedTaskRows
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.8)
                    )
                    // `elevation.transient`: the expanded card floats above transcript content.
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("picky.todo.drawer")
    }

    private var expandedTaskRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.tasks.enumerated()), id: \.element.id) { index, task in
                taskRow(task)
                if index < presentation.tasks.count - 1 {
                    Divider()
                        .overlay(DS.Colors.borderSubtle.opacity(0.45))
                        .padding(.leading, 34)
                }
            }
        }
    }

    private func taskRow(_ task: PickyTodoTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            taskMarker(task)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            Text(task.displayText)
                .font(task.status == .inProgress ? PickyHUDTypography.supportingSemibold : PickyHUDTypography.supporting)
                .foregroundColor(taskTextColor(task))
                .strikethrough(task.status == .completed, color: DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .frame(minHeight: PickyFocusStackTodoDrawerLayoutPolicy.taskRowMinimumHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.displayText)
        .accessibilityValue(accessibilityStatus(task.status))
    }

    @ViewBuilder
    private func taskMarker(_ task: PickyTodoTask) -> some View {
        switch task.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .pickyFont(size: 13, weight: .semibold)
                .foregroundColor(DS.Colors.successText)
        case .inProgress:
            if PickyTodoProgressMarkerPolicy.shouldAnimateInProgressMarker(
                taskStatus: task.status,
                isSessionRunning: isSessionRunning
            ) {
                ProgressView()
                    .controlSize(.small)
                    .tint(DS.Colors.info)
            } else {
                staticTodoInProgressMarker
            }
        case .pending:
            Circle()
                .stroke(DS.Colors.textTertiary.opacity(0.8), lineWidth: 1.3)
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private var staticTodoInProgressMarker: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(DS.Colors.info, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: 12, height: 12)
    }

    private func taskTextColor(_ task: PickyTodoTask) -> Color {
        switch task.status {
        case .completed: return DS.Colors.textTertiary
        case .inProgress: return DS.Colors.info
        case .pending: return DS.Colors.textSecondary
        }
    }

    private func accessibilityStatus(_ status: PickyTodoStatus) -> String {
        switch status {
        case .pending: return L10n.t("hud.todo.status.pending")
        case .inProgress: return L10n.t("hud.todo.status.inProgress")
        case .completed: return L10n.t("hud.todo.status.completed")
        }
    }

    private var expandedTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
    }

}

enum PickyTodoProgressMarkerPolicy {
    static func shouldAnimateInProgressMarker(taskStatus: PickyTodoStatus, isSessionRunning: Bool) -> Bool {
        isSessionRunning && taskStatus == .inProgress
    }
}
