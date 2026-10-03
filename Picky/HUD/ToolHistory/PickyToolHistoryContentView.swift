import AppKit
import SwiftUI

/// Known tool payloads are rendered from the saved input, never from a truncated preview
/// or the file currently on disk. This is a read-only execution record.
struct PickyToolHistoryContentView: View {
    let presentation: PickyToolHistoryPresentation.Detail
    var workingDirectory: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            switch presentation {
            case let .edit(file, changes):
                fileLink(file)
                GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 0) {
                                diffLine(change.oldText, mark: "−", tint: DS.Colors.destructiveText)
                                diffLine(change.newText, mark: "+", tint: DS.Colors.successText)
                            }
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                }
                .frame(height: diffHeight(changes))
                .background(DS.Colors.surface2.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
            case let .write(file, content):
                fileLink(file)
                PickyToolHistoryTextBlock(text: content)
            case let .todo(items, isSnapshot):
                if isSnapshot {
                    Text("\(items.filter { $0.marker == .done }.count) / \(items.count)")
                        .font(PickyHUDTypography.status).foregroundStyle(DS.Colors.textSecondary)
                        .accessibilityLabel(L10n.t("hud.toolHistory.todoProgress", Int64(items.filter { $0.marker == .done }.count), Int64(items.count)))
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: DS.Spacing.space2) {
                        Image(systemName: todoSymbol(item.marker))
                            .font(PickyHUDTypography.supporting)
                            .foregroundStyle(todoTint(item.marker))
                            .frame(width: 16)
                            .accessibilityLabel(todoLabel(item.marker))
                        Text(item.text)
                            .font(PickyHUDTypography.body)
                            .foregroundStyle(item.marker == .done || item.marker == .removed ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                            .strikethrough(item.marker == .removed)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, DS.Spacing.space1)
                }
            case let .ask(questions, state):
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                        Text(question.prompt)
                            .font(PickyHUDTypography.supporting)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                        if state == .answered, let answers = question.answers {
                            if answers.isEmpty {
                                Text(L10n.t("hud.toolHistory.ask.emptySelection"))
                                    .font(PickyHUDTypography.body).foregroundStyle(DS.Colors.textSecondary)
                            } else {
                                ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                                    HStack(alignment: .top, spacing: DS.Spacing.space1) {
                                        if question.type != "text" {
                                            Image(systemName: "checkmark")
                                                .font(PickyHUDTypography.status)
                                                .frame(width: PickyHUDTypography.Size.supporting, height: PickyHUDTypography.Size.supporting)
                                                .foregroundStyle(DS.Colors.accentText)
                                                .accessibilityHidden(true)
                                        }
                                        Text(answer).font(PickyHUDTypography.body)
                                            .foregroundStyle(DS.Colors.textPrimary).textSelection(.enabled)
                                    }
                                }
                            }
                        } else if state == .answered {
                            Text(L10n.t("hud.toolHistory.ask.noAnswer"))
                                .font(PickyHUDTypography.supporting).foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, DS.Spacing.space1)
                    if index < questions.count - 1 { Divider().overlay(DS.Colors.borderSubtle) }
                }
                if state != .answered {
                    Text(L10n.t(askStateKey(state)))
                        .font(PickyHUDTypography.supporting)
                        .foregroundStyle(state == .awaiting ? DS.Colors.warningText : DS.Colors.textSecondary)
                        .padding(.top, DS.Spacing.space1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func fileLink(_ path: String?) -> some View {
        if let path { PickyToolHistoryFileLink(path: path, workingDirectory: workingDirectory) }
    }

    private func diffLine(_ text: String, mark: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.space2) {
            Text(mark).accessibilityHidden(true)
            Text(text.isEmpty ? " " : text).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
            Spacer(minLength: 0)
        }
        .font(PickyHUDTypography.supportingMonospaced)
        .foregroundStyle(tint)
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space1)
        .background(tint.opacity(0.07))
        .accessibilityLabel(L10n.t(mark == "+" ? "hud.toolHistory.diff.added" : "hud.toolHistory.diff.removed") + ": " + text)
    }

    private func diffHeight(_ changes: [PickyToolHistoryEditChange]) -> CGFloat {
        var lines = 0
        for change in changes {
            for text in [change.oldText, change.newText] {
                lines += 1
                for character in text where character == "\n" {
                    lines += 1
                    if lines >= 14 { return 300 }
                }
                if lines >= 14 { return 300 }
            }
        }
        let font = NSFont.monospacedSystemFont(ofSize: PickyHUDTypography.Size.supporting, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return min(300, CGFloat(lines) * lineHeight + CGFloat(changes.count) * DS.Spacing.space4
                   + CGFloat(max(0, changes.count - 1)) * DS.Spacing.space2)
    }

    private func todoSymbol(_ marker: PickyToolHistoryTodoMarker) -> String {
        switch marker {
        case .done: return "checkmark"
        case .active: return "circle.dotted"
        case .pending: return "circle"
        case .added: return "plus"
        case .removed: return "minus"
        }
    }
    private func todoTint(_ marker: PickyToolHistoryTodoMarker) -> Color {
        marker == .active || marker == .added ? DS.Colors.accentText : DS.Colors.textSecondary
    }
    private func todoLabel(_ marker: PickyToolHistoryTodoMarker) -> String {
        switch marker {
        case .done: return L10n.t("hud.todo.status.completed")
        case .active: return L10n.t("hud.todo.status.inProgress")
        case .pending: return L10n.t("hud.todo.status.pending")
        case .added: return L10n.t("hud.toolHistory.diff.added")
        case .removed: return L10n.t("hud.toolHistory.diff.removed")
        }
    }
    private func askStateKey(_ state: PickyToolHistoryPresentation.AnswerState) -> String {
        switch state {
        case .answered: return "hud.toolHistory.ask.noAnswer"
        case .awaiting: return "hud.toolHistory.ask.awaiting"
        case .cancelled: return "hud.toolHistory.ask.dismissed"
        case .unavailable: return "hud.toolHistory.ask.unavailable"
        }
    }
}
