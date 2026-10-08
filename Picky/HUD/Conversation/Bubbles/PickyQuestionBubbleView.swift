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
    /// What the user answered, recorded by agentd once the answer was delivered.
    var answerRows: [PickyQuestionAnswerRow]? = nil
    let isActiveRequest: Bool
    let commands: any PickySessionCommands
    /// List changes this only for the canonical question message selected by a
    /// Live Step navigation request.
    var focusRequestID = 0
    var onFocusConsumed: () -> Void = { }
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var textValue = ""
    @State private var formState = PickyAskUserQuestionFormState()
    @State private var stepper = PickyAskUserQuestionStepper()
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
    private var isLocked: Bool { isClosed || isSubmitting || didSubmit }
    private var questions: [PickyExtensionUiQuestion] { request.questions ?? [] }
    private var usesSteps: Bool {
        request.method == "askUserQuestion" && PickyAskUserQuestionStepper.usesSteps(questions)
    }

    private var statusLabel: String {
        if isCancelled { return L10n.t("hud.question.cancelled") }
        if !isActiveRequest { return L10n.t("hud.question.answered") }
        return L10n.t("hud.question.needed")
    }

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: isClosed ? 6 : 10) {
                headerRow
                if !isCollapsedDisplay {
                    if isClosed {
                        closedDetail
                    } else {
                        openContent
                    }
                }
            }
            .padding(.horizontal, isClosed ? 10 : 12)
            .padding(.top, isClosed ? 7 : 10)
            .padding(.bottom, isClosed ? 7 : 12)
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
                    .fill(isClosed ? DS.Colors.surface2.opacity(0.55) : DS.Colors.surface2)
            )
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .stroke(isClosed ? DS.Colors.borderSubtle : DS.Colors.accent.opacity(0.45), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(!isClosed)
        .focused($isQuestionFocused)
        .focusEffectDisabled()
        .accessibilityFocused($isQuestionAccessibilityFocused)
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            handleNumberKey(press.characters) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            performPrimary() ? .handled : .ignored
        }
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
            stepper = PickyAskUserQuestionStepper()
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

    // MARK: Header

    @ViewBuilder
    private var headerRow: some View {
        if isClosed {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    statusIcon
                    Text(statusLabel)
                        .font(PickyHUDTypography.metaSemibold)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    if let summary = collapsedSummary {
                        Text(verbatim: "· \(summary)")
                            .font(PickyHUDTypography.metaMedium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .pickyFont(size: 8.5, weight: .bold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? L10n.t("hud.question.expand") : L10n.t("hud.question.collapse"))
            .accessibilityLabel(L10n.t("hud.question.status.accessibility", statusLabel))
            .accessibilityValue(isCollapsed ? L10n.t("common.collapsed") : L10n.t("common.expanded"))
            .hoverAffordance()
        } else {
            HStack(spacing: 6) {
                statusIcon
                Text(statusLabel)
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.accentText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if usesSteps {
                    Text(verbatim: "\(stepper.index + 1) / \(questions.count)")
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .accessibilityLabel(L10n.t("hud.question.step", stepper.index + 1, questions.count))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusIcon: some View {
        let (symbol, color): (String, Color) = isCancelled
            ? ("minus.circle", DS.Colors.textTertiary)
            : (isClosed ? ("checkmark.circle", DS.Colors.successText) : ("questionmark.circle", DS.Colors.accentText))
        return Image(systemName: symbol)
            .pickyFont(size: 11, weight: .semibold)
            .foregroundColor(color)
            .accessibilityHidden(true)
    }

    /// Collapsed line: the recorded answers when there are any, otherwise the question.
    private var collapsedSummary: String? {
        if !isCancelled, let answerRows, !answerRows.isEmpty, isCollapsed {
            return answerRows.map(\.value).joined(separator: " · ")
        }
        if let titleText { return titleText }
        guard let body = PickyQuestionBubbleCopy.bodyText(for: request), body != request.method else { return nil }
        return body
    }

    // MARK: Closed

    @ViewBuilder
    private var closedDetail: some View {
        if !isCancelled, let answerRows, !answerRows.isEmpty {
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(Array(answerRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                        Text(row.value)
                            .font(PickyHUDTypography.metaMedium)
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 18)
        } else {
            questionText
                .padding(.leading, 18)
        }
    }

    // MARK: Open

    @ViewBuilder
    private var openContent: some View {
        questionText
        Group {
            controls
        }
        .disabled(isLocked)
        .opacity(isSubmitting || didSubmit ? 0.55 : 1)
    }

    private var titleText: String? {
        if let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if request.method == "askUserQuestion", questions.count == 1 {
            let prompt = (questions[0].prompt ?? questions[0].label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? nil : prompt
        }
        return nil
    }

    @ViewBuilder
    private var questionText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = titleText {
                PickyQuestionMarkdown.text(title)
                    .font(PickyHUDTypography.bodySemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bodyText = PickyQuestionBubbleCopy.bodyText(for: request),
               bodyText != request.method,
               bodyText != titleText {
                PickyQuestionMarkdown.text(bodyText)
                    .font(PickyHUDTypography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let description = request.description, !description.isEmpty, !usesSteps || stepper.isFirst {
                PickyQuestionMarkdown.text(description)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch request.method {
        case "confirm":
            footer(
                primaryTitle: L10n.t("hud.question.allow"),
                primaryEnabled: true,
                skipTitle: L10n.t("common.cancel"),
                primary: { answer(.bool(true)) }
            )
        case "select":
            selectControls
        case "input", "editor":
            TextField(L10n.t("hud.question.responsePlaceholder"), text: $textValue)
                .textFieldStyle(.roundedBorder)
                .font(PickyHUDTypography.supporting)
                .onSubmit { submitText() }
            footer(
                primaryTitle: L10n.t("hud.question.submit"),
                primaryEnabled: !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                skipTitle: L10n.t("hud.question.skip"),
                primary: { submitText() }
            )
        case "askUserQuestion":
            PickyAskUserQuestionFormBody(
                questions: questions,
                form: $formState,
                stepper: $stepper,
                showsKeyHints: isQuestionFocused,
                rowFill: DS.Colors.surface1,
                hidesSinglePrompt: request.title == nil,
                onSubmitText: { _ = performPrimary() }
            )
            askUserQuestionFooter
        default:
            footer(primaryTitle: nil, primaryEnabled: false, skipTitle: L10n.t("common.dismiss"), primary: {})
        }
    }

    @ViewBuilder
    private var selectControls: some View {
        let options = request.options ?? []
        switch PickyQuestionOptionsLayoutPolicy.layout(for: options) {
        case .inlineRow where !options.isEmpty:
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button(option) { answer(.string(option)) }
                        .buttonStyle(PickyQuestionSecondaryButtonStyle())
                }
                Button(L10n.t("hud.question.skip")) { cancel() }
                    .buttonStyle(PickyQuestionGhostButtonStyle())
                Spacer(minLength: 0)
            }
            failureRow
        default:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                    PickyQuestionOptionRow(
                        kind: .radio,
                        label: option,
                        selected: false,
                        keyHint: isQuestionFocused && offset < 9 ? "\(offset + 1)" : nil,
                        rowFill: DS.Colors.surface1
                    ) {
                        answer(.string(option))
                    }
                }
            }
            footer(primaryTitle: nil, primaryEnabled: false, skipTitle: L10n.t("hud.question.skip"), primary: {})
        }
    }

    private var askUserQuestionFooter: some View {
        let isMidStep = usesSteps && !stepper.isLast(questions)
        let enabled = stepper.isPrimaryEnabled(formState, questions: questions)
        return footer(
            primaryTitle: isMidStep ? L10n.t("hud.question.next") : L10n.t("hud.question.submit"),
            primaryEnabled: enabled,
            skipTitle: usesSteps ? nil : L10n.t("hud.question.skip"),
            showsBack: usesSteps && !stepper.isFirst,
            showsRequiredHint: !enabled,
            primary: { _ = performPrimary() }
        )
    }

    @ViewBuilder
    private var failureRow: some View {
        if let failedSubmission, !isClosed {
            HStack(spacing: 6) {
                Text(L10n.t("hud.question.sendFailed"))
                    .foregroundColor(DS.Colors.destructiveText)
                Button(L10n.t("hud.error.retry")) { submit(failedSubmission) }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .disabled(isSubmitting)
            }
            .font(PickyHUDTypography.supportingMedium)
        }
    }

    private func footer(
        primaryTitle: String?,
        primaryEnabled: Bool,
        skipTitle: String?,
        showsBack: Bool = false,
        showsRequiredHint: Bool = false,
        primary: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            if failedSubmission != nil, !isClosed {
                failureRow
            } else if showsRequiredHint {
                Text(L10n.t("hud.question.required"))
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(1)
            } else if isQuestionFocused, let primaryTitle {
                Text(verbatim: "↩ \(primaryTitle)")
                    .font(PickyHUDTypography.meta)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            if let skipTitle {
                Button(skipTitle) { cancel() }
                    .buttonStyle(PickyQuestionGhostButtonStyle())
            }
            if showsBack {
                Button(L10n.t("hud.question.previous")) { stepper.back() }
                    .buttonStyle(PickyQuestionSecondaryButtonStyle())
            }
            if let primaryTitle {
                Button(primaryTitle, action: primary)
                    .buttonStyle(PickyQuestionPrimaryButtonStyle(isBusy: isSubmitting))
                    .disabled(!primaryEnabled)
            }
        }
    }

    // MARK: Keyboard

    private func handleNumberKey(_ characters: String) -> Bool {
        guard !isLocked, let number = Int(characters), (1...9).contains(number) else { return false }
        switch request.method {
        case "askUserQuestion":
            guard let current = stepper.current(questions) else { return false }
            return formState.applyNumberKey(number, question: current.question, index: current.index)
        case "select":
            let options = request.options ?? []
            guard options.indices.contains(number - 1) else { return false }
            answer(.string(options[number - 1]))
            return true
        default:
            return false
        }
    }

    /// Return key and text-field submit: advance a step, or send the answer.
    private func performPrimary() -> Bool {
        guard !isLocked else { return false }
        switch request.method {
        case "confirm":
            answer(.bool(true))
            return true
        case "input", "editor":
            submitText()
            return true
        case "askUserQuestion":
            if usesSteps, !stepper.isLast(questions) {
                return stepper.advance(formState, questions: questions)
            }
            submitAskUserQuestion()
            return true
        default:
            return false
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

    // MARK: Submission

    private func submitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer(.string(trimmed))
    }

    private func submitAskUserQuestion() {
        guard formState.isSubmittable(questions: questions) else { return }
        answer(.object(["value": .object(formState.answerObject(for: questions))]))
    }

    private func seedFormDefaultsIfNeeded() {
        guard request.method == "askUserQuestion", seededFormRequestID != request.id else { return }
        formState.seedDefaults(for: questions)
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
