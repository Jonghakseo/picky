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
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let outcome = session.lastTerminalSyncOutcome {
                            PickyTerminalSyncBanner(outcome: outcome) {
                                viewModel.dismissTerminalSyncOutcome(sessionID: session.id)
                            }
                        }
                        if hiddenHistoryCount > 0 {
                            moreHistoryButton
                        }
                        if visibleMessages.isEmpty && !hasQueueOrActivity {
                            Color.clear
                                .frame(height: 24)
                        } else {
                            ForEach(Array(turnGroups.enumerated()), id: \.element.id) { index, group in
                                if shouldShowTurnSeparator(before: index) {
                                    PickyConversationTimeSeparatorView(text: turnSeparatorText(before: index))
                                }
                                turnGroupView(group)
                            }
                            queueSection(items: visibleQueuedFollowUps, kind: .followUp, mode: session.followUpMode)
                            queueSection(items: visibleQueuedSteers, kind: .steer, mode: session.steeringMode)
                            if showsLiveActivitySummary {
                                PickyActivitySummaryView(summary: session.activitySummary, onTap: openCurrentTurnToolHistory)
                            }
                        }
                        // Sentinel anchor pinned to the very end of the list. Scrolling
                        // to a real message id is fragile because turn cards collapse
                        // their body and `agentActivity` messages render no view, so a
                        // dedicated always-rendered anchor is the only reliable target.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(.vertical, 2)
                }
                if session.isCompacting {
                    PickyCompactingOverlayView()
                }
            }
            .frame(minHeight: 80, maxHeight: 640)
            .onAppear {
                // Two attempts: first deferred to the next runloop tick (covers most
                // cases), second after a short delay to catch the rare path where
                // LazyVStack hasn't laid out the anchor yet on the first attempt.
                scrollToBottom(proxy: proxy, animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToBottom(proxy: proxy, animated: false)
                }
                hasAppeared = true
            }
            .onChange(of: session.id) { _, _ in
                // Reset to the bottom whenever the user swaps to a different session
                // through the dock, so the new card opens at its latest reply.
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: session.messages.last?.id) { _, _ in
                scrollToBottom(proxy: proxy, animated: hasAppeared)
            }
        }
    }

    var renderSnapshot: PickyConversationListRenderSnapshot {
        var snapshot = PickyConversationListRenderSnapshot()
        snapshot.showsActivitySummary = session.messages.contains { message in
            guard message.kind == .agentActivity, let snapshot = message.activitySnapshot else { return false }
            return !snapshot.visibleToolCallItems.isEmpty
        } || showsLiveActivitySummary
        let followUps = visibleQueuedFollowUps
        let steers = visibleQueuedSteers
        snapshot.batchGroupCount += session.followUpMode == .all && !followUps.isEmpty ? 1 : 0
        snapshot.batchGroupCount += session.steeringMode == .all && !steers.isEmpty ? 1 : 0
        snapshot.pendingBubbleCount += session.followUpMode == .all ? 0 : followUps.count
        snapshot.pendingBubbleCount += session.steeringMode == .all ? 0 : steers.count

        for message in session.messages {
            switch message.kind {
            case .agentThinking:
                snapshot.typingBubbleCount += 1
            case .agentQuestion where message.question != nil:
                snapshot.questionBubbleCount += 1
            case .agentError:
                snapshot.errorBubbleCount += 1
            case .agentActivity where message.activitySnapshot?.visibleToolCallItems.isEmpty == false:
                snapshot.activitySummaryCount += 1
            default:
                break
            }
        }
        if showsLiveActivitySummary {
            snapshot.activitySummaryCount += 1
        }
        if session.isCompacting {
            snapshot.compactingOverlayCount = 1
        }
        snapshot.compactCompletionBubbleCount = visibleMessages.filter(\.isCompactCompletionMessage).count
        snapshot.turnCardCount = turnGroups.filter(\.hasUserMessage).count
        return snapshot
    }

    /// `visibleMessages` 를 turn boundary(=`userText`) 기준으로 그룹화한 결과.
    /// 마지막 그룹은 session 이 active 상태일 때 자동 expanded(`isCurrent = true`).
    var turnGroups: [PickyTurnGroup] {
        PickyTurnGrouper.groups(from: visibleMessages, sessionStatus: session.status)
    }

    @ViewBuilder
    private func turnGroupView(_ group: PickyTurnGroup) -> some View {
        if let user = group.userMessage {
            PickyUserBubbleView(
                message: user,
                onOpenAsReport: openMessageReportAction(for: user)
            )
            .id(user.id)
            PickyTurnCardView(group: group) { message in
                messageView(message)
                    .id(message.id)
            }
        } else {
            // Pre-turn slice: messages that arrived before the first user_text
            // (e.g., session bootstrap notes). Render flat without card chrome.
            ForEach(group.bodyMessages, id: \.id) { message in
                messageView(message)
                    .id(message.id)
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage) -> some View {
        switch message.kind {
        case .userText:
            PickyUserBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message)
            )
        case .agentText:
            PickyAgentBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message)
            )
        case .agentThinking:
            PickyTypingBubbleView(message: message, initiallyCollapsed: PickyPiSettingsReader.hideThinkingBlock(cwd: session.cwd))
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
                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) }
            )
        case .agentActivity:
            if let snapshot = message.activitySnapshot, !snapshot.visibleToolCallItems.isEmpty {
                PickyActivitySummaryView(summary: snapshot, onTap: { openToolHistory(forAgentActivityID: message.id) })
            } else {
                EmptyView()
            }
        case .system:
            if message.isCompactCompletionMessage {
                PickyCompactCompletionBubbleView()
            } else {
                PickyAgentBubbleView(
                    message: message,
                    onOpenAsReport: openMessageReportAction(for: message)
                )
            }
        }
    }

    /// Returns a closure that opens this specific message in the report viewer,
    /// or `nil` when the message has no markdown content to expand. Used by the
    /// per-bubble hover-icon affordance.
    private func openMessageReportAction(for message: PickySessionMessage) -> (() -> Void)? {
        guard message.openAsReportMarkdown != nil else { return nil }
        let sessionID = session.id
        let messageID = message.id
        return { [weak viewModel] in
            Task { try? await viewModel?.openReport(sessionID: sessionID, messageID: messageID) }
        }
    }

    private func openCurrentTurnToolHistory() {
        viewModel.openToolHistoryForCurrentTurn(sessionID: session.id)
    }

    private func openToolHistory(forAgentActivityID messageID: String) {
        viewModel.openToolHistoryForAgentActivity(sessionID: session.id, messageID: messageID)
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
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(kind.color)
            Text("\(items.count)")
                .font(PickyHUDTypography.statusMonospacedMedium)
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: 8)
            Button(action: {
                Task { try? await viewModel.clearQueue(sessionID: session.id, kind: .all) }
            }) {
                Text("Clear all")
                    .font(PickyHUDTypography.metaSemibold)
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
        !visibleQueuedSteers.isEmpty || !visibleQueuedFollowUps.isEmpty || showsLiveActivitySummary
    }

    private var showsLiveActivitySummary: Bool {
        session.status == .running
            && !session.activitySummary.visibleToolCallItems.isEmpty
            && hasAgentProgressInVisibleTurn
            && !hasVisibleActivitySnapshot
    }

    private var hasAgentProgressInVisibleTurn: Bool {
        currentTurnMessages.contains { $0.kind != .userText }
    }

    private var hasVisibleActivitySnapshot: Bool {
        currentTurnMessages.contains { message in
            guard message.kind == .agentActivity, let snapshot = message.activitySnapshot else { return false }
            return !snapshot.visibleToolCallItems.isEmpty
        }
    }

    /// `visibleMessages`에서 "현재 턴"(마지막 user_text 이후) 만 잘라낸 슬라이스.
    /// 2턴 노출로 이전 턴의 activity snapshot이 보여도, "현재 턴에 이미
    /// snapshot이 렌더링되었는가" 같은 시점 판단은 현재 턴만 보도록 유지.
    private var currentTurnMessages: ArraySlice<PickySessionMessage> {
        let visible = visibleMessages
        guard let lastUserIndex = visible.lastIndex(where: { $0.kind == .userText }) else {
            return ArraySlice(visible)
        }
        return visible[lastUserIndex...]
    }

    private var visibleQueuedFollowUps: [PickyQueueItem] {
        session.queuedFollowUps
    }

    private var visibleQueuedSteers: [PickyQueueItem] {
        session.queuedSteers
    }

    /// 카드 안에는 "마지막 user_text 두 개 → 끝" 범위를 노출 (직전 턴까지 함께 보이게).
    /// 그 앞 히스토리는 "Earlier history" 버튼 → 터미널 오버레이로 풀 히스토리 확인.
    /// user_text가 0–1개일 때는 전체를 그대로 노출 (slice 시작점이 0과 동일).
    var visibleMessages: [PickySessionMessage] {
        let messages = session.messages
        let userIndices = messages.indices.filter { messages[$0].kind == .userText }
        guard let firstVisibleUserIndex = userIndices.suffix(2).first else {
            return messages
        }
        return Array(messages[firstVisibleUserIndex...])
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
                    .font(PickyHUDTypography.statusMedium)
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

    /// Time separator between two adjacent turn cards. Inside a turn card,
    /// individual message timing is summarized by the chip in the header so
    /// per-message separators inside the body would be redundant.
    private func shouldShowTurnSeparator(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let groups = turnGroups
        guard let previous = groups[index - 1].bodyMessages.last?.createdAt
            ?? groups[index - 1].userMessage?.createdAt else { return false }
        guard let current = groups[index].userMessage?.createdAt
            ?? groups[index].bodyMessages.first?.createdAt else { return false }
        return current.timeIntervalSince(previous) >= 60
    }

    private func turnSeparatorText(before index: Int) -> String {
        guard index > 0 else { return "now" }
        let groups = turnGroups
        guard let previous = groups[index - 1].bodyMessages.last?.createdAt
            ?? groups[index - 1].userMessage?.createdAt,
            let current = groups[index].userMessage?.createdAt
                ?? groups[index].bodyMessages.first?.createdAt else { return "now" }
        return elapsedText(seconds: max(0, Int(current.timeIntervalSince(previous))))
    }

    private func elapsedText(seconds: Int) -> String {
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m later" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m later"
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchorID = "__picky_conversation_bottom_anchor__"
}

struct PickyConversationListRenderSnapshot: Equatable {
    var typingBubbleCount = 0
    var batchGroupCount = 0
    var pendingBubbleCount = 0
    var questionBubbleCount = 0
    var errorBubbleCount = 0
    var activitySummaryCount = 0
    var contextUsageFooterCount = 0
    var compactingOverlayCount = 0
    var compactCompletionBubbleCount = 0
    var turnCardCount = 0
    var showsActivitySummary = false
}

private struct PickyConversationTimeSeparatorView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
            Text(text)
                .font(PickyHUDTypography.metaMedium)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.55)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}
