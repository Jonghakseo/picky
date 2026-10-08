import AppKit
import SwiftUI
import Vision
@testable import Picky

// Proposal only. Production code is unchanged.
// "before" scenes render the production PickyQuestionBubbleView and
// PickyMainQuestionPanelView. "after" scenes render one shared proposal body
// (ProposalQuestionBody) inside two shells: the Pickle conversation bubble and
// the main Picky cursor panel. Tokens, typography, HUD widths, bubble shape and
// panel metrics come from production (DS, PickyHUDTypography,
// PickyConversationBubbleLayout, PickyMainQuestionPanelLayout).

// MARK: - Proposal model (static fixtures)

enum QKind { case radio, checkbox, text }

struct QOption {
    let label: String
    var desc: String? = nil
    var selected = false
    var focused = false
    var hovered = false
}

enum OtherRow {
    case hidden
    case idle
    case typing(String)
}

struct QModel {
    var prompt: String?
    var kind: QKind
    var options: [QOption] = []
    var other: OtherRow = .hidden
    var required = false
    var textValue: String? = nil
    var placeholder = "답변을 입력하세요…"
}

enum Hint {
    case none
    case keys(String)
    case required
    case failed
}

struct FooterModel {
    var primary = "제출"
    var primaryEnabled = true
    var sending = false
    var back = false
    var skip: String? = "건너뛰기"
    var hint: Hint = .none
}

struct FormModel {
    var title: String
    var description: String? = nil
    var step: (Int, Int)? = nil
    var previous: [(String, String)] = []
    var question: QModel? = nil
    var chips: [String] = []
    var footer = FooterModel()
}

enum Density {
    case pickle, panel
    var rowFill: Color { self == .pickle ? DS.Colors.surface1 : DS.Colors.surface2.opacity(0.8) }
}

// MARK: - Shared proposal body

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(PickyHUDTypography.minimumMonospacedMedium)
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
    }
}

struct SelectionIndicator: View {
    let kind: QKind
    let selected: Bool
    var body: some View {
        ZStack {
            if kind == .radio {
                Circle().fill(selected ? DS.Colors.accent : DS.Colors.surface1)
                Circle().stroke(selected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1.5)
                if selected { Circle().fill(DS.Colors.textOnAccent).frame(width: 5, height: 5) }
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? DS.Colors.accent : DS.Colors.surface1)
                RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(selected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1.5)
                if selected {
                    Text(Image(systemName: "checkmark"))
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(DS.Colors.textOnAccent)
                }
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

struct OptionRow<Accessory: View>: View {
    let kind: QKind
    let label: String
    var desc: String? = nil
    let selected: Bool
    var focused = false
    var hovered = false
    var muted = false
    let key: String?
    let density: Density
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                SelectionIndicator(kind: kind, selected: selected).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(PickyHUDTypography.supportingMedium)
                        .foregroundStyle(muted && !selected ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let desc {
                        Text(desc)
                            .font(PickyHUDTypography.status)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let key { Keycap(text: key) }
            }
            accessory().padding(.leading, 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                .fill(selected ? DS.Colors.accentSubtle : (hovered ? DS.Colors.surface3 : density.rowFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous)
                .stroke(selected ? DS.Colors.accent.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: selected ? 1 : 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.compact + 2, style: .continuous)
                .stroke(DS.Colors.accent.opacity(focused ? 0.5 : 0), lineWidth: 2)
                .padding(-2)
        )
    }
}

struct FieldBox: View {
    let value: String?
    let placeholder: String
    var caret = false
    var body: some View {
        HStack(spacing: 0) {
            Text(value ?? placeholder)
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(value == nil ? DS.Colors.textTertiary : DS.Colors.textPrimary)
            if caret { Rectangle().fill(DS.Colors.accent).frame(width: 1, height: 13).padding(.leading, 1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.compact, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 0.5))
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled = true
    var sending = false
    var body: some View {
        HStack(spacing: 4) {
            if sending {
                Circle().trim(from: 0, to: 0.7)
                    .stroke(DS.Colors.disabledText, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 10, height: 10)
            }
            Text(title)
        }
        .font(PickyHUDTypography.supportingSemibold)
        .foregroundStyle(enabled ? DS.Colors.textOnAccent : DS.Colors.disabledText)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(enabled ? DS.Colors.accent : DS.Colors.disabledBackground))
    }
}

struct SecondaryButton: View {
    let title: String
    var body: some View {
        Text(title)
            .font(PickyHUDTypography.supportingMedium)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(DS.Colors.surface1))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 0.5))
    }
}

struct GhostButton: View {
    let title: String
    var key: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(PickyHUDTypography.supportingMedium).foregroundStyle(DS.Colors.textSecondary)
            if let key { Keycap(text: key) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

struct StepProgress: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index < current ? DS.Colors.accent : (index == current ? DS.Colors.accent.opacity(0.45) : DS.Colors.borderSubtle))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AnswerChip: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(DS.Colors.textSecondary)
            Text(value).fontWeight(.semibold).foregroundStyle(DS.Colors.textPrimary)
        }
        .font(PickyHUDTypography.metaMedium)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
    }
}

