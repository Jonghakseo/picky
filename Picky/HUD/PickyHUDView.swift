//
//  PickyHUDView.swift
//  Picky
//
//  SwiftUI composition for the long-running session HUD.
//

import SwiftUI

struct PickyHUDView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    var onSizeChange: (CGSize) -> Void = { _ in }
    @State private var expandedSessionID: String?

    private var visibleSessions: [PickySessionListViewModel.SessionCard] {
        Array(viewModel.sessions.prefix(6))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if visibleSessions.isEmpty {
                EmptyView()
            } else {
                ForEach(visibleSessions) { session in
                    PickySessionCardView(
                        session: session,
                        isExpanded: expandedSessionID == session.id,
                        viewModel: viewModel,
                        onToggle: {
                            expandedSessionID = expandedSessionID == session.id ? nil : session.id
                        }
                    )
                }
            }
        }
        .padding(PickyHUDExpansion.outerPadding)
        .background(PickyHUDSizeReader())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onPreferenceChange(PickyHUDSizePreferenceKey.self, perform: onSizeChange)
    }
}

private struct PickyHUDSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct PickyHUDSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PickyHUDSizePreferenceKey.self, value: proxy.size)
        }
    }
}

private struct PickyHUDCollapsibleContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct PickyHUDCollapsibleContent<Content: View>: View {
    let isExpanded: Bool
    private let content: Content
    @State private var measuredHeight: CGFloat = 0

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PickyHUDCollapsibleContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .frame(
                height: PickyHUDExpansion.contentFrameHeight(
                    isExpanded: isExpanded,
                    measuredHeight: measuredHeight
                ),
                alignment: .top
            )
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(PickyHUDExpansion.animation, value: isExpanded)
            .onPreferenceChange(PickyHUDCollapsibleContentHeightPreferenceKey.self) { height in
                measuredHeight = height
            }
    }
}

