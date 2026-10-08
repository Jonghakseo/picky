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
    @Published var stepper = PickyAskUserQuestionStepper()

    var onAnswer: (String, JSONValue) -> Void = { _, _ in }

    var questions: [PickyExtensionUiQuestion] { request?.questions ?? [] }
    var currentStepIndex: Int { stepper.index }
    var usesSteps: Bool { PickyAskUserQuestionStepper.usesSteps(questions) }
    var isFirstStep: Bool { stepper.isFirst }
    var isLastStep: Bool { stepper.isLast(questions) }
    var currentQuestion: (question: PickyExtensionUiQuestion, index: Int)? { stepper.current(questions) }
    var isCurrentStepSubmittable: Bool { stepper.isCurrentSatisfied(formState, questions: questions) }
    var isActionSubmittable: Bool { stepper.isPrimaryEnabled(formState, questions: questions) }

    func configure(request: PickyExtensionUiRequest) {
        guard self.request?.id != request.id else { return }
        self.request = request
        formState = PickyAskUserQuestionFormState()
        formState.seedDefaults(for: request.questions ?? [])
        isSending = false
        errorMessage = nil
        stepper = PickyAskUserQuestionStepper()
    }

    func clear() {
        request = nil
        formState = PickyAskUserQuestionFormState()
        isSending = false
        errorMessage = nil
        stepper = PickyAskUserQuestionStepper()
    }

    func goNext() {
        stepper.advance(formState, questions: questions)
    }

    func goBack() {
        stepper.back()
    }

    /// Return key: advance a step, or submit on the last one.
    func performPrimary() {
        if usesSteps, !isLastStep { goNext() } else { submit() }
    }

    /// Number keys 1-9 pick an option of the current question.
    @discardableResult
    func applyNumberKey(_ number: Int) -> Bool {
        guard !isSending, let current = currentQuestion else { return false }
        return formState.applyNumberKey(number, question: current.question, index: current.index)
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
                header
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        titleBlock(for: request)
                        PickyAskUserQuestionFormBody(
                            questions: questions,
                            form: $viewModel.formState,
                            stepper: $viewModel.stepper,
                            showsKeyHints: true,
                            rowFill: DS.Colors.surface2.opacity(0.8),
                            hidesSinglePrompt: request.title == nil,
                            onSubmitText: { viewModel.performPrimary() }
                        )
                        .disabled(viewModel.isSending)
                        .opacity(viewModel.isSending ? 0.55 : 1)
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
                .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 0.8)
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

    /// Names the asker: the panel appears beside the cursor, away from any conversation.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundStyle(DS.Colors.accentText)
                .accessibilityHidden(true)
            Text(L10n.t("hud.question.mainAsks"))
                .font(PickyHUDTypography.metaSemibold)
                .foregroundStyle(DS.Colors.accentText)
            Spacer(minLength: 4)
            if viewModel.usesSteps {
                Text(verbatim: "\(viewModel.currentStepIndex + 1) / \(questions.count)")
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .accessibilityLabel(L10n.t("hud.question.step", viewModel.currentStepIndex + 1, questions.count))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func titleBlock(for request: PickyExtensionUiRequest) -> some View {
        let title = request.title ?? request.prompt ?? (questions.count == 1 ? questions[0].prompt ?? questions[0].label : nil)
        return VStack(alignment: .leading, spacing: 3) {
            if let title, !title.isEmpty {
                PickyQuestionMarkdown.text(title)
                    .font(PickyHUDTypography.bodySemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = request.prompt, !prompt.isEmpty, prompt != title {
                PickyQuestionMarkdown.text(prompt)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shouldShowDescription, let description = request.description, !description.isEmpty {
                PickyQuestionMarkdown.text(description)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            // A new message while the panel is open closes it and is read as the
            // answer (see CompanionManager), so answering by voice really works.
            HStack(spacing: 5) {
                Image(systemName: "mic")
                    .pickyFont(size: 10, weight: .medium)
                    .accessibilityHidden(true)
                Text(L10n.t("hud.question.voiceHint"))
            }
            .font(PickyHUDTypography.meta)
            .foregroundStyle(DS.Colors.textTertiary)

            HStack(spacing: 6) {
                if let errorMessage = viewModel.errorMessage {
                    Text(L10n.t("hud.question.sendFailed"))
                        .font(PickyHUDTypography.meta)
                        .foregroundStyle(DS.Colors.destructiveText)
                        .lineLimit(1)
                        .help(errorMessage)
                        .accessibilityLabel(L10n.t("hud.question.deliveryFailed", errorMessage))
                } else if showsRequiredHint {
                    Text(L10n.t("hud.question.required"))
                        .font(PickyHUDTypography.meta)
                        .foregroundStyle(DS.Colors.destructiveText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                if !viewModel.usesSteps || viewModel.isFirstStep {
                    Button { viewModel.cancel() } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t("hud.question.skip"))
                            PickyQuestionKeycap(text: "esc")
                        }
                    }
                    .buttonStyle(PickyQuestionGhostButtonStyle())
                    .disabled(viewModel.isSending)
                }

                if viewModel.usesSteps, !viewModel.isFirstStep {
                    Button(L10n.t("hud.question.previous")) { viewModel.goBack() }
                        .buttonStyle(PickyQuestionSecondaryButtonStyle())
                }

                if viewModel.usesSteps, !viewModel.isLastStep {
                    Button(L10n.t("hud.question.next")) { viewModel.goNext() }
                        .buttonStyle(PickyQuestionPrimaryButtonStyle())
                        .disabled(viewModel.isSending || !viewModel.isActionSubmittable)
                        .accessibilityLabel(L10n.t("hud.question.next.accessibility"))
                } else {
                    Button(L10n.t("hud.question.submit")) { viewModel.submit() }
                        .buttonStyle(PickyQuestionPrimaryButtonStyle(isBusy: viewModel.isSending))
                        .disabled(viewModel.isSending || !viewModel.isActionSubmittable)
                        .accessibilityLabel(L10n.t("hud.question.submit.accessibility"))
                        .accessibilityValue(viewModel.isSending ? L10n.t("common.sending") : "")
                }
            }
        }
    }
}