/// One body for both shells: title, progress, previous answers, current question.
struct ProposalQuestionBody: View {
    let model: FormModel
    let density: Density
    var showsKeys = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(PickyHUDTypography.bodySemibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = model.description {
                    Text(description)
                        .font(PickyHUDTypography.supporting)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let step = model.step { StepProgress(current: step.0, total: step.1) }
            if !model.previous.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(model.previous.enumerated()), id: \.offset) { _, pair in
                        AnswerChip(label: pair.0, value: pair.1)
                    }
                }
            }
            if let question = model.question { questionView(question) }
            if !model.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.chips, id: \.self) { chip in
                        Text(chip)
                            .font(PickyHUDTypography.supportingMedium)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(density.rowFill))
                            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).strokeBorder(DS.Colors.borderStrong, lineWidth: 0.5))
                    }
                    if let skip = model.footer.skip { GhostButton(title: skip) }
                }
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: QModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.prompt != nil || question.kind == .checkbox || question.required {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let prompt = question.prompt {
                        Text(prompt)
                            .font(PickyHUDTypography.supportingSemibold)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if question.required {
                        Text("필수").font(PickyHUDTypography.meta).foregroundStyle(DS.Colors.destructiveText)
                    } else if question.kind == .checkbox {
                        Text("여러 개 고를 수 있어요").font(PickyHUDTypography.meta).foregroundStyle(DS.Colors.textTertiary)
                    }
                }
            }
            switch question.kind {
            case .text:
                FieldBox(value: question.textValue, placeholder: question.placeholder)
            case .radio, .checkbox:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        OptionRow(kind: question.kind, label: option.label, desc: option.desc,
                                  selected: option.selected, focused: option.focused, hovered: option.hovered,
                                  key: showsKeys ? "\(index + 1)" : nil, density: density) { EmptyView() }
                    }
                    otherRow(question)
                }
            }
        }
    }

    @ViewBuilder
    private func otherRow(_ question: QModel) -> some View {
        let key = showsKeys ? "\(question.options.count + 1)" : nil
        switch question.other {
        case .hidden:
            EmptyView()
        case .idle:
            OptionRow(kind: question.kind, label: "직접 입력", selected: false, muted: true, key: key, density: density) { EmptyView() }
        case .typing(let value):
            OptionRow(kind: question.kind, label: "직접 입력", selected: true, focused: true, muted: true, key: key, density: density) {
                FieldBox(value: value, placeholder: "", caret: true)
            }
        }
    }
}

struct ProposalFooter: View {
    let footer: FooterModel
    var skipKey: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            switch footer.hint {
            case .none: EmptyView()
            case .keys(let text):
                Text(text).font(PickyHUDTypography.meta).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
            case .required:
                Text("필수 항목을 입력해 주세요").font(PickyHUDTypography.meta).foregroundStyle(DS.Colors.destructiveText).lineLimit(1)
            case .failed:
                HStack(spacing: 6) {
                    Text("답변을 보내지 못했어요.").foregroundStyle(DS.Colors.destructiveText)
                    Text("다시 시도").foregroundStyle(DS.Colors.accentText)
                }
                .font(PickyHUDTypography.supportingMedium)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let skip = footer.skip { GhostButton(title: skip, key: skipKey) }
            if footer.back { SecondaryButton(title: "이전") }
            if !footer.primary.isEmpty {
                PrimaryButton(title: footer.primary, enabled: footer.primaryEnabled && !footer.sending, sending: footer.sending)
            }
        }
    }
}

