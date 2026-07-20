//
//  PickyTodoProgressOverlayView.swift
//  Picky
//
//  Read-only native HUD projection of todo_write state. The Pi extension stays
//  the sole mutation owner; this view only presents its latest session snapshot.
//

import SwiftUI

private struct PickyTodoProgressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(interactionFill(isPressed: configuration.isPressed))
            )
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.fast),
                value: configuration.isPressed
            )
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.fast),
                value: isHovered
            )
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.fast),
                value: isFocused
            )
    }

    private func interactionFill(isPressed: Bool) -> Color {
        PickyHUDInteractionStateLayer.fill(
            isHovered: isHovered,
            isPressed: isPressed,
            isFocused: isFocused
        )
    }
}

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

struct PickyTodoProgressRestoreButton: View {
    let presentation: PickyTodoProgressPresentation
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            Label(presentation.stepText, systemImage: "checklist")
                .font(PickyHUDTypography.statusMonospacedMedium)
                .foregroundColor(presentation.isComplete ? DS.Colors.successText : DS.Colors.info)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PickyTodoProgressButtonStyle())
        // The base surface sits behind the style's state layer so hover/press
        // feedback remains visible instead of being covered by an opaque label.
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.97))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke((presentation.isComplete ? DS.Colors.success : DS.Colors.info).opacity(0.5), lineWidth: 0.8)
                )
        )
        .clipShape(Capsule(style: .continuous))
        .help(L10n.t("hud.todo.show"))
        .accessibilityLabel(L10n.t("hud.todo.show"))
        .accessibilityValue(presentation.stepText)
        .accessibilityHint(L10n.t("hud.todo.expand"))
    }
}

struct PickyTodoProgressOverlayView: View {
    static let minimumCardWidth: CGFloat = 280
    static let maximumCardWidth: CGFloat = 700

    let presentation: PickyTodoProgressPresentation
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Group {
            if isExpanded {
                expandedCard
                    .transition(expandedTransition)
            } else {
                PickyTodoProgressRestoreButton(
                    presentation: presentation,
                    onRestore: { isExpanded = true }
                )
            }
        }
        .onChange(of: presentation.isComplete) { _, isComplete in
            if PickyTodoProgressOverlayPolicy.shouldCollapse(isComplete: isComplete) {
                isExpanded = false
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal),
            value: isExpanded
        )
    }

    private var expandedCard: some View {
        PickyTodoProgressAdaptiveWidthLayout(
            minimumWidth: Self.minimumCardWidth,
            maximumWidth: Self.maximumCardWidth
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { isExpanded = false }) {
                    expandedHeader
                }
                .buttonStyle(PickyTodoProgressButtonStyle())
                .help(L10n.t("hud.todo.collapse"))
                .accessibilityLabel("\(presentation.stepText), \(L10n.t("hud.todo.collapse"))")
                .accessibilityValue(L10n.t("hud.todo.state.expanded"))
                .accessibilityHint(L10n.t("hud.todo.collapse"))

                Divider()
                    .overlay(DS.Colors.borderSubtle.opacity(0.65))

                if presentation.usesScrollableExpandedList {
                    ScrollView(.vertical, showsIndicators: true) {
                        expandedTaskRows
                    }
                    .frame(maxHeight: 224)
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
    }

    private var expandedHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            progressRing(side: 19, lineWidth: 2.4)

            Text(presentation.stepText)
                .font(PickyHUDTypography.statusMonospacedMedium)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .pickyFont(size: 9.5, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            ProgressView()
                .controlSize(.small)
                .tint(DS.Colors.info)
        case .pending:
            Circle()
                .stroke(DS.Colors.textTertiary.opacity(0.8), lineWidth: 1.3)
                .frame(width: 12, height: 12)
        }
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

    private var progressColor: Color {
        presentation.isComplete ? DS.Colors.success : DS.Colors.info
    }

    private func progressRing(side: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: lineWidth)
            if presentation.fraction > 0 {
                Circle()
                    .trim(from: 0, to: presentation.fraction)
                    .stroke(progressColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(
                        accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal),
                        value: presentation.fraction
                    )
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
