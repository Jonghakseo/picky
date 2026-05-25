//
//  PickyConversationListView.swift
//  Picky
//
//  Message list for the conversation-style Pickle card.
//

import SwiftUI

struct PickyConversationListView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    var isCommandShortcutHintVisible = false
    @State private var hasAppeared = false
    @State private var delayedQuestionCollapseScrollTask: Task<Void, Never>?

    var body: some View {
        let _ = PickyPerf.event("conversation_list_body")
        // Compute the per-render slices once and thread them into helpers so a
        // single body evaluation doesn't fan back out into N+1 repeat calls of
        // `turnGroups` / `visibleMessages` (each of which walks `session.messages`).
        // The computed `var`s are preserved for test access — see
        // PickyConversationCardViewTests.
        let messages = visibleMessages
        let groups = turnGroups
        let hiddenCount = max(0, session.messages.count - messages.count)
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    // Eager VStack instead of LazyVStack: `visibleMessages` already
                    // trims to the last five user turns (older history lives behind
                    // the View as TUI button / terminal overlay), so the row
                    // count is bounded and laziness gains little. Lazy materialization
                    // also broke `proxy.scrollTo(bottomAnchorID, anchor: .bottom)`
                    // for long-content sessions: the 1pt sentinel hadn't been laid
                    // out by the first scroll attempt, so the viewport landed on
                    // empty space and stayed blank until a streaming message
                    // triggered another scroll. With VStack the sentinel is always
                    // in the tree on first layout and the initial bottom-pin lands
                    // cleanly.
                    VStack(alignment: .leading, spacing: 8) {
                        if let outcome = session.lastTerminalSyncOutcome {
                            PickyTerminalSyncBanner(outcome: outcome) {
                                viewModel.dismissTerminalSyncOutcome(sessionID: session.id)
                            }
                        }
                        if hiddenCount > 0 {
                            moreHistoryButton(hiddenCount: hiddenCount)
                        }
                        if messages.isEmpty && !hasQueueOrActivity {
                            Color.clear
                                .frame(height: 24)
                        } else {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                if shouldShowTurnSeparator(before: index, groups: groups) {
                                    PickyConversationTimeSeparatorView(text: turnSeparatorText(before: index, groups: groups))
                                }
                                turnGroupView(group)
                            }
                            queueSection(items: visibleQueuedSteers, kind: .steer, mode: session.steeringMode)
                            queueSection(items: visibleQueuedFollowUps, kind: .followUp, mode: session.followUpMode)
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
            .task(id: session.id) {
                // VStack is eager so the bottom sentinel is in the view tree by the
                // time this runs. A single non-animated scroll dispatched onto the
                // next runloop tick is enough; no extra sleep needed.
                scrollToBottom(proxy: proxy, animated: PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: hasAppeared))
                hasAppeared = true
            }
            .onChange(of: bottomScrollTrigger) { oldValue, newValue in
                scrollToBottom(proxy: proxy, animated: PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: hasAppeared))
                if PickyConversationScrollPolicy.shouldRepinAfterQuestionCollapse(from: oldValue, to: newValue) {
                    scheduleQuestionCollapseScrollToBottom(proxy: proxy)
                }
            }
            .onDisappear {
                delayedQuestionCollapseScrollTask?.cancel()
                delayedQuestionCollapseScrollTask = nil
            }
        }
    }

    var bottomScrollTrigger: PickyConversationBottomScrollTrigger {
        PickyConversationBottomScrollTrigger(
            latestMessageID: session.messages.last?.id,
            queuedSteers: session.queuedSteers,
            queuedFollowUps: session.queuedFollowUps,
            steeringMode: session.steeringMode,
            followUpMode: session.followUpMode,
            lastRequestAt: session.lastRequestAt,
            pendingExtensionUiRequestID: session.pendingExtensionUiRequest?.id
        )
    }

    var renderSnapshot: PickyConversationListRenderSnapshot {
        var snapshot = PickyConversationListRenderSnapshot()
        snapshot.showsActivitySummary = session.messages.contains { message in
            guard message.kind == .agentActivity, let snapshot = message.activitySnapshot else { return false }
            return !snapshot.visibleToolCallItems.isEmpty
        }
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
            case .commandReceipt:
                snapshot.commandReceiptBubbleCount += 1
            case .system where message.notifyType != nil:
                snapshot.notifyBubbleCount += 1
            case .agentActivity where message.activitySnapshot?.visibleToolCallItems.isEmpty == false:
                snapshot.activitySummaryCount += 1
            default:
                break
            }
        }
        if session.isCompacting {
            snapshot.compactingOverlayCount = 1
        }
        snapshot.compactCompletionBubbleCount = visibleMessages.filter(\.isCompactCompletionMessage).count
        snapshot.compactFailureBubbleCount = visibleMessages.filter(\.isCompactFailureMessage).count
        snapshot.turnCardCount = turnGroups.filter { $0.hasUserMessage && !$0.bodyMessages.isEmpty }.count
        return snapshot
    }

    /// `visibleMessages` 를 turn boundary(=`userText`) 기준으로 그룹화한 결과.
    /// 마지막 그룹은 session 이 active 상태일 때 자동 expanded(`isCurrent = true`).
    /// `session.activitySummary` 는 현재 턴의 라이브 누적 카운트 (agentd가
    /// turn commit 시점에만 agentActivity 메시지로 flush). active turn header가
    /// "N tools"를 실시간으로 입데이트하도록 넘겨줌.
    var turnGroups: [PickyTurnGroup] {
        PickyTurnGrouper.groups(
            from: visibleMessages,
            sessionStatus: session.status,
            liveActivitySummary: session.activitySummary
        )
    }

    @ViewBuilder
    private func turnGroupView(_ group: PickyTurnGroup) -> some View {
        if let user = group.userMessage {
            leadingMessageView(user)
                .id(user.id)
            // Render the turn card whenever there are body messages, or when the
            // current turn has an active/recent tool to surface — without this,
            // tool-only turns (no thinking, no agent_text, agent_activity not
            // committed yet) leave the user bubble dangling with nothing below it.
            let liveTool = group.isCurrent ? liveToolForCurrentTurn(group) : nil
            if !group.bodyMessages.isEmpty || liveTool != nil {
                PickyTurnCardView(
                    group: group,
                    activeTool: liveTool,
                    onOpenActiveToolHistory: group.isCurrent ? { [weak viewModel] in
                        viewModel?.openToolHistoryForCurrentTurn(sessionID: session.id)
                    } : nil
                ) { message in
                    messageView(message, in: group)
                        .id(message.id)
                }
            }
            // Auto-compaction success/failure bubbles live outside the card so
            // they stay visible whether the card is collapsed or expanded — see
            // `PickyTurnGrouper.splitCompactSystemMessages`.
            ForEach(group.trailingCompactMessages, id: \.id) { message in
                messageView(message, in: group)
                    .id(message.id)
            }
        } else {
            // Pre-turn slice: messages that arrived before the first user_text
            // (e.g., session bootstrap notes). Render flat without card chrome.
            ForEach(group.bodyMessages, id: \.id) { message in
                messageView(message, in: group)
                    .id(message.id)
            }
            ForEach(group.trailingCompactMessages, id: \.id) { message in
                messageView(message, in: group)
                    .id(message.id)
            }
        }
    }

    @ViewBuilder
    private func leadingMessageView(_ message: PickySessionMessage) -> some View {
        PickyUserBubbleView(
            message: message,
            onOpenAsReport: openMessageReportAction(for: message),
            onCopyText: { viewModel.copyMessageText($0) },
            onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
        )
    }

    @ViewBuilder
    private func messageView(_ message: PickySessionMessage, in group: PickyTurnGroup) -> some View {
        switch message.kind {
        case .userText:
            PickyUserBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message),
                onCopyText: { viewModel.copyMessageText($0) },
                onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
            )
        case .commandReceipt:
            PickyUserBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message),
                onCopyText: { viewModel.copyMessageText($0) },
                onEditText: { viewModel.replaceComposerDraftText($0, sessionID: session.id) }
            )
        case .agentText:
            PickyAgentBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message),
                onCopyText: { viewModel.copyMessageText($0) },
                isLatestResponseShortcutHintVisible: shouldShowLatestResponseShortcutHint(for: message)
            )
        case .agentThinking:
            PickyTypingBubbleView(message: message, initiallyCollapsed: viewModel.thinkingBlocksHidden(sessionID: session.id))
        case .agentQuestion:
            if let request = message.question {
                PickyQuestionBubbleView(
                    request: request,
                    cancelledAt: message.cancelledAt,
                    isActiveRequest: session.pendingExtensionUiRequest?.id == request.id,
                    viewModel: viewModel
                )
            } else {
                PickyAgentBubbleView(
                    message: message,
                    onCopyText: { viewModel.copyMessageText($0) }
                )
            }
        case .agentError:
            PickyErrorBubbleView(
                message: message,
                onOpenTerminal: { viewModel.openTerminalOverlay(sessionID: session.id) },
                onRetry: retryRuntimeRaceAction(for: message)
            )
        case .agentActivity:
            // Every agentActivity message renders as the compact aggregate
            // chip regardless of turn state. "What's running right now" is
            // surfaced separately by the active-tool indicator pinned to the
            // current turn's body — see `PickyTurnCardView.expandedBody`.
            if let snapshot = message.activitySnapshot, !snapshot.visibleToolCallItems.isEmpty {
                PickyActivitySummaryView(summary: snapshot, onTap: { openToolHistory(forAgentActivityID: message.id) })
            } else {
                EmptyView()
            }
        case .system:
            if message.isCompactCompletionMessage {
                PickyCompactCompletionBubbleView()
            } else if message.isCompactFailureMessage {
                PickyCompactFailureBubbleView(message: message)
            } else if message.notifyType != nil {
                PickyNotifyBubbleView(
                    message: message,
                    onOpenAsReport: openMessageReportAction(for: message)
                )
            } else {
                PickyAgentBubbleView(
                    message: message,
                    onOpenAsReport: openMessageReportAction(for: message),
                    onCopyText: { viewModel.copyMessageText($0) }
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

    private func shouldShowLatestResponseShortcutHint(for message: PickySessionMessage) -> Bool {
        isCommandShortcutHintVisible && message.id == session.latestAgentResponseReportMessageID
    }

    /// Returns a closure that re-sends `session.lastRequestText` via `steer`, but
    /// only when the failed bubble was caused by the Pi SDK `activeRun` race so
    /// we do not invite re-submission on unrelated runtime errors. `steer` is
    /// the right channel because it accepts terminal-status sessions; the
    /// supervisor revives the card to `running` and Pi queues the prompt behind
    /// the in-flight run that won the race.
    private func retryRuntimeRaceAction(for message: PickySessionMessage) -> (() -> Void)? {
        guard PickyErrorBubbleView.isRecoverableRuntimeRace(errorMessage: message.errorMessage) else { return nil }
        guard let text = session.lastRequestText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sessionID = session.id
        return { [weak viewModel] in
            Task { try? await viewModel?.retryAfterRuntimeRace(sessionID: sessionID) }
        }
    }

    /// Resolves the tool to surface in the active turn's live indicator.
    /// Falls back from `activeTool` to the most recent tool started inside
    /// the turn so the indicator does not blink off during the gap between
    /// successive tool calls — the completion state is then conveyed by
    /// the row's status indicator (pulsing dot → checkmark → failure dot).
    private func liveToolForCurrentTurn(_ group: PickyTurnGroup) -> PickyToolActivity? {
        let turnStart = group.userMessage?.createdAt ?? group.bodyMessages.first?.createdAt ?? .distantPast
        return session.mostRecentTool(after: turnStart)
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
                Text("hud.conversation.clearAll")
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
        !visibleQueuedSteers.isEmpty || !visibleQueuedFollowUps.isEmpty
    }

    private var visibleQueuedFollowUps: [PickyQueueItem] {
        session.queuedFollowUps
    }

    private var visibleQueuedSteers: [PickyQueueItem] {
        session.queuedSteers
    }

    /// 카드 안에는 "마지막 user_text 다섯 개 → 끝" 범위를 노출 (최근 5턴이 함께 보이게).
    /// 그 앞 히스토리는 "View as TUI" 버튼 → 인라인 터미널 TUI로 풀 히스토리 확인.
    /// user_text가 0–4개일 때는 전체를 그대로 노출 (slice 시작점이 0과 동일).
    var visibleMessages: [PickySessionMessage] {
        let messages = session.messages
        let userIndices = messages.indices.filter { messages[$0].kind == .userText }
        guard let firstVisibleUserIndex = userIndices.suffix(5).first else {
            return messages
        }
        return Array(messages[firstVisibleUserIndex...])
    }

    var hiddenHistoryCount: Int {
        max(0, session.messages.count - visibleMessages.count)
    }

    private func moreHistoryButton(hiddenCount: Int) -> some View {
        Button(action: {
            viewModel.openTerminalOverlay(sessionID: session.id)
        }) {
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                    .pickyFont(size: 8.5, weight: .semibold)
                Text(L10n.t("hud.conversation.viewAsTui", Int64(hiddenCount)))
                    .font(PickyHUDTypography.statusMedium)
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(DS.Colors.surface2.opacity(0.55)))
            .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                terminalShortcutBadge
                    .fixedSize()
                    .offset(x: 10, y: -7)
                    .opacity(isCommandShortcutHintVisible ? 1 : 0)
                    .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
        .help("Open full session history in Pi terminal (⌘⇧T)")
        .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
    }

    private var terminalShortcutBadge: some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .pickyFont(size: 6.5, weight: .bold)
            Image(systemName: "shift")
                .pickyFont(size: 6.5, weight: .bold)
            Text("T")
                .pickyFont(size: 7.5, weight: .bold, design: .rounded)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.70)))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }

    /// Time separator between two adjacent turn cards. Inside a turn card,
    /// individual message timing is summarized by the chip in the header so
    /// per-message separators inside the body would be redundant.
    /// `groups` is threaded in from `body` so the ForEach iteration does not
    /// re-walk `session.messages` for every turn separator decision.
    private func shouldShowTurnSeparator(before index: Int, groups: [PickyTurnGroup]) -> Bool {
        guard index > 0 else { return false }
        guard let previous = groups[index - 1].bodyMessages.last?.createdAt
            ?? groups[index - 1].userMessage?.createdAt else { return false }
        guard let current = groups[index].userMessage?.createdAt
            ?? groups[index].bodyMessages.first?.createdAt else { return false }
        return current.timeIntervalSince(previous) >= 60
    }

    private func turnSeparatorText(before index: Int, groups: [PickyTurnGroup]) -> String {
        guard index > 0 else { return "now" }
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
                withAnimation(PickyConversationScrollPolicy.liveUpdateAnimation) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                // First hover can inherit the HUD reveal transaction. Force the
                // initial bottom pin to be instantaneous so the user never sees
                // the list animate from its top/pre-measure content offset.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func scheduleQuestionCollapseScrollToBottom(proxy: ScrollViewProxy) {
        delayedQuestionCollapseScrollTask?.cancel()
        delayedQuestionCollapseScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PickyConversationScrollPolicy.questionCollapseRepinDelayNanoseconds)
            guard !Task.isCancelled else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
    }

    private static let bottomAnchorID = "__picky_conversation_bottom_anchor__"
}