// MARK: - Shell 1: Pickle conversation bubble

enum BubbleState { case active, sending, answered(summary: String, rows: [(String, String)]?), skipped }

struct HeaderLabel: View {
    let symbol: String
    let text: String
    let color: Color
    var textColor: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            Text(Image(systemName: symbol)).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(text).font(PickyHUDTypography.metaSemibold).foregroundStyle(textColor ?? color)
        }
    }
}

struct ProposalPickleBubble: View {
    let model: FormModel
    var state: BubbleState = .active
    @Environment(\.pickyHUDDetailWidth) private var detailWidth

    private var isClosed: Bool {
        switch state { case .answered, .skipped: true; default: false }
    }

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: isClosed ? 6 : 10) {
                header
                switch state {
                case .active, .sending:
                    ProposalQuestionBody(model: model, density: .pickle)
                        .opacity(isSending ? 0.55 : 1)
                    if model.chips.isEmpty { ProposalFooter(footer: model.footer) }
                case .answered(_, let rows?):
                    Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 3) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.0).font(PickyHUDTypography.meta).foregroundStyle(DS.Colors.textTertiary)
                                Text(row.1).font(PickyHUDTypography.metaMedium).foregroundStyle(DS.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.leading, 18)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, isClosed ? 10 : 12)
            .padding(.top, isClosed ? 7 : 10)
            .padding(.bottom, isClosed ? 7 : 12)
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: detailWidth, fraction: 0.88, oppositeSideReserve: 36),
                   alignment: .leading)
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
    }

    private var isSending: Bool { if case .sending = state { return true }; return false }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            switch state {
            case .active, .sending:
                HeaderLabel(symbol: "questionmark.circle", text: "입력이 필요해요", color: DS.Colors.accentText)
                Spacer(minLength: 4)
                if let step = model.step {
                    Text("\(step.0) / \(step.1)").font(PickyHUDTypography.metaMonospacedMedium).foregroundStyle(DS.Colors.textTertiary)
                }
            case .answered(let summary, let rows):
                HeaderLabel(symbol: "checkmark.circle", text: "답변 완료", color: DS.Colors.successText, textColor: DS.Colors.textSecondary)
                Text("· \(rows == nil ? summary : model.title)")
                    .font(PickyHUDTypography.metaMedium).foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Image(systemName: rows == nil ? "chevron.right" : "chevron.down"))
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Colors.textTertiary)
            case .skipped:
                HeaderLabel(symbol: "minus.circle", text: "건너뜀", color: DS.Colors.textTertiary, textColor: DS.Colors.textSecondary)
                Text("· \(model.title)").font(PickyHUDTypography.metaMedium).foregroundStyle(DS.Colors.textTertiary).lineLimit(1)
                Spacer(minLength: 4)
                Text(Image(systemName: "chevron.right")).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }
}

// MARK: - Shell 2: main Picky cursor panel

struct ProposalMainPanel: View {
    let model: FormModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Capsule(style: .continuous)
                .fill(DS.Colors.textPrimary.opacity(0.18))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                HeaderLabel(symbol: "questionmark.circle.fill", text: "Picky가 물어봐요", color: DS.Colors.accentText)
                Spacer(minLength: 4)
                if let step = model.step {
                    Text("\(step.0) / \(step.1)").font(PickyHUDTypography.metaMonospacedMedium).foregroundStyle(DS.Colors.textTertiary)
                }
            }
            ProposalQuestionBody(model: model, density: .panel)
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(DS.Colors.borderSubtle)
                HStack(spacing: 5) {
                    Text(Image(systemName: "mic")).font(.system(size: 10, weight: .medium))
                    Text("말로 답해도 돼요")
                }
                .font(PickyHUDTypography.meta)
                .foregroundStyle(DS.Colors.textTertiary)
                ProposalFooter(footer: model.footer, skipKey: "esc")
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
}

