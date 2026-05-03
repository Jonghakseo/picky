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
    @State private var gitStatus: PickyGitRepositoryStatus?
    @State private var isGitSectionExpanded = true

    private var isVoiceFollowUpTarget: Bool {
        viewModel.hoveredVoiceFollowUpSessionID == session.id
    }

    private var gitStatusRefreshKey: String {
        "\(session.cwd ?? "")|\(session.updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHUDExpansion.cardSpacing(isExpanded: isExpanded)) {
            header
            PickyHUDCollapsibleContent(isExpanded: isExpanded) {
                expandedContent
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, PickyHUDExpansion.cardVerticalPadding(isExpanded: isExpanded))
        .background(cardBackground)
        .onHover { isHovering in
            if isHovering {
                viewModel.beginHoveredVoiceFollowUp(sessionID: session.id)
            } else {
                viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
            }
        }
        .onDisappear {
            viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
        }
        .task(id: gitStatusRefreshKey) {
            let loadedStatus = await PickyGitRepositoryStatus.load(cwd: session.cwd)
            guard !Task.isCancelled else { return }
            gitStatus = loadedStatus
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            PickyHUDStatusBadgeView(color: statusColor, isActive: session.status == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isVoiceFollowUpTarget {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.Colors.accentSubtle.opacity(0.95)))
                    .help("Voice steering target")
                    .transition(.scale.combined(with: .opacity))
            }
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

            if let compactCwd = session.compactCwdDescription {
                metaRow(icon: "folder", text: compactCwd)
            }

            if let gitStatus {
                gitStatusSection(gitStatus)
            }

            if let lastRequestText = session.lastRequestText {
                lastRequestBubble(text: lastRequestText)
            }

            if let currentWorkDescription {
                detailSection(title: "Current work", text: currentWorkDescription, lineLimit: 2)
            }

            if let pending = session.pendingExtensionUiRequest {
                PickyPendingInputView(request: pending, viewModel: viewModel)
            }

            if PickyHUDExpandedContentPolicy.showsSummary(for: session.status), !session.lastSummary.isEmpty {
                assistantSummaryBubble(text: session.lastSummary)
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
                TextField("Steer this agent…", text: $followUpText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { submitFollowUp() }
                iconButton(
                    systemName: "paperplane.fill",
                    help: "Send steering message",
                    disabled: followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submitFollowUp
                )
            }

            HStack(spacing: 10) {
                iconButton(systemName: "doc.text.magnifyingglass", help: "Open report", disabled: session.reportArtifact == nil) {
                    Task { try? await viewModel.openReport(sessionID: session.id) }
                }
                iconButton(systemName: "doc.on.doc", help: "Copy Pi resume command", disabled: session.piSessionFilePath == nil) {
                    viewModel.copyTerminalResumeCommand(sessionID: session.id)
                }
                iconButton(systemName: "terminal", help: "Open Pi terminal", disabled: session.piSessionFilePath == nil || session.status.blocksTerminalOverlay) {
                    viewModel.openTerminalOverlay(sessionID: session.id)
                }
                if let notifyMainOnCompletion = session.notifyMainOnCompletion {
                    iconButton(
                        systemName: notifyMainOnCompletion ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                        help: notifyMainOnCompletion ? "Tell main agent when this side task finishes" : "Keep completion on this side card only"
                    ) {
                        Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: !notifyMainOnCompletion) }
                    }
                }
                iconButton(systemName: "stop.circle", help: "Stop session", disabled: session.status.isTerminal) {
                    Task { try? await viewModel.abort(sessionID: session.id) }
                }
                iconButton(systemName: "archivebox", help: "Archive session") {
                    viewModel.archive(sessionID: session.id)
                }
                Spacer(minLength: 0)
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
                .truncationMode(.middle)
        }
        .foregroundColor(DS.Colors.textTertiary)
    }

    private func gitStatusSection(_ status: PickyGitRepositoryStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(PickyHUDExpansion.animation) {
                    isGitSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .rotationEffect(.degrees(isGitSectionExpanded ? 90 : 0))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DS.Colors.success.opacity(0.92))
                    Text(status.repositoryDisplayName)
                        .font(.system(size: 10.8, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isGitSectionExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.branchDisplayName)
                        .font(.system(size: 10.4, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if status.hasVisibleMetrics {
                        HStack(spacing: 6) {
                            if status.insertions > 0 {
                                gitMetricPill("+\(status.insertions)", color: DS.Colors.success)
                            }
                            if status.deletions > 0 {
                                gitMetricPill("-\(status.deletions)", color: DS.Colors.destructiveText)
                            }
                            if status.aheadCount > 0 {
                                gitMetricPill("↑\(status.aheadCount)", color: DS.Colors.accentText)
                            }
                            if status.behindCount > 0 {
                                gitMetricPill("↓\(status.behindCount)", color: DS.Colors.warningText)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8))
        )
    }

    private func gitMetricPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.2, weight: .semibold, design: .monospaced))
            .foregroundColor(color.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
    }

    private func lastRequestBubble(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.accentText.opacity(0.9))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.62))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8))
            )
        }
    }

    private func assistantSummaryBubble(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.success.opacity(0.9))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(PickyHUDExpandedContentPolicy.summaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.success.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Colors.success.opacity(0.18), lineWidth: 0.8))
            )
        }
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(session.status == .completed ? 0.88 : 0.95))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(statusColor.opacity(cardTintOpacity)))
            .overlay {
                if usesAnimatedStatusBorder {
                    PickyHUDAnimatedStatusBorderView(
                        baseColor: statusColor,
                        highlightColor: statusLoadingHighlightColor,
                        duration: statusBorderAnimationDuration
                    )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(cardBorderColor, lineWidth: 1)
                }
            }
            .shadow(
                color: Color.black.opacity(PickyHUDExpansion.cardShadowOpacity),
                radius: PickyHUDExpansion.cardShadowRadius,
                x: 0,
                y: PickyHUDExpansion.cardShadowYOffset
            )
    }

    private var headerSubtitle: String {
        let elapsed = session.elapsedDescription()
        switch session.status {
        case .queued:
            return "queued · \(elapsed)"
        case .running:
            if let activeTool = session.activeTool {
                return "\(activeTool.name) · \(elapsed)"
            }
            return "working · \(elapsed)"
        case .waiting_for_input:
            return "input needed · \(elapsed)"
        case .blocked:
            return session.isRuntimeDetached ? "detached · resume needed · \(elapsed)" : "blocked · \(elapsed)"
        case .completed:
            return session.reportArtifact == nil ? "completed · \(elapsed)" : "report ready · \(elapsed)"
        case .failed:
            return "failed · \(elapsed)"
        case .cancelled:
            return "cancelled · \(elapsed)"
        }
    }

    private var currentWorkDescription: String? {
        guard session.status == .running else { return nil }
        return PickyHUDCurrentWorkPolicy.runningDescription(
            activeTool: session.activeTool,
            thinkingPreview: session.thinkingPreview
        )
    }

    private var cardTintOpacity: Double {
        switch session.status {
        case .running: 0.055
        case .queued: 0.035
        case .waiting_for_input: 0.08
        case .blocked, .failed: 0.07
        case .completed: 0.03
        case .cancelled: 0.02
        }
    }

    private var usesAnimatedStatusBorder: Bool {
        session.status == .queued || session.status == .running
    }

    private var statusBorderAnimationDuration: Double {
        session.status == .running ? 2.4 : 4.2
    }

    private var statusLoadingHighlightColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .queued:
            return DS.Colors.floatingGradientPurple
        default:
            return statusColor
        }
    }

    private var cardBorderColor: Color {
        if isVoiceFollowUpTarget {
            return DS.Colors.accentText.opacity(0.72)
        }

        switch session.status {
        case .waiting_for_input:
            return DS.Colors.warning.opacity(0.55)
        case .blocked:
            return DS.Colors.warningText.opacity(0.55)
        case .failed:
            return DS.Colors.destructiveText.opacity(0.55)
        case .completed:
            return DS.Colors.success.opacity(0.42)
        case .running:
            return statusColor.opacity(0.50)
        case .queued, .cancelled:
            return DS.Colors.borderSubtle.opacity(0.65)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return DS.Colors.accentText
        case .running:
            return DS.Colors.overlayCursorBlue
        case .waiting_for_input:
            return DS.Colors.warning
        case .blocked:
            return DS.Colors.warningText
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }
}