enum PickyConversationScrollPolicy {
    static let liveUpdateAnimation = Animation.easeOut(duration: 0.18)

    static let questionCollapseRepinDelayNanoseconds: UInt64 = 220_000_000

    static func shouldAnimateScroll(hasAppeared: Bool) -> Bool {
        hasAppeared
    }

    static func shouldRepinAfterQuestionCollapse(
        from oldValue: PickyConversationBottomScrollTrigger,
        to newValue: PickyConversationBottomScrollTrigger
    ) -> Bool {
        oldValue.pendingExtensionUiRequestID != nil && newValue.pendingExtensionUiRequestID == nil
    }
}

struct PickyConversationBottomScrollTrigger: Equatable {
    let latestMessageID: String?
    let queuedSteers: [PickyQueueItem]
    let queuedFollowUps: [PickyQueueItem]
    let steeringMode: PickyQueueMode
    let followUpMode: PickyQueueMode
    let lastRequestAt: Date?
    let pendingExtensionUiRequestID: String?
}

struct PickyConversationListRenderSnapshot: Equatable {
    var typingBubbleCount = 0
    var batchGroupCount = 0
    var pendingBubbleCount = 0
    var questionBubbleCount = 0
    var errorBubbleCount = 0
    var activitySummaryCount = 0
    var notifyBubbleCount = 0
    var contextUsageFooterCount = 0
    var compactingOverlayCount = 0
    var compactCompletionBubbleCount = 0
    var compactFailureBubbleCount = 0
    var commandReceiptBubbleCount = 0
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