// MARK: - Fixtures

enum Fixtures {
    static let releaseQuestions: [PickyExtensionUiQuestion] = [
        .init(id: "version", type: .radio, prompt: "어떤 버전으로 올릴까요?", label: "버전",
              options: [.init(value: "0.9.3-beta.2", label: "0.9.3-beta.2", description: "베타 채널만 갱신해요"),
                        .init(value: "0.9.3", label: "0.9.3", description: "정식 채널에 바로 올려요")],
              allowOther: nil, required: true, placeholder: nil, defaultValue: .string("0.9.3-beta.2")),
        .init(id: "notes", type: .checkbox, prompt: "릴리즈 노트에 넣을 항목을 고르세요.", label: "노트",
              options: [.init(value: "lag", label: "HUD 렉 수정"), .init(value: "schedule", label: "보낼 시점 메뉴"),
                        .init(value: "refactor", label: "내부 리팩터링", description: "사용자에게 보이는 변화 없음")],
              allowOther: nil, required: true, placeholder: nil, defaultValue: .array([.string("lag"), .string("schedule")])),
        .init(id: "memo", type: .text, prompt: "알파 테스터 공지 문구", label: "공지",
              options: nil, allowOther: nil, required: true, placeholder: nil, defaultValue: nil),
    ]

    static func releaseRequest(id: String = "q-release") -> PickyExtensionUiRequest {
        .init(id: id, sessionId: "proposal", method: "askUserQuestion", title: "릴리즈 범위를 정해 주세요",
              questions: releaseQuestions, createdAt: Date(timeIntervalSince1970: 1))
    }

    static let testOptions = [
        QOption(label: "픽스처를 고치고 다시 돌리기", desc: "추천 · 원인이 fake timer 누락으로 보여요", selected: true, focused: true),
        QOption(label: "테스트는 건너뛰고 원인만 보고"),
        QOption(label: "세션 로그부터 더 조사", hovered: true),
    ]

    static let single = FormModel(
        title: "실패한 테스트를 어떻게 처리할까요?",
        description: "SessionSupervisor 테스트 2개가 타임아웃으로 실패했어요.",
        question: QModel(prompt: nil, kind: .radio, options: testOptions, other: .idle),
        footer: FooterModel(hint: .keys("↩ 제출"))
    )

    static let stepTwo = FormModel(
        title: "릴리즈 범위를 정해 주세요",
        step: (2, 3),
        previous: [("버전", "0.9.3-beta.2")],
        question: QModel(prompt: "릴리즈 노트에 넣을 항목", kind: .checkbox, options: [
            QOption(label: "HUD 렉 수정", selected: true),
            QOption(label: "보낼 시점 메뉴", selected: true),
            QOption(label: "내부 리팩터링", desc: "사용자에게 보이는 변화 없음"),
        ], other: .typing("표 렌더링 지원")),
        footer: FooterModel(primary: "다음", back: true, skip: nil, hint: .keys("↩ 다음"))
    )

    static let stepThreeRequired = FormModel(
        title: "릴리즈 범위를 정해 주세요",
        step: (3, 3),
        previous: [("버전", "0.9.3-beta.2"), ("노트", "HUD 렉 수정 외 2개")],
        question: QModel(prompt: "알파 테스터 공지 문구", kind: .text, required: true),
        footer: FooterModel(primaryEnabled: false, back: true, skip: nil, hint: .required)
    )

    static let confirm = FormModel(
        title: "변경 사항을 커밋할까요?",
        description: "수정된 파일 3개가 있어요.",
        footer: FooterModel(primary: "허용", skip: "취소", hint: .keys("↩ 허용"))
    )

    static let select = FormModel(
        title: "어느 브랜치에 올릴까요?",
        chips: ["main", "develop"],
        footer: FooterModel(primary: "", skip: "건너뛰기")
    )

    static let versionSending = FormModel(
        title: "어떤 버전으로 올릴까요?",
        question: QModel(prompt: nil, kind: .radio, options: [QOption(label: "0.9.3-beta.2", selected: true), QOption(label: "0.9.3")]),
        footer: FooterModel(sending: true, skip: nil)
    )

