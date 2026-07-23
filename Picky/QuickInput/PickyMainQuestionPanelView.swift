//
//  PickyMainQuestionPanelView.swift
//  Picky
//
//  Dark, keyboard-first askUserQuestion form for the main agent.
//

import Combine
import SwiftUI

@MainActor
final class PickyMainQuestionPanelViewModel: ObservableObject {
    @Published private(set) var request: PickyExtensionUiRequest?
    @Published var formState = PickyAskUserQuestionFormState()
    @Published var isSending = false

    var onAnswer: (String, JSONValue) -> Void = { _, _ in }

    func configure(request: PickyExtensionUiRequest) {
        guard self.request?.id != request.id else { return }
        self.request = request
        formState = PickyAskUserQuestionFormState()
        formState.seedDefaults(for: request.questions ?? [])
        isSending = false
    }

    func clear() {
        request = nil
        formState = PickyAskUserQuestionFormState()
        isSending = false
    }

    func submit() {
        guard let request, !isSending else { return }
        let questions = request.questions ?? []
        guard formState.isSubmittable(questions: questions) else { return }
        onAnswer(request.id, .object(["value": .object(formState.answerObject(for: questions))]))
    }

    func cancel() {
        guard let request, !isSending else { return }
        onAnswer(request.id, PickyMainQuestionPanelPolicy.cancellationValue)
    }
}

struct PickyMainQuestionPanelView: View {
    @ObservedObject var viewModel: PickyMainQuestionPanelViewModel

    private var request: PickyExtensionUiRequest? { viewModel.request }
    private var questions: [PickyExtensionUiQuestion] { request?.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let request {
                header(for: request)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if let description = request.description, !description.isEmpty {
                            markdownText(description, color: DS.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        questionControls
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                footer
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: PickyMainQuestionPanelLayout.contentWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.97))
                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
        .padding(PickyMainQuestionPanelLayout.shadowOutset)
        .frame(width: PickyMainQuestionPanelLayout.panelWidth, alignment: .leading)
    }

    private func header(for request: PickyExtensionUiRequest) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            markdownText(request.title ?? request.prompt ?? "Picky 질문", color: DS.Colors.textPrimary)
                .pickyFont(size: 12, weight: .medium)
            if let prompt = request.prompt,
               !prompt.isEmpty,
               prompt != request.title {
                markdownText(prompt, color: DS.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var questionControls: some View {
        if questions.isEmpty {
            Text("질문 내용이 없습니다.")
                .pickyFont(size: 11)
                .foregroundStyle(DS.Colors.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    formQuestion(question, index: index)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("esc 취소")
                .pickyFont(size: 10)
                .foregroundStyle(DS.Colors.textPrimary.opacity(0.35))
            Spacer(minLength: DS.Spacing.sm)
            Button("제출") { viewModel.submit() }
                .buttonStyle(PickyMainQuestionSubmitButtonStyle())
                .disabled(viewModel.isSending || !viewModel.formState.isSubmittable(questions: questions))
                .accessibilityLabel("Submit answer")
                .accessibilityValue(viewModel.isSending ? "Sending" : "")
        }
    }

    private func formQuestion(_ question: PickyExtensionUiQuestion, index: Int) -> some View {
        let key = PickyAskUserQuestionFormState.key(for: question, index: index)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                markdownText(question.prompt ?? question.label ?? key, color: DS.Colors.textPrimary)
                    .pickyFont(size: 11, weight: .medium)
                if question.required ?? true {
                    Text("*")
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundStyle(DS.Colors.warningText)
                        .accessibilityHidden(true)
                }
            }
            switch question.type {
            case .radio:
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(question.options ?? []) { option in
                        optionButton(
                            label: option.label,
                            description: option.description,
                            selected: viewModel.formState.radioValues[key] == option.value,
                            selectionKind: .radio
                        ) {
                            viewModel.formState.selectRadio(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        optionButton(
                            label: "Other…",
                            description: nil,
                            selected: viewModel.formState.radioValues[key] == PickyAskUserQuestionFormState.otherSentinel,
                            selectionKind: .radio
                        ) {
                            viewModel.formState.selectRadio(question: question, index: index, value: PickyAskUserQuestionFormState.otherSentinel)
                        }
                        TextField("Other…", text: binding(\PickyAskUserQuestionFormState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .pickyFont(size: 11)
                            .disabled(viewModel.formState.radioValues[key] != PickyAskUserQuestionFormState.otherSentinel)
                    }
                }
            case .checkbox:
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(question.options ?? []) { option in
                        optionButton(
                            label: option.label,
                            description: option.description,
                            selected: viewModel.formState.checkboxValues[key]?.contains(option.value) == true,
                            selectionKind: .checkbox
                        ) {
                            viewModel.formState.toggleCheckbox(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        TextField("Other…", text: binding(\PickyAskUserQuestionFormState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .pickyFont(size: 11)
                    }
                }
            case .text:
                TextField(question.placeholder ?? "Response…", text: binding(\PickyAskUserQuestionFormState.textValues, key: key))
                    .textFieldStyle(.roundedBorder)
                    .pickyFont(size: 11)
            }
        }
    }

    private enum SelectionKind { case radio, checkbox }

    private func optionButton(
        label: String,
        description: String?,
        selected: Bool,
        selectionKind: SelectionKind,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: selectionSymbol(for: selectionKind, selected: selected))
                    .pickyFont(size: 12, weight: .medium)
                    .foregroundStyle(selected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    markdownText(label, color: selected ? DS.Colors.accentText : DS.Colors.textPrimary)
                        .pickyFont(size: 11, weight: .medium)
                    if let description, !description.isEmpty {
                        markdownText(description, color: DS.Colors.textSecondary)
                            .pickyFont(size: 10)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(selected ? DS.Colors.accentSubtle : DS.Colors.surface2.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(selected ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .accessibilityLabel(PickyBubbleMarkdown.displayString(for: label))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func selectionSymbol(for kind: SelectionKind, selected: Bool) -> String {
        switch (kind, selected) {
        case (.radio, true): "largecircle.fill.circle"
        case (.radio, false): "circle"
        case (.checkbox, true): "checkmark.square.fill"
        case (.checkbox, false): "square"
        }
    }

    private func binding(
        _ keyPath: WritableKeyPath<PickyAskUserQuestionFormState, [String: String]>,
        key: String
    ) -> Binding<String> {
        Binding(
            get: { viewModel.formState[keyPath: keyPath][key] ?? "" },
            set: { viewModel.formState[keyPath: keyPath][key] = $0 }
        )
    }

    private func markdownText(_ source: String, color: Color) -> Text {
        Text(PickyMainQuestionPanelMarkdown.attributedText(for: source))
            .foregroundColor(color)
    }
}

private enum PickyMainQuestionPanelMarkdown {
    static func attributedText(for source: String) -> AttributedString {
        let inlineOnly = source
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        return PickyBubbleMarkdown.attributedText(for: inlineOnly)
    }
}

private struct PickyMainQuestionSubmitButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pickyFont(size: 11, weight: .medium)
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(configuration.isPressed || isHovered ? DS.Colors.accentHover : DS.Colors.accent)
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
    }
}
