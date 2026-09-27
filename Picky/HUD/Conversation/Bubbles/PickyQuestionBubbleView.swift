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
    let commands: any PickySessionCommands
    /// List changes this only for the canonical question message selected by a
    /// Live Step navigation request.
    var focusRequestID = 0
    var onFocusConsumed: () -> Void = { }
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var textValue = ""
    @State private var formState = PickyAskUserQuestionFormState()
    @State private var seededFormRequestID: String?
    @State private var isCollapsed: Bool = false
    @State private var didInitCollapse: Bool = false
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var failedSubmission: Submission?
    @State private var submittedRequestID: String?
    @FocusState private var isQuestionFocused: Bool
    @AccessibilityFocusState private var isQuestionAccessibilityFocused: Bool

    private var isCancelled: Bool { cancelledAt != nil }
    private var isClosed: Bool { isCancelled || !isActiveRequest }
    private var isCollapsedDisplay: Bool { isClosed && isCollapsed }

    private var statusLabel: String {
        if isCancelled { return L10n.t("hud.question.cancelled") }
        if !isActiveRequest { return L10n.t("hud.question.answered") }
        return L10n.t("hud.question.needed")
    }

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                headerRow
                if !isCollapsedDisplay {
                    if let title = request.title, !title.isEmpty {
                        Text(.init(title))
                            .font(PickyHUDTypography.bodyCompactMedium)
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let bodyText = PickyQuestionBubbleCopy.bodyText(for: request) {
                        Text(.init(bodyText))
                            .font(PickyHUDTypography.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .strikethrough(isCancelled, color: DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(.init(description))
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    controls
                        .disabled(isClosed || isSubmitting || didSubmit)
                        .opacity(isClosed || isSubmitting || didSubmit ? 0.48 : 1)
                    if let failedSubmission, !isClosed {
                        HStack(spacing: 6) {
                            Text("hud.question.sendFailed")
                                .foregroundColor(DS.Colors.destructiveText)
                            Button(L10n.t("hud.error.retry")) { submit(failedSubmission) }
                                .disabled(isSubmitting)
                        }
                        .font(PickyHUDTypography.supportingMedium)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isCollapsedDisplay ? 6 : 9)
            .frame(
                maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(
                    forDetailWidth: pickyHUDDetailWidth,
                    fraction: 0.88,
                    oppositeSideReserve: 36
                ),
                alignment: .leading
            )
            .background(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .fill(isClosed ? DS.Colors.surface2.opacity(0.55) : DS.Colors.warning.opacity(0.07))
            )
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .stroke((isClosed ? DS.Colors.borderSubtle : DS.Colors.warning.opacity(0.58)), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable()
        .focused($isQuestionFocused)
        .focusEffectDisabled()
        .accessibilityFocused($isQuestionAccessibilityFocused)
        .onChange(of: focusRequestID) { _, _ in
            requestQuestionFocusIfNeeded()
        }
        .onAppear {
            requestQuestionFocusIfNeeded()
            seedFormDefaultsIfNeeded()
            if !didInitCollapse {
                isCollapsed = isClosed
                didInitCollapse = true
            }
        }
        .onChange(of: request.id) { _, _ in
            textValue = ""
            formState = PickyAskUserQuestionFormState()
            seededFormRequestID = nil
            seedFormDefaultsIfNeeded()
            isCollapsed = isClosed
            isSubmitting = false
            didSubmit = false
            failedSubmission = nil
            submittedRequestID = nil
        }
        .onChange(of: isActiveRequest) { _, _ in autoCollapseIfClosed() }
        .onChange(of: cancelledAt) { _, _ in autoCollapseIfClosed() }
    }

    @ViewBuilder
    private var headerRow: some View {
        let label = HStack(spacing: 6) {
            if isClosed {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .pickyFont(size: 8.5, weight: .bold)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Text("⌑ \(statusLabel) · \(request.method)")
                .font(PickyHUDTypography.metaBold)
                .foregroundColor(isClosed ? DS.Colors.textTertiary : DS.Colors.warningText)
                .lineLimit(1)
            if isCollapsedDisplay, let title = request.title, !title.isEmpty {
                Text("· \(title)")
                    .font(PickyHUDTypography.metaBold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        if isClosed {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isCollapsed.toggle() }
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? L10n.t("hud.question.expand") : L10n.t("hud.question.collapse"))
            .accessibilityLabel(L10n.t("hud.question.status.accessibility", statusLabel))
            .accessibilityValue(isCollapsed ? L10n.t("common.collapsed") : L10n.t("common.expanded"))
            .hoverAffordance()
        } else {
            label
        }
    }

    private func autoCollapseIfClosed() {
        guard isClosed, !isCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.18)) { isCollapsed = true }
    }

    private func requestQuestionFocusIfNeeded() {
        guard focusRequestID != 0 else { return }
        DispatchQueue.main.async {
            isQuestionFocused = true
            isQuestionAccessibilityFocused = true
            onFocusConsumed()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch request.method {
        case "confirm":
            HStack(spacing: 6) {
                Button(L10n.t("hud.question.allow")) { answer(.bool(true)) }
                Button(L10n.t("common.cancel")) { cancel() }
            }
            .font(PickyHUDTypography.supportingMedium)
        case "select":
            let options = request.options ?? []
            if options.isEmpty {
                Button(L10n.t("common.cancel")) { cancel() }
                    .font(PickyHUDTypography.supportingMedium)
            } else {
                switch PickyQuestionOptionsLayoutPolicy.layout(for: options) {
                case .inlineRow:
                    HStack(spacing: 6) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { answer(.string(option)) }
                        }
                        Button(L10n.t("common.cancel")) { cancel() }
                    }
                    .font(PickyHUDTypography.supportingMedium)
                case .stacked:
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(options, id: \.self) { option in
                            stackedSelectOptionButton(option)
                        }
                        Button(L10n.t("common.cancel")) { cancel() }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Spacing.xs)
                    }
                    .font(PickyHUDTypography.supportingMedium)
                }
            }
        case "input", "editor":
            HStack(spacing: 6) {
                TextField(L10n.t("hud.question.responsePlaceholder"), text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .font(PickyHUDTypography.supporting)
                    .onSubmit { submitText() }
                Button(L10n.t("hud.question.submit")) { submitText() }
                    .disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.t("common.cancel")) { cancel() }
            }
            .font(PickyHUDTypography.supportingMedium)
        case "askUserQuestion":
            askUserQuestionForm
        default:
            Button(L10n.t("common.dismiss")) { cancel() }
                .font(PickyHUDTypography.supportingMedium)
        }
    }

    private var askUserQuestionForm: some View {
        let questions = request.questions ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if questions.isEmpty {
                Text("hud.questions.none")
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    formQuestion(question, index: index)
                }
            }
            HStack(spacing: 6) {
                Button(L10n.t("hud.question.submit")) { submitAskUserQuestion() }
                    .disabled(!formState.isSubmittable(questions: questions))
                Button(L10n.t("common.cancel")) { cancel() }
            }
            .font(PickyHUDTypography.supportingMedium)
        }
    }

    private func formQuestion(_ question: PickyExtensionUiQuestion, index: Int) -> some View {
        let key = PickyAskUserQuestionFormState.key(for: question, index: index)
        return VStack(alignment: .leading, spacing: 5) {
            Text(question.prompt ?? question.label ?? key)
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch question.type {
            case .radio:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.radioValues[key] == option.value) {
                            formState.selectRadio(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowsOther {
                        optionButton(label: L10n.t("hud.question.other"), description: nil, selected: formState.radioValues[key] == PickyAskUserQuestionFormState.otherSentinel) {
                            formState.selectRadio(question: question, index: index, value: PickyAskUserQuestionFormState.otherSentinel)
                        }
                        TextField(L10n.t("hud.question.other"), text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(PickyHUDTypography.supporting)
                            .disabled(formState.radioValues[key] != PickyAskUserQuestionFormState.otherSentinel)
                            .onSubmit { submitAskUserQuestion() }
                    }
                }
            case .checkbox:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.options ?? []) { option in
                        optionButton(label: option.label, description: option.description, selected: formState.checkboxValues[key]?.contains(option.value) == true) {
                            formState.toggleCheckbox(question: question, index: index, value: option.value)
                        }
                    }
                    if question.allowsOther {
                        TextField(L10n.t("hud.question.other"), text: binding($formState.otherValues, key: key))
                            .textFieldStyle(.roundedBorder)
                            .font(PickyHUDTypography.supporting)
                            .onSubmit { submitAskUserQuestion() }
                    }
                }
            case .text:
                TextField(question.placeholder ?? L10n.t("hud.question.responsePlaceholder"), text: binding($formState.textValues, key: key))
                    .textFieldStyle(.roundedBorder)
                    .font(PickyHUDTypography.supporting)
                    .onSubmit { submitAskUserQuestion() }
            }
        }
        .padding(.vertical, 2)
    }

    private func stackedSelectOptionButton(_ option: String) -> some View {
        Button { answer(.string(option)) } label: {
            Text(option)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textPrimary)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                .fill(DS.Colors.surface2.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func optionButton(label: String, description: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(PickyHUDTypography.supportingMedium)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small).fill(selected ? DS.Colors.accentSubtle : DS.Colors.surface2.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.small).stroke(selected ? DS.Colors.accentText : DS.Colors.borderSubtle, lineWidth: 0.5))
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

    private enum Submission {
        case answer(JSONValue)
        case cancel
    }

    private func answer(_ value: JSONValue) { submit(.answer(value)) }
    private func cancel() { submit(.cancel) }

    private func submit(_ submission: Submission) {
        guard !isClosed, !isSubmitting, !didSubmit else { return }
        isSubmitting = true
        failedSubmission = nil
        let requestID = request.id
        let sessionID = request.sessionId
        submittedRequestID = requestID
        Task {
            do {
                switch submission {
                case .answer(let value):
                    try await commands.answerExtensionUi(sessionID: sessionID, requestID: requestID, value: value)
                case .cancel:
                    try await commands.cancelExtensionUi(sessionID: sessionID, requestID: requestID)
                }
                guard submittedRequestID == requestID else { return }
                didSubmit = true
            } catch {
                guard submittedRequestID == requestID else { return }
                failedSubmission = submission
            }
            isSubmitting = false
        }
    }
}

enum PickyQuestionBubbleCopy {
    static func bodyText(for request: PickyExtensionUiRequest) -> String? {
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !prompt.isEmpty, prompt != title { return prompt }
        if title.isEmpty { return request.method }
        return nil
    }
}
