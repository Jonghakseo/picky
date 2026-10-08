//
//  PickyQuestionFormComponents.swift
//  Picky
//
//  Question form pieces shared by the Pickle question bubble and the main
//  Picky question panel, so both surfaces show one selection grammar:
//  circle = pick one, square = pick any, "Type your own" opens inline,
//  two or more questions advance one step at a time.
//

import SwiftUI

enum PickyQuestionSelectionKind {
    case radio, checkbox
}

enum PickyQuestionMarkdown {
    /// Inline-only markdown: question copy is a label, so block syntax is dropped.
    static func text(_ source: String) -> Text {
        let inlineOnly = source
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        return Text(PickyBubbleMarkdown.attributedText(for: inlineOnly))
    }
}

struct PickyQuestionKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PickyHUDTypography.minimumMonospacedMedium)
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

struct PickyQuestionSelectionIndicator: View {
    let kind: PickyQuestionSelectionKind
    let selected: Bool

    var body: some View {
        ZStack {
            switch kind {
            case .radio:
                Circle().fill(selected ? DS.Colors.accent : DS.Colors.surface1)
                Circle().strokeBorder(selected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1.5)
                if selected {
                    Circle().fill(DS.Colors.textOnAccent).frame(width: 5, height: 5)
                }
            case .checkbox:
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(selected ? DS.Colors.accent : DS.Colors.surface1)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1.5)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(DS.Colors.textOnAccent)
                }
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// One selectable option. `accessory` renders under the label inside the same
/// row (used by "Type your own" for its text field).
struct PickyQuestionOptionRow<Accessory: View>: View {
    let kind: PickyQuestionSelectionKind
    let label: String
    var description: String? = nil
    let selected: Bool
    var muted = false
    var keyHint: String? = nil
    let rowFill: Color
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 8) {
                    PickyQuestionSelectionIndicator(kind: kind, selected: selected)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        PickyQuestionMarkdown.text(label)
                            .font(PickyHUDTypography.supportingMedium)
                            .foregroundColor(muted && !selected ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let description, !description.isEmpty {
                            PickyQuestionMarkdown.text(description)
                                .font(PickyHUDTypography.status)
                                .foregroundColor(DS.Colors.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let keyHint { PickyQuestionKeycap(text: keyHint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PickyBubbleMarkdown.displayString(for: label))
            .accessibilityValue(selected ? L10n.t("common.selected") : L10n.t("common.notSelected"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            accessory()
                .padding(.leading, 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                .fill(selected ? DS.Colors.accentSubtle : rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                .strokeBorder(selected ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: selected ? 1 : 0.5)
        )
        .hoverAffordance()
    }
}

extension PickyQuestionOptionRow where Accessory == EmptyView {
    init(
        kind: PickyQuestionSelectionKind,
        label: String,
        description: String? = nil,
        selected: Bool,
        muted: Bool = false,
        keyHint: String? = nil,
        rowFill: Color,
        action: @escaping () -> Void
    ) {
        self.init(kind: kind, label: label, description: description, selected: selected, muted: muted,
                  keyHint: keyHint, rowFill: rowFill, action: action, accessory: { EmptyView() })
    }
}

struct PickyQuestionStepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { step in
                Capsule()
                    .fill(color(for: step))
                    .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.t("hud.question.step", current + 1, total))
    }

    private func color(for step: Int) -> Color {
        if step < current { return DS.Colors.accent }
        if step == current { return DS.Colors.accent.opacity(0.45) }
        return DS.Colors.borderSubtle
    }
}

/// Wraps previous-answer chips onto as many lines as the width allows.
struct PickyQuestionChipFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

struct PickyQuestionPrimaryButtonStyle: ButtonStyle {
    var isBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            configuration.label
        }
        .font(PickyHUDTypography.supportingSemibold)
        .foregroundStyle(isEnabled ? DS.Colors.textOnAccent : DS.Colors.disabledText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(backgroundColor(isPressed: configuration.isPressed))
        )
        .opacity(isEnabled && configuration.isPressed ? 0.88 : 1)
        .onHover { isHovered = isEnabled && $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return DS.Colors.disabledBackground }
        return isPressed || isHovered ? DS.Colors.accentHover : DS.Colors.accent
    }
}

struct PickyQuestionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PickyHUDTypography.supportingMedium)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? DS.Colors.surface3 : DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .strokeBorder(DS.Colors.borderStrong, lineWidth: 0.5)
            )
            .hoverAffordance()
    }
}

struct PickyQuestionGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PickyHUDTypography.supportingMedium)
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .hoverAffordance()
    }
}

/// Question body for `askUserQuestion`: step progress, previous-answer chips and
/// the current question (or every question, when there is only one).
struct PickyAskUserQuestionFormBody: View {
    let questions: [PickyExtensionUiQuestion]
    @Binding var form: PickyAskUserQuestionFormState
    @Binding var stepper: PickyAskUserQuestionStepper
    /// Number-key hints are shown only while the surface receives key presses.
    var showsKeyHints: Bool
    var rowFill: Color
    /// A single question whose prompt already serves as the card title.
    var hidesSinglePrompt = false
    var onSubmitText: () -> Void = {}
    @FocusState private var focusedFieldKey: String?

