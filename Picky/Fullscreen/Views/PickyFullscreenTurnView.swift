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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let userMessage = turn.userMessage {
                PickyUserBubbleView(
                    message: userMessage,
                    onOpenAsReport: openMessageReportAction(for: userMessage),
                    onCopyText: { viewModel.copyMessageText($0) },
                    onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
                )
            }

            if turn.isCurrent, let liveActivitySummary = turn.liveActivitySummary, !liveActivitySummary.visibleToolCallItems.isEmpty {
                PickyActivitySummaryView(summary: liveActivitySummary) {
                    viewModel.openToolHistoryForCurrentTurn(sessionID: session.id)
                }
            }

            ForEach(turn.bodyMessages, id: \.id) { message in
                messageView(message)
            }

            ForEach(turn.statusMessages, id: \.id) { message in
                statusMessageView(message)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage) -> some View {
        switch message.kind {
        case .agentText:
            PickyFullscreenAgentMessageView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message),
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
                onOpenAsReport: openMessageReportAction(for: message),
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
                onOpenAsReport: openMessageReportAction(for: message)
            )
        }
    }

    private func openMessageReportAction(for message: PickySessionMessage) -> (() -> Void)? {
        guard message.openAsReportMarkdown != nil else { return nil }
        let sessionID = session.id
        let messageID = message.id
        return { [weak viewModel] in
            Task { try? await viewModel?.openReport(sessionID: sessionID, messageID: messageID) }
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

private struct PickyFullscreenAgentMessageView: View {
    let message: PickySessionMessage
    var onOpenAsReport: (() -> Void)? = nil
    var onCopyText: ((String) -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            PickyAgentBubbleSurfaceView(
                markdown: displayText,
                maxBubbleWidth: bubbleMaxWidth,
                showsShortcutBadge: false,
                onOpenAsReport: onOpenAsReport,
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
