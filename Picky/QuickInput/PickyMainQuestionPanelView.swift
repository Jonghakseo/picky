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
    @Published var errorMessage: String?
    @Published private(set) var currentStepIndex = 0

    var onAnswer: (String, JSONValue) -> Void = { _, _ in }

    var questions: [PickyExtensionUiQuestion] { request?.questions ?? [] }
    var usesSteps: Bool { questions.count > 1 }
    var isFirstStep: Bool { currentStepIndex == 0 }
    var isLastStep: Bool { currentStepIndex >= questions.count - 1 }
    var currentQuestion: (question: PickyExtensionUiQuestion, index: Int)? {
        guard questions.indices.contains(currentStepIndex) else { return nil }
        return (questions[currentStepIndex], currentStepIndex)
    }
    var isCurrentStepSubmittable: Bool {
        guard let currentQuestion else { return true }
        return formState.isRequiredSatisfied(question: currentQuestion.question, index: currentQuestion.index)
    }
    var isActionSubmittable: Bool {
        usesSteps && !isLastStep
            ? isCurrentStepSubmittable
            : formState.isSubmittable(questions: questions)
    }

    func configure(request: PickyExtensionUiRequest) {
        guard self.request?.id != request.id else { return }
        self.request = request
        formState = PickyAskUserQuestionFormState()
        formState.seedDefaults(for: request.questions ?? [])
        isSending = false
        errorMessage = nil
        currentStepIndex = 0
    }

    func clear() {
        request = nil
        formState = PickyAskUserQuestionFormState()
        isSending = false
        errorMessage = nil
        currentStepIndex = 0
    }

    func goNext() {
        guard usesSteps, !isLastStep, isCurrentStepSubmittable else { return }
        currentStepIndex += 1
    }

    func goBack() {
        guard usesSteps, !isFirstStep else { return }
        currentStepIndex -= 1
    }

    func submit() {
        guard let request, !isSending, formState.isSubmittable(questions: questions) else { return }
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
    private var questions: [PickyExtensionUiQuestion] { viewModel.questions }
    private var shouldShowDescription: Bool { !viewModel.usesSteps || viewModel.isFirstStep }
    private var showsRequiredHint: Bool { !viewModel.isSending && !viewModel.isActionSubmittable }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let request {
                dragGrabber
                header(for: request)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if viewModel.usesSteps {
                            stepIndicator
                        }
                        if shouldShowDescription,
                           let description = request.description,
                           !description.isEmpty {
                            markdownText(description, color: DS.Colors.textSecondary)
                                .pickyFont(size: 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        questionControls
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: PickyMainQuestionPanelLayout.maximumScrollableContentHeight, alignment: .top)
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

    /// Purely a discoverability affordance. The window itself is moved natively via
    /// `isMovableByWindowBackground`, so any non-control area (including this strip)
    /// drags the panel; the capsule just signals that.
    private var dragGrabber: some View {
        Capsule(style: .continuous)
            .fill(DS.Colors.textPrimary.opacity(0.18))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
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

    private var stepIndicator: some View {
        Text("\(viewModel.currentStepIndex + 1) / \(questions.count)")
            .pickyFont(size: 10, weight: .medium)
            .foregroundStyle(DS.Colors.textSecondary)
            .accessibilityLabel("Question \(viewModel.currentStepIndex + 1) of \(questions.count)")
    }

    @ViewBuilder
    private var questionControls: some View {
        if questions.isEmpty {
            Text("질문 내용이 없습니다.")
                .pickyFont(size: 11)
                .foregroundStyle(DS.Colors.textSecondary)
        } else if let currentQuestion = viewModel.currentQuestion {
            formQuestion(currentQuestion.question, index: currentQuestion.index)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .pickyFont(size: 10)
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Answer delivery failed: \(errorMessage)")
            } else if showsRequiredHint {
                Text("필수 항목을 입력하세요")
                    .pickyFont(size: 10)
                    .foregroundStyle(DS.Colors.warningText)
            }

            HStack(spacing: DS.Spacing.sm) {
                Text("esc 취소")
                    .pickyFont(size: 10)
                    .foregroundStyle(DS.Colors.textPrimary.opacity(0.35))
                Spacer(minLength: DS.Spacing.sm)

                if viewModel.usesSteps, !viewModel.isFirstStep {
                    Button("이전") { viewModel.goBack() }
                        .controlSize(.small)
                }

                if viewModel.usesSteps, !viewModel.isLastStep {
                    Button("다음") { viewModel.goNext() }
                        .buttonStyle(PickyMainQuestionSubmitButtonStyle())
                        .disabled(viewModel.isSending || !viewModel.isActionSubmittable)
                        .accessibilityLabel("Next question")
                } else {
                    Button("제출") { viewModel.submit() }
                        .buttonStyle(PickyMainQuestionSubmitButtonStyle())
                        .disabled(viewModel.isSending || !viewModel.isActionSubmittable)
                        .accessibilityLabel("Submit answer")
                        .accessibilityValue(viewModel.isSending ? "Sending" : "")
                }
            }
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
                    if question.allowsOther {
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
                    if question.allowsOther {
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pickyFont(size: 11, weight: .medium)
            .foregroundStyle(isEnabled ? DS.Colors.textOnAccent : DS.Colors.disabledText)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .opacity(isEnabled && configuration.isPressed ? 0.88 : 1)
            .onHover { isHovered = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return DS.Colors.disabledBackground }
        return isPressed || isHovered ? DS.Colors.accentHover : DS.Colors.accent
    }
}
