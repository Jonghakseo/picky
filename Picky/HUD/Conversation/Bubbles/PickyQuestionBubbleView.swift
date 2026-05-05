//
//  PickyQuestionBubbleView.swift
//  Picky
//
//  Inline extension-ui question bubble for conversation cards.
//

import SwiftUI

struct PickyQuestionBubbleView: View {
    let request: PickyExtensionUiRequest
    let cancelledAt: Date?
    let isActiveRequest: Bool
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var textValue = ""
    @State private var formState = PickyAskUserQuestionFormState()
    @State private var seededFormRequestID: String?

    private var isCancelled: Bool { cancelledAt != nil }
    private var isClosed: Bool { isCancelled || !isActiveRequest }

    private var statusLabel: String {
        if isCancelled { return "INPUT CANCELLED" }
        if !isActiveRequest { return "INPUT CLOSED" }
        return "INPUT NEEDED"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("⌑ \(statusLabel) · \(request.method)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(isClosed ? DS.Colors.textTertiary : DS.Colors.warning)
                    .lineLimit(1)
                if let title = request.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text(request.prompt ?? request.title ?? request.method)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .strikethrough(isCancelled, color: DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
                    .disabled(isClosed)
                    .opacity(isClosed ? 0.48 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.88, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(isClosed ? DS.Colors.surface2.opacity(0.55) : DS.Colors.warning.opacity(0.07))
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .stroke((isClosed ? DS.Colors.borderSubtle : DS.Colors.warning.opacity(0.58)), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { seedFormDefaultsIfNeeded() }
        .onChange(of: request.id) { _, _ in
            textValue = ""
            formState = PickyAskUserQuestionFormState()
            seededFormRequestID = nil
            seedFormDefaultsIfNeeded()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: 6) {
                Button("Allow") { answer(.bool(true)) }
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        case "select":
            let options = request.options ?? []
            if options.isEmpty {
                Button("Cancel") { cancel() }
                    .font(.system(size: 11, weight: .medium))
            } else {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { answer(.string(option)) }
                    }
                    Button("Cancel") { cancel() }
                }
                .font(.system(size: 11, weight: .medium))
            }
        case "input", "editor":
            HStack(spacing: 6) {
                TextField("Response…", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitText() }
                Button("Submit") { submitText() }
                    .disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        case "askUserQuestion":
            askUserQuestionForm
        default:
            Button("Dismiss") { cancel() }
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var askUserQuestionForm: some View {
        let questions = request.questions ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if questions.isEmpty {
                Text("No questions provided")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    formQuestion(question, index: index)
                }
            }
            HStack(spacing: 6) {
                Button("Submit") { submitAskUserQuestion() }
                    .disabled(!formState.isSubmittable(questions: questions))
                Button("Cancel") { cancel() }
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private func formQuestion(_ question: PickyExtensionUiQuestion, index: Int) -> some View {
        let key = PickyAskUserQuestionFormState.key(for: question, index: index)
        return VStack(alignment: .leading, spacing: 5) {
            Text(question.prompt ?? question.label ?? key)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            switch question.type {
            case .radio:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.radioValues[key] == option.value) {
                            formState.selectRadio(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        optionButton(label: "Other…", description: nil, selected: formState.radioValues[key] == PickyAskUserQuestionFormState.otherSentinel) {
                            formState.selectRadio(question: question, index: index, value: PickyAskUserQuestionFormState.otherSentinel)
                        }
                        TextField("Other…", text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .disabled(formState.radioValues[key] != PickyAskUserQuestionFormState.otherSentinel)
                    }
                }
            case .checkbox:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.checkboxValues[key]?.contains(option.value) == true) {
                            formState.toggleCheckbox(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowOther ?? true {
                        TextField("Other…", text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }
            case .text:
                TextField(question.placeholder ?? "Response…", text: binding($formState.textValues, key: key))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 2)
    }

    private func optionButton(label: String, description: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .medium))
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? DS.Colors.accentSubtle : DS.Colors.surface2.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundColor(selected ? DS.Colors.accentText : DS.Colors.textPrimary)
    }

    private func binding(_ dictionary: Binding<[String: String]>, key: String) -> Binding<String> {
        Binding(get: { dictionary.wrappedValue[key] ?? "" }, set: { dictionary.wrappedValue[key] = $0 })
    }

    private func submitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer(.string(trimmed))
    }

    private func submitAskUserQuestion() {
        let questions = request.questions ?? []
        guard formState.isSubmittable(questions: questions) else { return }
        answer(.object(["value": .object(formState.answerObject(for: questions))]))
    }

    private func seedFormDefaultsIfNeeded() {
        guard request.method == "askUserQuestion", seededFormRequestID != request.id else { return }
        formState.seedDefaults(for: request.questions ?? [])
        seededFormRequestID = request.id
    }

    private func answer(_ value: JSONValue) {
        Task { try? await viewModel.answerExtensionUi(sessionID: request.sessionId, requestID: request.id, value: value) }
    }

    private func cancel() {
        Task { try? await viewModel.cancelExtensionUi(sessionID: request.sessionId, requestID: request.id) }
    }
}