    static let versionFailed = FormModel(
        title: "어떤 버전으로 올릴까요?",
        question: QModel(prompt: nil, kind: .radio, options: [QOption(label: "0.9.3-beta.2", selected: true), QOption(label: "0.9.3")]),
        footer: FooterModel(skip: nil, hint: .failed)
    )

    static let answeredRows = [("버전", "0.9.3-beta.2"), ("노트", "HUD 렉 수정, 보낼 시점 메뉴, 표 렌더링 지원"), ("공지", "알파 테스터에게 먼저 공지하고 금요일에 정식 배포")]

    // Main panel variants: number keys still apply, ↩ hint lives on primary.
    static func panel(_ model: FormModel) -> FormModel {
        var copy = model
        if copy.footer.skip == nil, copy.footer.back == false { copy.footer.skip = "건너뛰기" }
        if case .keys = copy.footer.hint { copy.footer.hint = .none }
        return copy
    }

    static let mainSingle = FormModel(
        title: "이 Slack 스레드를 어디로 넘길까요?",
        description: "결제 오류 제보 3건이 한 스레드에 모여 있어요.",
        question: QModel(prompt: nil, kind: .radio, options: [
            QOption(label: "새 Pickle로 조사 시작", desc: "creatrip/product 기준", selected: true, focused: true),
            QOption(label: "진행 중인 ‘결제 장애’ Pickle에 보내기"),
            QOption(label: "요약만 해서 DM으로 보내기"),
        ], other: .idle),
        footer: FooterModel(skip: "건너뛰기")
    )
}

// MARK: - Scenes

struct SceneSpec {
    enum Kind {
        case pickle([AnyView])
        case panel(AnyView)
    }
    let id: String
    let title: String
    let note: String
    let kind: Kind
}

@MainActor final class Fixture {
    let client = FakePickyAgentClient()
    lazy var commands = PickySessionListViewModel(client: client)
}

struct PickleStage: View {
    let bubbles: [AnyView]
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            ForEach(Array(bubbles.enumerated()), id: \.offset) { _, bubble in bubble }
        }
        .padding(.horizontal, PickyHUDDockLayout.detailHorizontalPadding)
        .padding(.vertical, DS.Spacing.space3)
        .frame(width: width, alignment: .leading)
        .background(DS.Colors.surface1)
        .environment(\.pickyHUDDetailWidth, width)
    }
}

struct PanelStage: View {
    let panel: AnyView
    var body: some View {
        panel
            .padding(DS.Spacing.space3)
            .background(DS.Colors.background)
    }
}

@main struct Render {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared // Never activate, show a window, or launch Picky.
        NSApp.setActivationPolicy(.prohibited)
        let fixture = Fixture()

        let mainBefore = PickyMainQuestionPanelViewModel()
        mainBefore.configure(request: Fixtures.releaseRequest(id: "main-before"))
        mainBefore.goNext()
        mainBefore.formState.otherValues[PickyAskUserQuestionFormState.key(for: Fixtures.releaseQuestions[1], index: 1)] = "표 렌더링 지원"

        let mainBeforeSingle = PickyMainQuestionPanelViewModel()
        mainBeforeSingle.configure(request: .init(
            id: "main-before-single", sessionId: "main", method: "askUserQuestion",
            title: "이 Slack 스레드를 어디로 넘길까요?", description: "결제 오류 제보 3건이 한 스레드에 모여 있어요.",
            questions: [.init(id: "route", type: .radio, prompt: "넘길 곳", label: nil,
                              options: [.init(value: "new", label: "새 Pickle로 조사 시작", description: "creatrip/product 기준"),
                                        .init(value: "existing", label: "진행 중인 ‘결제 장애’ Pickle에 보내기"),
                                        .init(value: "dm", label: "요약만 해서 DM으로 보내기")],
                              allowOther: nil, required: true, placeholder: nil, defaultValue: .string("new"))],
            createdAt: Date(timeIntervalSince1970: 1)))

