//
//  PickyConversationListView.swift
//  Picky
//
//  Message list for the conversation-style side-agent card.
//

import SwiftUI

struct PickyConversationListView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.messages.isEmpty && !hasQueueOrActivity {
                        Color.clear
                            .frame(height: 24)
                    } else {
                        ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowSeparator(before: index) {
                                PickyConversationTimeSeparatorView(text: separatorText(before: index))
                            }
                            messageView(message)
                                .id(message.id)
                        }
                        if shouldShowActivityStrip {
                            PickyActivitySummaryView(
                                summary: session.activitySummary,
                                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) }
                            )
                            .id("__activity__")
                        }
                        queueSection(items: session.queuedFollowUps, kind: .followUp, mode: session.followUpMode)
                        queueSection(items: session.queuedSteers, kind: .steer, mode: session.steeringMode)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
            .onAppear { scrollToLatest(proxy: proxy) }
            .onChange(of: session.messages.last?.id) { _, _ in
                scrollToLatest(proxy: proxy)
            }
        }
    }

    var renderSnapshot: PickyConversationListRenderSnapshot {
        var snapshot = PickyConversationListRenderSnapshot()
        snapshot.showsActivitySummary = shouldShowActivityStrip
        snapshot.batchGroupCount += session.followUpMode == .all && !session.queuedFollowUps.isEmpty ? 1 : 0
        snapshot.batchGroupCount += session.steeringMode == .all && !session.queuedSteers.isEmpty ? 1 : 0
        snapshot.pendingBubbleCount += session.followUpMode == .all ? 0 : session.queuedFollowUps.count
        snapshot.pendingBubbleCount += session.steeringMode == .all ? 0 : session.queuedSteers.count

        for message in session.messages {
            switch message.kind {
            case .agentThinking:
                snapshot.typingBubbleCount += 1
            case .agentReport where message.report != nil:
                snapshot.finalReportBubbleCount += 1
            case .agentQuestion where message.question != nil:
                snapshot.questionBubbleCount += 1
            case .agentError:
                snapshot.errorBubbleCount += 1
            default:
                break
            }
        }
        return snapshot
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage) -> some View {
        switch message.kind {
        case .userText:
            PickyUserBubbleView(message: message)
        case .agentText:
            PickyAgentBubbleView(message: message)
        case .agentThinking:
            PickyTypingBubbleView(message: message)
        case .agentReport:
            if let report = message.report {
                PickyFinalReportBubbleView(report: report)
            } else {
                PickyAgentBubbleView(message: message)
            }
        case .agentQuestion:
            if let request = message.question {
                PickyQuestionBubbleView(request: request, cancelledAt: message.cancelledAt, viewModel: viewModel)
            } else {
                PickyAgentBubbleView(message: message)
            }
        case .agentError:
            PickyErrorBubbleView(
                message: message,
                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) },
                onOpenLogs: { viewModel.openTerminalOverlay(sessionID: session.id) }
            )
        case .system:
            PickyAgentBubbleView(message: message)
        }
    }

    @ViewBuilder
    private func queueSection(items: [PickyQueueItem], kind: PickyPendingQueueKind, mode: PickyQueueMode) -> some View {
        if !items.isEmpty {
            if mode == .all {
                PickyBatchGroupView(items: items, kind: kind)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    PickyPendingBubbleView(queueItem: item, kind: kind)
                }
            }
        }
    }

    private var shouldShowActivityStrip: Bool {
        guard !session.pinned else { return false }
        let total = session.activitySummary.edit
            + session.activitySummary.bash
            + session.activitySummary.thinking
            + session.activitySummary.other
        return total > 0
    }

    private var hasQueueOrActivity: Bool {
        shouldShowActivityStrip || !session.queuedSteers.isEmpty || !session.queuedFollowUps.isEmpty
    }

    private func shouldShowSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = session.messages[index - 1].createdAt
        let current = session.messages[index].createdAt
        return current.timeIntervalSince(previous) >= 60
    }

    private func separatorText(before index: Int) -> String {
        guard index > 0 else { return "now" }
        let previous = session.messages[index - 1].createdAt
        let current = session.messages[index].createdAt
        return elapsedText(seconds: max(0, Int(current.timeIntervalSince(previous))))
    }

    private func elapsedText(seconds: Int) -> String {
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m later" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m later"
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let latestID = session.messages.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(latestID, anchor: .bottom)
            }
        }
    }
}

struct PickyConversationListRenderSnapshot: Equatable {
    var typingBubbleCount = 0
    var batchGroupCount = 0
    var pendingBubbleCount = 0
    var finalReportBubbleCount = 0
    var questionBubbleCount = 0
    var errorBubbleCount = 0
    var showsActivitySummary = false
}

private struct PickyConversationTimeSeparatorView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}