private struct PickySessionCardView: View {
    let session: PickySessionListViewModel.SessionCard
    let isExpanded: Bool
    @ObservedObject var viewModel: PickySessionListViewModel
    let onToggle: () -> Void
    @State private var followUpText = ""
    @State private var isVoiceFollowUpButtonPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHUDExpansion.cardSpacing(isExpanded: isExpanded)) {
            header
            PickyHUDCollapsibleContent(isExpanded: isExpanded) {
                expandedContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, PickyHUDExpansion.cardVerticalPadding(isExpanded: isExpanded))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 1))
                .shadow(
                    color: Color.black.opacity(PickyHUDExpansion.cardShadowOpacity),
                    radius: PickyHUDExpansion.cardShadowRadius,
                    x: 0,
                    y: PickyHUDExpansion.cardShadowYOffset
                )
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(session.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(PickyHUDExpansion.animation, value: isExpanded)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.35)

            if let cwd = session.cwd, !cwd.isEmpty {
                metaRow(icon: "folder", text: "CWD  \(cwd)")
            }
            metaRow(icon: "clock", text: session.elapsedDescription())

            if let pending = session.pendingExtensionUiRequest {
                PickyPendingInputView(request: pending, viewModel: viewModel)
            }

            if PickyHUDExpandedContentPolicy.showsSummary(for: session.status), !session.lastSummary.isEmpty {
                detailSection(
                    title: "Summary",
                    text: session.lastSummary,
                    lineLimit: PickyHUDExpandedContentPolicy.summaryLineLimit
                )
            }

            if PickyHUDExpandedContentPolicy.showsRecentLog, !session.logPreview.isEmpty {
                detailSection(title: "Recent log", text: session.logPreview)
            }

            if !session.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    detailTitle("Changed files")
                    ForEach(session.changedFiles.prefix(4), id: \.path) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(file.status) · \(file.path)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                            if let summary = file.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            let diffArtifacts = session.artifacts.filter { $0.kind == "diff" }
            if !diffArtifacts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    detailTitle("Diff preview")
                    ForEach(diffArtifacts.prefix(2)) { artifact in
                        Text(artifact.title)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            if !session.prArtifacts.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.prArtifacts) { artifact in
                        Text(artifact.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DS.Colors.accentSubtle))
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Follow up…", text: $followUpText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitFollowUp() }
                iconButton(
                    systemName: "paperplane.fill",
                    help: "Send follow-up",
                    disabled: followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submitFollowUp
                )
            }

            HStack(spacing: 10) {
                iconButton(systemName: "doc.text.magnifyingglass", help: "Open report", disabled: session.reportArtifact == nil) {
                    Task { try? await viewModel.openReport(sessionID: session.id) }
                }
                iconButton(systemName: "terminal", help: "Resume in Ghostty", disabled: session.piSessionFilePath == nil || session.status == .running) {
                    viewModel.resumeInGhostty(sessionID: session.id)
                }
                voiceFollowUpHoldButton
                iconButton(systemName: "stop.circle", help: "Stop session", disabled: session.status.isTerminal) {
                    Task { try? await viewModel.abort(sessionID: session.id) }
                }
                iconButton(systemName: "doc.on.doc", help: "Copy summary") {
                    viewModel.copySummary(sessionID: session.id)
                }
                iconButton(systemName: "archivebox", help: "Archive session") {
                    viewModel.archive(sessionID: session.id)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var voiceFollowUpHoldButton: some View {
        let isActive = viewModel.activeVoiceFollowUpSessionID == session.id || isVoiceFollowUpButtonPressed
        return Image(systemName: "text.bubble")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 18, height: 18)
            .foregroundColor(isActive ? DS.Colors.accentText : DS.Colors.textSecondary)
            .opacity(session.status == .running ? 0.85 : 1)
            .background(
                Circle()
                    .fill(isActive ? DS.Colors.accentSubtle.opacity(0.9) : Color.clear)
                    .frame(width: 24, height: 24)
            )
            .contentShape(Rectangle())
            .help("Hold for voice follow-up")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isVoiceFollowUpButtonPressed else { return }
                        isVoiceFollowUpButtonPressed = true
                        viewModel.beginVoiceFollowUp(sessionID: session.id)
                    }
                    .onEnded { _ in
                        isVoiceFollowUpButtonPressed = false
                        viewModel.endVoiceFollowUp(sessionID: session.id)
                    }
            )
            .onDisappear {
                if isVoiceFollowUpButtonPressed {
                    isVoiceFollowUpButtonPressed = false
                    viewModel.endVoiceFollowUp(sessionID: session.id)
                }
            }
    }

    private func submitFollowUp() {
        let text = followUpText
        followUpText = ""
        Task { try? await viewModel.followUp(text: text, sessionID: session.id) }
    }

    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
        .foregroundColor(DS.Colors.textTertiary)
    }

    private func detailSection(title: String, text: String, lineLimit: Int? = 3) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            detailTitle(title)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(lineLimit)
        }
    }

    private func detailTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func iconButton(systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.textSecondary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
    }

    private var statusColor: Color {
        switch session.status.hudTone {
        case .inProgress: DS.Colors.warning
        case .error: DS.Colors.destructiveText
        case .completed: DS.Colors.success
        case .other: DS.Colors.accentText
        }
    }
}

private struct PickyPendingInputView: View {
    let request: PickyExtensionUiRequest
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var textValue = ""
    @State private var formState = PickyAskUserQuestionFormState()
    @State private var seededFormRequestID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for input")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.warning)
            Text(request.prompt ?? request.title ?? request.method)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(3)
            if request.method == "askUserQuestion", let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
            }
            controls
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.warning.opacity(0.12)))
        .onAppear { seedFormDefaultsIfNeeded() }
        .onChange(of: request.id) { _ in
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
                Text(label)
                    .font(.system(size: 11, weight: .medium))
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
        Binding(
            get: { dictionary.wrappedValue[key] ?? "" },
            set: { dictionary.wrappedValue[key] = $0 }
        )
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


#Preview("Picky HUD") {
    PickyHUDView(viewModel: PickySessionListViewModel(client: LocalStubPickyAgentClient(), notificationCenter: PickyNoopNotificationCenter()))
}