        let scenes: [SceneSpec] = [
            .init(id: "pickle-00-before-form", title: "피클 · 현재 (production)",
                  note: "production PickyQuestionBubbleView. 질문 3개를 한 버블에 쌓고, 머리줄에 method 이름, warning 틀, 같은 모양의 radio/checkbox, 늘 보이는 기타 입력칸.",
                  kind: .pickle([AnyView(PickyQuestionBubbleView(request: Fixtures.releaseRequest(), cancelledAt: nil, isActiveRequest: true, commands: fixture.commands))])),
            .init(id: "pickle-00-before-closed", title: "피클 · 현재 답변 뒤 (production)",
                  note: "production PickyQuestionBubbleView, isActiveRequest=false. 오프스크린에서는 onAppear 접힘이 적용되지 않을 수 있어 펼친 채로 보일 수 있다. 어느 쪽이든 고른 답은 남지 않는다.",
                  kind: .pickle([AnyView(PickyQuestionBubbleView(request: Fixtures.releaseRequest(id: "q-closed"), cancelledAt: nil, isActiveRequest: false, commands: fixture.commands))])),
            .init(id: "pickle-01-single", title: "피클 · 질문 1개, 하나 선택",
                  note: "method 이름 제거, 파란 테두리, 원 표시, 숫자 키, 직접 입력 행, 제출=주 버튼·건너뛰기=글자 버튼. 첫 행은 포커스, 셋째 행은 hover 표시.",
                  kind: .pickle([AnyView(ProposalPickleBubble(model: Fixtures.single))])),
            .init(id: "pickle-02-step", title: "피클 · 질문 3개 중 2단계",
                  note: "질문 2개 이상이면 단계 진행. 앞 답은 칩, 네모 표시와 복수 선택 힌트, 직접 입력 행 안에 입력칸.",
                  kind: .pickle([AnyView(ProposalPickleBubble(model: Fixtures.stepTwo))])),
            .init(id: "pickle-03-required", title: "피클 · 마지막 단계, 필수 비어 있음",
                  note: "제출이 꺼진 이유를 버튼 옆에 표시한다. 필수 질문에만 '필수'를 붙인다.",
                  kind: .pickle([AnyView(ProposalPickleBubble(model: Fixtures.stepThreeRequired))])),
            .init(id: "pickle-04-confirm-select", title: "피클 · confirm / 짧은 select",
                  note: "confirm은 허용이 주 버튼. 짧은 select는 누르면 바로 보내는 칩.",
                  kind: .pickle([AnyView(ProposalPickleBubble(model: Fixtures.confirm)), AnyView(ProposalPickleBubble(model: Fixtures.select))])),
            .init(id: "pickle-05-sending-failed", title: "피클 · 보내는 중 / 보내기 실패",
                  note: "보내는 동안 선택을 흐리게 유지하고 진행 표시는 제출 버튼 안에만. 실패하면 고른 답을 둔 채 다시 시도.",
                  kind: .pickle([AnyView(ProposalPickleBubble(model: Fixtures.versionSending, state: .sending)), AnyView(ProposalPickleBubble(model: Fixtures.versionFailed))])),
            .init(id: "pickle-06-answered", title: "피클 · 답변 뒤 접힘 / 펼침 / 건너뜀",
                  note: "접힌 줄에 고른 답 요약, 펼치면 질문·답 두 열. 취소는 '건너뜀'. 답 요약은 프로토콜에 answer 필드가 필요하다.",
                  kind: .pickle([
                    AnyView(ProposalPickleBubble(model: Fixtures.stepTwo, state: .answered(summary: "0.9.3-beta.2 · HUD 렉 수정 외 2개 · 알파 테스터에게…", rows: nil))),
                    AnyView(ProposalPickleBubble(model: Fixtures.stepTwo, state: .answered(summary: "", rows: Fixtures.answeredRows))),
                    AnyView(ProposalPickleBubble(model: Fixtures.single, state: .skipped)),
                  ])),
            .init(id: "main-00-before-single", title: "메인 Picky · 현재 질문 1개 (production)",
                  note: "production PickyMainQuestionPanelView. 커서 옆에 뜨지만 누가 묻는지 표시가 없고, 필수 '*'가 warning 색, 기타는 버튼+비활성 입력칸 두 벌, 건너뛰기는 흐린 'esc 취소' 글자뿐.",
                  kind: .panel(AnyView(PickyMainQuestionPanelView(viewModel: mainBeforeSingle)))),
            .init(id: "main-00-before-step", title: "메인 Picky · 현재 2단계 (production)",
                  note: "production PickyMainQuestionPanelView. 단계는 '2 / 3' 글자뿐이고 앞 단계 답이 보이지 않는다.",
                  kind: .panel(AnyView(PickyMainQuestionPanelView(viewModel: mainBefore)))),
            .init(id: "main-01-single", title: "메인 Picky · 질문 1개",
                  note: "'Picky가 물어봐요'로 출처를 밝힌다. 피클과 같은 본문 컴포넌트, 숫자 키, esc 건너뛰기, '말로 답해도 돼요' 안내.",
                  kind: .panel(AnyView(ProposalMainPanel(model: Fixtures.mainSingle)))),
            .init(id: "main-02-step", title: "메인 Picky · 2단계",
                  note: "단계 막대와 앞 답 칩. 피클 버블과 같은 규칙.",
                  kind: .panel(AnyView(ProposalMainPanel(model: Fixtures.panel(Fixtures.stepTwo))))),
            .init(id: "main-03-required", title: "메인 Picky · 필수 비어 있음",
                  note: "필수 안내를 warning 대신 destructiveText 한 줄로. 피클과 같은 문구.",
                  kind: .panel(AnyView(ProposalMainPanel(model: Fixtures.panel(Fixtures.stepThreeRequired))))),
            .init(id: "main-04-failed", title: "메인 Picky · 보내기 실패",
                  note: "패널을 닫지 않고 고른 답을 유지한 채 다시 시도(현재 동작 유지).",
                  kind: .panel(AnyView(ProposalMainPanel(model: Fixtures.panel(Fixtures.versionFailed))))),
        ]

