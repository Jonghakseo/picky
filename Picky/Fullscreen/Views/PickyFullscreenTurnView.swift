//
//  PickyFullscreenTurnView.swift
//  Picky
//
//  One fullscreen conversation turn rendered with a focused chat policy.
//

import SwiftUI

struct PickyFullscreenTurnView: View {
    let turn: PickyFullscreenTurnRenderModel
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    var isLastTurn = false
    var isWorkSummaryExpanded = false
    var onToggleWorkSummary: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let userMessage = turn.userMessage {
                PickyUserBubbleView(
                    message: userMessage,
                    onOpenAsReport: nil,
                    onCopyText: { viewModel.copyMessageText($0) },
                    onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
                )
            }

            if turn.isCurrent, let liveActivitySummary = turn.liveActivitySummary, !liveActivitySummary.visibleToolCallItems.isEmpty {
                PickyActivitySummaryView(summary: liveActivitySummary) {
                    viewModel.openToolHistoryForCurrentTurn(sessionID: session.id)
                }
            }

            if shouldShowWorkSummary {
                PickyFullscreenWorkSummaryView(
                    durationSeconds: turn.workDurationSeconds ?? 0,
                    messages: turn.intermediateMessages,
                    isExpanded: isWorkSummaryExpanded,
                    onToggle: onToggleWorkSummary ?? {},
                    messageView: { message in
                        AnyView(messageView(message))
                    }
                )
            }

            ForEach(turn.bodyMessages, id: \.id) { message in
                messageView(message)
            }

            ForEach(turn.statusMessages, id: \.id) { message in
                statusMessageView(message)
            }

            if shouldShowChangedFilesCard {
                PickyFullscreenChangedFilesCardView(changedFiles: session.changedFiles)
            }
        }
        .padding(.vertical, 4)
    }

    private var shouldShowChangedFilesCard: Bool {
        PickyFullscreenTurnPolicy.shouldShowSessionChangedFilesCard(
            isLastTurn: isLastTurn,
            isCurrentTurn: turn.isCurrent,
            sessionStatus: session.status,
            changedFilesCount: session.changedFiles.count
        )
    }

    private var shouldShowWorkSummary: Bool {
        !turn.isCurrent && turn.workDurationSeconds != nil && !turn.intermediateMessages.isEmpty
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage) -> some View {
        switch message.kind {
        case .agentText:
            PickyFullscreenAgentMessageView(
                message: message,
                onCopyText: { viewModel.copyMessageText($0) }
            )
        case .agentActivity:
            if let summary = message.activitySnapshot, !summary.visibleToolCallItems.isEmpty {
                PickyActivitySummaryView(summary: summary) {
                    viewModel.openToolHistoryForAgentActivity(sessionID: session.id, messageID: message.id)
                }
            }
        case .agentQuestion:
            if let request = message.question {
                PickyQuestionBubbleView(
                    request: request,
                    cancelledAt: message.cancelledAt,
                    isActiveRequest: session.pendingExtensionUiRequest?.id == request.id,
                    viewModel: viewModel
                )
            } else {
                PickyAgentBubbleView(message: message, onCopyText: { viewModel.copyMessageText($0) })
            }
        case .agentError:
            PickyErrorBubbleView(
                message: message,
                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) },
                onRetry: retryRuntimeRaceAction(for: message)
            )
        case .userText, .commandReceipt:
            PickyUserBubbleView(
                message: message,
                onOpenAsReport: nil,
                onCopyText: { viewModel.copyMessageText($0) },
                onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
            )
        case .system:
            statusMessageView(message)
        case .agentThinking:
            PickyTypingBubbleView(message: message, initiallyCollapsed: viewModel.thinkingBlocksHidden(sessionID: session.id))
        }
    }

    @ViewBuilder
    private func statusMessageView(_ message: PickySessionMessage) -> some View {
        if message.isCompactCompletionMessage {
            PickyCompactCompletionBubbleView()
        } else if message.isCompactFailureMessage {
            PickyCompactFailureBubbleView(message: message)
        } else if message.notifyType != nil {
            PickyNotifyBubbleView(
                message: message,
                onOpenAsReport: nil
            )
        }
    }



    private func retryRuntimeRaceAction(for message: PickySessionMessage) -> (() -> Void)? {
        guard PickyErrorBubbleView.isRecoverableRuntimeRace(errorMessage: message.errorMessage) else { return nil }
        guard let text = session.lastRequestText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return { [weak viewModel] in
            Task { try? await viewModel?.retryAfterRuntimeRace(sessionID: session.id) }
        }
    }
}

private struct PickyFullscreenWorkSummaryView: View {
    let durationSeconds: Int
    let messages: [PickySessionMessage]
    let isExpanded: Bool
    let onToggle: () -> Void
    let messageView: (PickySessionMessage) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 10, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 12, alignment: .center)
                    Text("\(Self.formatDuration(durationSeconds)) 동안 작업")
                        .font(PickyHUDTypography.labelMonospacedMedium)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(DS.Colors.surface2.opacity(0.86), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Self.formatDuration(durationSeconds)) 동안 작업")
            .accessibilityHint(isExpanded ? "작업 내역 접기" : "작업 내역 펼치기")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages, id: \.id) { message in
                        messageView(message)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(DS.Colors.surface1.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = seconds / 3_600
        let remainingMinutes = (seconds % 3_600) / 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

private struct PickyFullscreenAgentMessageView: View {
    let message: PickySessionMessage
    var onCopyText: ((String) -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            PickyAgentBubbleSurfaceView(
                markdown: displayText,
                maxBubbleWidth: bubbleMaxWidth,
                showsShortcutBadge: false,
                onOpenAsReport: nil,
                onCopyText: copyTextAction
            )
            .frame(width: bubbleMaxWidth, alignment: .leading)
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubbleMaxWidth: CGFloat {
        PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth, fraction: 0.86)
    }

    private var copyTextAction: (() -> Void)? {
        let text = displayText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onCopyText else { return nil }
        return { onCopyText(text) }
    }

    private var displayText: String {
        if let text = message.text, !text.isEmpty { return text }
        if let errorMessage = message.errorMessage, !errorMessage.isEmpty { return errorMessage }
        return ""
    }
}
