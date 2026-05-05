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
    @State private var hasAppeared = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if hiddenHistoryCount > 0 {
                        moreHistoryButton
                    }
                    if visibleMessages.isEmpty && !hasQueueOrActivity {
                        Color.clear
                            .frame(height: 24)
                    } else {
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowSeparator(before: index) {
                                PickyConversationTimeSeparatorView(text: separatorText(before: index))
                            }
                            messageView(message)
                                .id(message.id)
                        }
                        queueSection(items: visibleQueuedFollowUps, kind: .followUp, mode: session.followUpMode)
                        queueSection(items: visibleQueuedSteers, kind: .steer, mode: session.steeringMode)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 80, maxHeight: 1050)
            .onAppear {
                scrollToLatest(proxy: proxy, animated: false)
                hasAppeared = true
            }
            .onChange(of: session.messages.last?.id) { _, _ in
                scrollToLatest(proxy: proxy, animated: hasAppeared)
            }
        }
    }

    var renderSnapshot: PickyConversationListRenderSnapshot {
        var snapshot = PickyConversationListRenderSnapshot()
        snapshot.showsActivitySummary = session.messages.contains { message in
            guard message.kind == .agentActivity, let snapshot = message.activitySnapshot else { return false }
            return activityTotal(snapshot) > 0
        }
        let followUps = visibleQueuedFollowUps
        let steers = visibleQueuedSteers
        snapshot.batchGroupCount += session.followUpMode == .all && !followUps.isEmpty ? 1 : 0
        snapshot.batchGroupCount += session.steeringMode == .all && !steers.isEmpty ? 1 : 0
        snapshot.pendingBubbleCount += session.followUpMode == .all ? 0 : followUps.count
        snapshot.pendingBubbleCount += session.steeringMode == .all ? 0 : steers.count

        snapshot.openAsReportActionCount = visibleMessages.filter { showsOpenAsReportAction(for: $0) }.count

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
            case .agentActivity where message.activitySnapshot != nil:
                snapshot.activitySummaryCount += 1
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
            PickyAgentBubbleView(
                message: message,
                showsOpenAsReportAction: showsOpenAsReportAction(for: message),
                onOpenAsReport: { openReport() }
            )
        case .agentThinking:
            PickyTypingBubbleView(message: message)
        case .agentReport:
            if let report = message.report {
                PickyFinalReportBubbleView(
                    report: report,
                    showsOpenAsReportAction: showsOpenAsReportAction(for: message),
                    onOpenAsReport: { openReport() }
                )
            } else {
                PickyAgentBubbleView(message: message)
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
                PickyAgentBubbleView(message: message)
            }
        case .agentError:
            PickyErrorBubbleView(
                message: message,
                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) },
                onOpenLogs: { viewModel.openTerminalOverlay(sessionID: session.id) }
            )
        case .agentActivity:
            if let snapshot = message.activitySnapshot, activityTotal(snapshot) > 0 {
                PickyActivitySummaryView(summary: snapshot)
            } else {
                EmptyView()
            }
        case .system:
            PickyAgentBubbleView(message: message)
        }
    }

    private func showsOpenAsReportAction(for message: PickySessionMessage) -> Bool {
        session.canOpenMarkdownReport && message.id == session.latestOpenAsReportMessage?.id
    }

    private func openReport() {
        Task { try? await viewModel.openReport(sessionID: session.id) }
    }

    @ViewBuilder
    private func queueSection(items: [PickyQueueItem], kind: PickyPendingQueueKind, mode: PickyQueueMode) -> some View {
        if !items.isEmpty {
            queueGroupHeader(items: items, kind: kind)
            if mode == .all {
                PickyBatchGroupView(items: items, kind: kind)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    PickyPendingBubbleView(queueItem: item, kind: kind)
                }
            }
        }
    }

    private func queueGroupHeader(items: [PickyQueueItem], kind: PickyPendingQueueKind) -> some View {
        HStack(spacing: 6) {
            Text(kind.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(kind.color)
            Text("\(items.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 8)
            Button(action: {
                Task { try? await viewModel.clearQueue(sessionID: session.id, kind: .all) }
            }) {
                Text("Clear all")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(DS.Colors.surface2.opacity(0.6))
                    )
                    .overlay(
                        Capsule().stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Clear all queued messages")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var hasQueueOrActivity: Bool {
        !visibleQueuedSteers.isEmpty || !visibleQueuedFollowUps.isEmpty
    }

    private var visibleQueuedFollowUps: [PickyQueueItem] {
        visibleQueueItems(session.queuedFollowUps)
    }

    private var visibleQueuedSteers: [PickyQueueItem] {
        visibleQueueItems(session.queuedSteers)
    }

    private func visibleQueueItems(_ items: [PickyQueueItem]) -> [PickyQueueItem] {
        items.filter { item in
            !recentUserTextMatchesQueuedItem(item)
        }
    }

    private func recentUserTextMatchesQueuedItem(_ item: PickyQueueItem) -> Bool {
        let queuedText = PickyQueuedInputText.normalized(item.text)
        guard !queuedText.isEmpty else { return false }
        return session.messages.contains { message in
            guard message.kind == .userText,
                  let text = message.text,
                  abs(message.createdAt.timeIntervalSince(item.enqueuedAt)) <= 300
            else { return false }
            return PickyQueuedInputText.normalized(text) == queuedText
        }
    }

    /// 카드 안에는 "마지막 user_text → 끝" 한 쌍만 노출. 히스토리 전체는 "Earlier history" 버튼 → terminal.
    var visibleMessages: [PickySessionMessage] {
        let messages = session.messages
        guard let lastUserIndex = messages.lastIndex(where: { $0.kind == .userText }) else {
            return messages
        }
        return Array(messages[lastUserIndex...])
    }

    var hiddenHistoryCount: Int {
        max(0, session.messages.count - visibleMessages.count)
    }

    private var moreHistoryButton: some View {
        Button(action: {
            viewModel.openTerminalOverlay(sessionID: session.id)
        }) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                Text("Earlier history · \(hiddenHistoryCount) more")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(DS.Colors.surface2.opacity(0.55)))
            .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
        .help("Open terminal to see full session history")
    }

    private func shouldShowSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = visibleMessages[index - 1].createdAt
        let current = visibleMessages[index].createdAt
        return current.timeIntervalSince(previous) >= 60
    }

    private func separatorText(before index: Int) -> String {
        guard index > 0 else { return "now" }
        let previous = visibleMessages[index - 1].createdAt
        let current = visibleMessages[index].createdAt
        return elapsedText(seconds: max(0, Int(current.timeIntervalSince(previous))))
    }

    private func elapsedText(seconds: Int) -> String {
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m later" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m later"
    }

    private func scrollToLatest(proxy: ScrollViewProxy, animated: Bool) {
        guard let latestID = session.messages.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(latestID, anchor: .bottom)
                }
            } else {
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
    var openAsReportActionCount = 0
    var questionBubbleCount = 0
    var errorBubbleCount = 0
    var activitySummaryCount = 0
    var showsActivitySummary = false
}

private func activityTotal(_ summary: PickyActivitySummary) -> Int {
    summary.edit + summary.bash + summary.thinking + summary.other
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
