//
//  PickyTodoProgressOverlayView.swift
//  Picky
//
//  Read-only native HUD projection of todo_write state. The Pi extension stays
//  the sole mutation owner; this view only presents its latest session snapshot.
//

import SwiftUI

struct PickyTodoProgressRestoreButton: View {
    static let bottomContentInset: CGFloat = 38

    let presentation: PickyTodoProgressPresentation
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            Label(presentation.countText, systemImage: "checklist")
                .font(PickyHUDTypography.statusMonospacedMedium)
                .foregroundColor(presentation.isComplete ? DS.Colors.successText : DS.Colors.info)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.97))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke((presentation.isComplete ? DS.Colors.success : DS.Colors.info).opacity(0.5), lineWidth: 0.8)
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.t("hud.todo.show"))
        .accessibilityLabel(L10n.t("hud.todo.show"))
        .accessibilityValue(presentation.countText)
    }
}

struct PickyTodoProgressOverlayView: View {
    static let bottomContentInset: CGFloat = 48

    let presentation: PickyTodoProgressPresentation
    let onHide: () -> Void
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                expandedCard
                    .transition(.scale(scale: 0.97, anchor: .bottom).combined(with: .opacity))
            }
            compactPill
        }
        .onChange(of: presentation.isComplete) { _, isComplete in
            if PickyTodoProgressOverlayPolicy.shouldCollapse(isComplete: isComplete) {
                isExpanded = false
            }
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private var compactPill: some View {
        HStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    progressRing(side: 19, lineWidth: 2.4)

                    Text(presentation.countText)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(compactSummary)
                        .font(PickyHUDTypography.statusMedium)
                        .foregroundColor(presentation.isComplete ? DS.Colors.successText : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .pickyFont(size: 9.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 12)
                }
                .padding(.leading, 11)
                .padding(.trailing, 8)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("hud.todo.toggle.help"))
            .accessibilityLabel("\(presentation.countText), \(compactSummary)")
            .accessibilityHint(L10n.t("hud.todo.toggle.help"))

            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.65))
                .frame(width: 0.5, height: 16)
                .accessibilityHidden(true)

            Button(action: onHide) {
                Image(systemName: "minus")
                    .pickyFont(size: 8.5, weight: .semibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 29, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("hud.todo.hide"))
            .accessibilityLabel(L10n.t("hud.todo.hide"))
        }
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.97))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(progressColor.opacity(0.5), lineWidth: 0.8)
                )
        )
        .clipShape(Capsule(style: .continuous))
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.t("hud.todo.title"))
                    .font(PickyHUDTypography.supportingSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 8)
                Text(presentation.countText)
                    .font(PickyHUDTypography.statusMonospacedMedium)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

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
                .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        )
        .accessibilityElement(children: .contain)
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

    private var compactSummary: String {
        presentation.isComplete ? L10n.t("hud.todo.complete") : presentation.activeText
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
                    .animation(.easeOut(duration: 0.2), value: presentation.fraction)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