private struct PickyHUDAnimatedStatusBorderView: View {
    let baseColor: Color
    let highlightColor: Color
    let duration: Double
    @State private var isFlowing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(baseColor.opacity(0.24), lineWidth: 1)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: baseColor.opacity(0.20), location: 0.00),
                            .init(color: highlightColor.opacity(0.85), location: 0.11),
                            .init(color: Color.white.opacity(0.64), location: 0.17),
                            .init(color: baseColor.opacity(0.86), location: 0.24),
                            .init(color: baseColor.opacity(0.18), location: 0.42),
                            .init(color: highlightColor.opacity(0.30), location: 0.62),
                            .init(color: highlightColor.opacity(0.82), location: 0.79),
                            .init(color: baseColor.opacity(0.24), location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(isFlowing ? 360 : 0)
                    ),
                    lineWidth: 1.45
                )
                .shadow(color: highlightColor.opacity(0.26), radius: 3.4, x: 0, y: 0)
        }
        .onAppear {
            guard !isFlowing else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                isFlowing = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PickyHUDStatusBadgeView: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isActive ? 0.16 : 0.10))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(isActive ? 0.70 : 0.45), lineWidth: 0.8)
            Image("PiSymbol")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundColor(color)
                .frame(width: 12.5, height: 12.5)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
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