    private var usesSteps: Bool { PickyAskUserQuestionStepper.usesSteps(questions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesSteps {
                PickyQuestionStepProgress(current: stepper.index, total: questions.count)
                if stepper.index > 0 { previousAnswers }
            }
            if let current = stepper.current(questions) {
                questionView(current.question, index: current.index)
                    .id(PickyAskUserQuestionFormState.key(for: current.question, index: current.index))
            } else {
                Text(L10n.t("hud.questions.none"))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private var previousAnswers: some View {
        PickyQuestionChipFlowLayout(spacing: 4) {
            ForEach(0..<stepper.index, id: \.self) { step in
                let question = questions[step]
                Button { stepper.jump(to: step) } label: {
                    HStack(spacing: 4) {
                        Text(Self.shortLabel(question, index: step))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text(answerText(question, index: step))
                            .fontWeight(.semibold)
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .font(PickyHUDTypography.metaMedium)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(DS.Colors.surface1))
                    .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverAffordance()
            }
        }
    }

    static func shortLabel(_ question: PickyExtensionUiQuestion, index: Int) -> String {
        let label = (question.label ?? question.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? PickyAskUserQuestionFormState.key(for: question, index: index) : label
    }

    private func answerText(_ question: PickyExtensionUiQuestion, index: Int) -> String {
        guard let answer = form.displayAnswer(question: question, index: index) else { return "—" }
        return answer.more > 0 ? L10n.t("hud.question.answerMore", answer.first, answer.more) : answer.first
    }

    private func questionView(_ question: PickyExtensionUiQuestion, index: Int) -> some View {
        let key = PickyAskUserQuestionFormState.key(for: question, index: index)
        let required = question.required ?? true
        let showsPrompt = !(hidesSinglePrompt && questions.count == 1)
        let prompt = (question.prompt ?? question.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            if (showsPrompt && !prompt.isEmpty) || question.type == .checkbox || (question.type == .text && required) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsPrompt, !prompt.isEmpty {
                        PickyQuestionMarkdown.text(prompt)
                            .font(PickyHUDTypography.supportingSemibold)
                            .foregroundColor(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if question.type == .checkbox {
                        Text(L10n.t("hud.question.hint.multiple"))
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    } else if question.type == .text, required {
                        Text(L10n.t("hud.question.hint.required"))
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.destructiveText)
                    }
                }
            }
            switch question.type {
            case .text:
                TextField(question.placeholder ?? L10n.t("hud.question.responsePlaceholder"), text: binding(\.textValues, key: key))
                    .textFieldStyle(.roundedBorder)
                    .font(PickyHUDTypography.supporting)
                    .focused($focusedFieldKey, equals: key)
                    .onSubmit(onSubmitText)
            case .radio, .checkbox:
                let kind: PickyQuestionSelectionKind = question.type == .radio ? .radio : .checkbox
                let options = question.options ?? []
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                        PickyQuestionOptionRow(
                            kind: kind,
                            label: option.label,
                            description: option.description,
                            selected: form.isOptionSelected(question: question, index: index, value: option.value),
                            keyHint: keyHint(offset + 1),
                            rowFill: rowFill
                        ) {
                            select(question, index: index, value: option.value)
                        }
                    }
                    if question.allowsOther {
                        let otherSelected = form.isOtherSelected(question: question, index: index)
                        PickyQuestionOptionRow(
                            kind: kind,
                            label: L10n.t("hud.question.other"),
                            selected: otherSelected,
                            muted: true,
                            keyHint: keyHint(options.count + 1),
                            rowFill: rowFill,
                            action: { select(question, index: index, value: PickyAskUserQuestionFormState.otherSentinel) },
                            accessory: {
                                if otherSelected {
                                    TextField(L10n.t("hud.question.responsePlaceholder"), text: binding(\.otherValues, key: key))
                                        .textFieldStyle(.roundedBorder)
                                        .font(PickyHUDTypography.supporting)
                                        .focused($focusedFieldKey, equals: key)
                                        .onSubmit(onSubmitText)
                                        .accessibilityLabel(L10n.t("hud.question.other"))
                                }
                            }
                        )
                        .onChange(of: otherSelected) { _, isSelected in
                            if isSelected { focusedFieldKey = key }
                        }
                    }
                }
            }
        }
    }

    private func keyHint(_ number: Int) -> String? {
        showsKeyHints && number <= 9 ? "\(number)" : nil
    }

    private func select(_ question: PickyExtensionUiQuestion, index: Int, value: String) {
        switch question.type {
        case .radio: form.selectRadio(question: question, index: index, value: value)
        case .checkbox: form.toggleCheckbox(question: question, index: index, value: value)
        case .text: break
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PickyAskUserQuestionFormState, [String: String]>, key: String) -> Binding<String> {
        Binding(
            get: { form[keyPath: keyPath][key] ?? "" },
            set: { form[keyPath: keyPath][key] = $0 }
        )
    }
}
