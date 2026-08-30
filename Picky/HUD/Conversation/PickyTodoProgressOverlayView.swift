//
//  PickyTodoProgressOverlayView.swift
//  Picky
//
//  Read-only native HUD projection of todo_write state. The Pi extension stays
//  the sole mutation owner; this view only presents its latest session snapshot.
//

import SwiftUI

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

struct PickyTodoProgressListView: View {
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
        Group {
            if presentation.usesScrollableExpandedList {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        expandedTaskRows
                    }
                    .frame(height: PickyFocusStackTodoDrawerLayoutPolicy.viewportHeight)
                    .onAppear { scrollToFocusTask(proxy, animated: false) }
                    .onChange(of: presentation.focusTaskID) { _, _ in
                        scrollToFocusTask(proxy, animated: true)
                    }
                }
            } else {
                expandedTaskRows
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: DS.CornerRadius.control,
                bottomTrailingRadius: DS.CornerRadius.control,
                style: .continuous
            )
            .fill(DS.Colors.surface2)
        )
        .overlay(alignment: .top) {
            Divider()
                .overlay(DS.Colors.borderSubtle.opacity(0.65))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("picky.todo.drawer")
    }

    private var expandedTaskRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.tasks.enumerated()), id: \.element.id) { index, task in
                taskRow(task)
                    .id(task.id)
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

    private func scrollToFocusTask(_ proxy: ScrollViewProxy, animated: Bool) {
        guard animated, !accessibilityReduceMotion else {
            proxy.scrollTo(presentation.focusTaskID, anchor: .center)
            return
        }
        withAnimation(.easeOut(duration: DS.Animation.normal)) {
            proxy.scrollTo(presentation.focusTaskID, anchor: .center)
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
            : .move(edge: .top).combined(with: .opacity)
    }

}

enum PickyTodoProgressMarkerPolicy {
    static func shouldAnimateInProgressMarker(taskStatus: PickyTodoStatus, isSessionRunning: Bool) -> Bool {
        isSessionRunning && taskStatus == .inProgress
    }
}