        var manifest: [[String: Any]] = []
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            for scene in scenes {
                for light in [false, true] {
                    try render(scene, light: light, pickleWidth: PickyHUDDockLayout.detailWidth, fontScale: 1, fixture: fixture, output: output, manifest: &manifest)
                }
            }
        }
        try JSONSerialization.data(withJSONObject: [
            "renderer": "SwiftUI / NSHostingView; before = production PickyQuestionBubbleView & PickyMainQuestionPanelView; after = proposal views on production DS, PickyHUDTypography, bubble layout and panel metrics",
            "scenes": manifest,
        ], options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        print("Rendered \(manifest.count) SwiftUI scenes. No Picky app launch or daemon connection.")
    }

    @MainActor static func render(_ scene: SceneSpec, light: Bool, pickleWidth: CGFloat, fontScale: CGFloat, fixture: Fixture, output: URL, manifest: inout [[String: Any]]) throws {
        let content: AnyView
        switch scene.kind {
        case .pickle(let bubbles): content = AnyView(PickleStage(bubbles: bubbles, width: pickleWidth))
        case .panel(let panel): content = AnyView(PanelStage(panel: panel))
        }
        let view = content
            .environment(\.pickyAppFontScale, fontScale)
            .environment(\.locale, Locale(identifier: "ko"))
            .environment(\.colorScheme, light ? .light : .dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { throw NSError(domain: "Invalid geometry \(scene.id)", code: 1) }
        let bitmap = PickyRenderGalleryRasterizer.rasterize(view, logicalSize: size, scale: 2, appearance: light ? .aqua : .darkAqua)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = fontScale == 1 ? "" : "-scale130"
        let name = "\(scene.id)-\(light ? "light" : "dark")\(suffix).png"
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.contains("hud.question."), !text.contains("common.") else { throw NSError(domain: "Missing localized resources in \(scene.id)", code: 2) }
        guard fixture.client.sentCommands.isEmpty, fixture.client.submitted.isEmpty else { throw NSError(domain: "Unexpected runtime command", code: 4) }
        manifest.append(["id": scene.id + suffix, "title": scene.title + (fontScale == 1 ? "" : " (글자 130%)"), "note": scene.note, "file": name,
                         "appearance": light ? "light" : "dark", "width": size.width, "height": size.height,
                         "scale": fontScale, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "ocr": text])
        print("\(name): \(Int(size.width))×\(Int(size.height))pt")
    }
}
