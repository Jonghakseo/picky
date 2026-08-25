//
//  PickyConversationListView.swift
//  Picky
//
//  Message list for the conversation-style Pickle card.
//

import SwiftUI

struct PickyConversationListView: View {
    let session: PickyConversationSessionCard
    /// Runtime composition passes the registry-owned conversation store. The
    /// legacy value fallback keeps existing focused policy tests independent of
    /// registry setup while production message membership and leaf values retain
    /// their stable store identities.
    let conversationStore: PickyConversationStore?
    let viewModel: any PickySessionCommands
    var isCommandShortcutHintVisible = false
    /// Test-only observation hook with a no-op production default. It counts
    /// actual SwiftUI body evaluations when the view is mounted in NSHostingView.
    var onBodyEvaluation: () -> Void = { }
    /// Test-only leaf hook. It verifies that a same-ID streaming replacement
    /// wakes its own stable store and not a sibling bubble.
    var onMessageLeafBodyEvaluation: (String, Bool, Bool) -> Void = { _, _, _ in }

    init(
        session: PickyConversationSessionCard,
        viewModel: any PickySessionCommands,
        conversationStore: PickyConversationStore? = nil,
        isCommandShortcutHintVisible: Bool = false,
        fillsAvailableHeight: Bool = false,
        hasProgressOverlay: Bool = false,
        onInitialBottomPinReady: @escaping () -> Void = { },
        onBodyEvaluation: @escaping () -> Void = { },
        onMessageLeafBodyEvaluation: @escaping (String, Bool, Bool) -> Void = { _, _, _ in }
    ) {
        self.session = session
        self.viewModel = viewModel
        self.conversationStore = conversationStore
        self.isCommandShortcutHintVisible = isCommandShortcutHintVisible
        self.fillsAvailableHeight = fillsAvailableHeight
        self.hasProgressOverlay = hasProgressOverlay
        self.onInitialBottomPinReady = onInitialBottomPinReady
        self.onBodyEvaluation = onBodyEvaluation
        self.onMessageLeafBodyEvaluation = onMessageLeafBodyEvaluation
    }
    /// When the enclosing card has an explicit (user-resized) height, let the list
    /// grow to consume the leftover vertical space so the composer stays pinned to
    /// the card's bottom edge instead of floating below a hardcoded 640pt cap.
    var fillsAvailableHeight = false
    /// Whether the card reserves a top overlay control above transcript rows.
    var hasProgressOverlay = false
    /// Fires once the initial bottom anchor is confirmed inside the viewport.
    /// This is a geometry-ready milestone, not a generic next-runloop guess.
    var onInitialBottomPinReady: () -> Void = { }
    @State private var hasAppeared = false
    @State private var hasReportedInitialBottomPinReady = false
    @State private var isPinnedToBottom = true
    @State private var hasUnreadContentSinceUnpinning = false
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var bottomAnchorMaxY: CGFloat = .infinity
    /// Suppresses an unpin caused by the short layout interval between a
    /// streaming update growing the content and its requested bottom scroll.
    @State private var isAwaitingProgrammaticBottomPin = false
    @State private var delayedQuestionCollapseScrollTask: Task<Void, Never>?
    /// Oldest visible `userText` message id once the user has loaded earlier
    /// turns. nil = default window (last 10 user turns). Absolute id so newly
    /// streamed turns never push expanded history back out of view.
    @State private var expandedHistoryAnchorID: String?
    /// One-shot `scrollPosition` target used to keep the previously-top turn
    /// anchored while older turns are prepended in the same transaction
    /// (flicker-free, unlike a deferred `proxy.scrollTo`). Cleared right after
    /// the commit so it never fights the bottom-pin machinery.
    @State private var historyScrollTargetID: String?

    var body: some View {
        let _ = onBodyEvaluation()
        let _ = PickyPerf.event("conversation_list_body")
        // Compute the per-render slices once and thread them into helpers so a
        // single body evaluation doesn't fan back out into N+1 repeat calls of
        // `turnGroups` / `visibleMessages` (each of which walks `session.messages`).
        // The computed `var`s are preserved for test access — see
        // PickyConversationCardViewTests.
        let messages = PickyPerf.interval("conversation_visible_messages") { visibleMessages }
        let groups = PickyPerf.interval("conversation_turn_groups") { turnGroups }
        let hiddenTurns = PickyConversationHistoryWindowPolicy.hiddenTurnCount(
            messages: orderedMessages,
            expandedAnchorID: expandedHistoryAnchorID
        )
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    // Eager VStack instead of LazyVStack: `visibleMessages` already
                    // trims to the last ten user turns (older history loads in
                    // ten-turn steps via the pill below), so the row
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
                        historyTopMarker(hiddenTurns: hiddenTurns, groups: groups)
                        if messages.isEmpty && !hasQueueOrActivity {
                            Color.clear
                                .frame(height: 24)
                        } else {
                            // Turn chrome is intentionally grouped rather than rendered as a
                            // flat message list. Its identity is the leading message ID (or the
                            // fixed pre-turn sentinel), so a same-ID streaming replacement keeps
                            // the group and every bubble identity stable; leaf values are read
                            // through the registry-owned PickyMessageStore below.
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
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: PickyConversationBottomAnchorPreferenceKey.self,
                                        value: proxy.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                                    )
                                }
                            }
                    }
                    .padding(.vertical, 2)
                    .scrollTargetLayout()
                }
                .scrollPosition(
                    id: Binding(
                        get: { historyScrollTargetID },
                        // Write-only: ignore scroll writeback so user scrolling
                        // never mutates state; we clear explicitly post-commit.
                        set: { _ in }
                    ),
                    anchor: .top
                )
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PickyConversationScrollViewportPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                if session.isCompacting {
                    PickyCompactingOverlayView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if PickyConversationScrollPolicy.shouldShowJumpToLatest(
                    isPinnedToBottom: isPinnedToBottom,
                    hasUnreadContent: hasUnreadContentSinceUnpinning
                ) {
                    jumpToLatestButton(proxy: proxy)
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
            }
            .frame(minHeight: 80, maxHeight: fillsAvailableHeight ? .infinity : 640)
            .onPreferenceChange(PickyConversationScrollViewportPreferenceKey.self) { height in
                scrollViewportHeight = height
                updatePinnedStateFromViewportGeometry()
            }
            .onPreferenceChange(PickyConversationBottomAnchorPreferenceKey.self) { maxY in
                bottomAnchorMaxY = maxY
                updatePinnedStateFromViewportGeometry()
            }
            .task(id: session.id) {
                expandedHistoryAnchorID = nil
                historyScrollTargetID = nil
                hasReportedInitialBottomPinReady = false
                // Session changes always start at the most recent content. VStack is
                // eager, so the bottom sentinel is in the view tree by this point.
                if PickyConversationScrollPolicy.shouldAutoScroll(
                    from: nil,
                    to: bottomScrollTrigger,
                    isPinnedToBottom: isPinnedToBottom
                ) {
                    isPinnedToBottom = true
                    hasUnreadContentSinceUnpinning = false
                    scrollToBottom(proxy: proxy, animated: PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: hasAppeared))
                }
                hasAppeared = true
            }
            .onChange(of: bottomScrollTrigger) { oldValue, newValue in
                PickyPerf.event("conversation_bottom_scroll_trigger_changed")
                let shouldAutoScroll = PickyConversationScrollPolicy.shouldAutoScroll(
                    from: oldValue,
                    to: newValue,
                    isPinnedToBottom: isPinnedToBottom
                )

                if shouldAutoScroll {
                    // Local submissions and question completion deliberately return
                    // the user to the active end of the conversation. Mark this
                    // before the deferred ScrollViewProxy action so the jump pill
                    // does not flash while the sentinel comes back into view.
                    isPinnedToBottom = true
                    hasUnreadContentSinceUnpinning = false
                    scrollToBottom(proxy: proxy, animated: PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: hasAppeared))
                    if PickyConversationScrollPolicy.shouldRepinAfterQuestionCollapse(from: oldValue, to: newValue) {
                        scheduleQuestionCollapseScrollToBottom(proxy: proxy)
                    }
                } else if PickyConversationScrollPolicy.shouldMarkContentUnread(
                    from: oldValue,
                    to: newValue,
                    isPinnedToBottom: isPinnedToBottom
                ) {
                    hasUnreadContentSinceUnpinning = true
                }
            }
            .onDisappear {
                delayedQuestionCollapseScrollTask?.cancel()
                delayedQuestionCollapseScrollTask = nil
                isAwaitingProgrammaticBottomPin = false
            }
        }
    }

    var bottomScrollTrigger: PickyConversationBottomScrollTrigger {
        PickyConversationBottomScrollTrigger(
            latestMessageID: orderedMessages.last?.id,
            queuedSteers: session.queuedSteers,
            queuedFollowUps: session.queuedFollowUps,
            steeringMode: session.steeringMode,
            followUpMode: session.followUpMode,
            lastRequestAt: session.lastRequestAt,
            pendingExtensionUiRequestID: session.pendingExtensionUiRequest?.id,
            hasProgressOverlay: hasProgressOverlay
        )
    }

    /// Test-facing aggregation of what `body` puts in the tree. Counts derive
    /// from the same `PickyConversationBubbleKind` classification `messageView`
    /// switches on, applied to the same turn groups the list renders, so they
    /// cannot drift from the real render path. Collapsed-card state is runtime
    /// UI state; counts represent each turn's expanded content.
    var renderSnapshot: PickyConversationListRenderSnapshot {
        var snapshot = PickyConversationListRenderSnapshot()
        let followUps = visibleQueuedFollowUps
        let steers = visibleQueuedSteers
        snapshot.batchGroupCount += session.followUpMode == .all && !followUps.isEmpty ? 1 : 0
        snapshot.batchGroupCount += session.steeringMode == .all && !steers.isEmpty ? 1 : 0
        snapshot.pendingBubbleCount += session.followUpMode == .all ? 0 : followUps.count
        snapshot.pendingBubbleCount += session.steeringMode == .all ? 0 : steers.count

        let groups = turnGroups
        let renderedMessages = groups.flatMap { group in
            [group.userMessage].compactMap { $0 } + group.bodyMessages + group.trailingMessages
        }
        for message in renderedMessages {
            switch PickyConversationBubbleKind(message: message) {
            case .userText, .agentText, .questionFallback, .systemText, .hiddenActivity:
                break
            case .commandReceipt:
                snapshot.commandReceiptBubbleCount += 1
            case .subagentInvocation:
                snapshot.subagentInvocationBubbleCount += 1
            case .typing:
                snapshot.typingBubbleCount += 1
            case .question:
                snapshot.questionBubbleCount += 1
            case .error:
                snapshot.errorBubbleCount += 1
            case .activitySummary:
                snapshot.activitySummaryCount += 1
            case .compactCompletion:
                snapshot.compactCompletionBubbleCount += 1
            case .compactFailure:
                snapshot.compactFailureBubbleCount += 1
            case .notify:
                snapshot.notifyBubbleCount += 1
            }
        }
        snapshot.showsActivitySummary = snapshot.activitySummaryCount > 0
        if session.isCompacting {
            snapshot.compactingOverlayCount = 1
        }
        snapshot.turnCardCount = groups.filter { shouldRenderTurnCard($0) }.count
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
            liveActivitySummary: session.activitySummary,
            pendingQuestionRequestID: session.pendingExtensionUiRequest?.id
        )
    }

    @ViewBuilder
    private func turnGroupView(_ group: PickyTurnGroup) -> some View {
        if let user = group.userMessage {
            messageLeafView(user, in: group)
                .id(user.id)
            let liveTool = liveToolForCurrentTurn(group)
            if shouldRenderTurnCard(group) {
                PickyTurnCardView(
                    group: group,
                    activeTool: liveTool,
                    onOpenActiveToolHistory: group.isCurrent ? { [weak viewModel] in
                        viewModel?.openToolHistoryForCurrentTurn(sessionID: session.id)
                    } : nil
                ) { message in
                    messageLeafView(message, in: group)
                        .id(message.id)
                }
            }
            // Auto-compaction bubbles and the pending extension-ui question live
            // outside the card so they stay visible whether the card is collapsed
            // or expanded — see `PickyTurnGrouper.groups`.
            ForEach(group.trailingMessages, id: \.id) { message in
                messageLeafView(message, in: group)
                    .id(message.id)
            }
        } else {
            // Pre-turn slice: messages that arrived before the first user_text
            // (e.g., session bootstrap notes). Render flat without card chrome.
            ForEach(group.bodyMessages, id: \.id) { message in
                messageLeafView(message, in: group)
                    .id(message.id)
            }
            ForEach(group.trailingMessages, id: \.id) { message in
                messageLeafView(message, in: group)
                    .id(message.id)
            }
        }
    }

    @ViewBuilder
    private func messageLeafView(_ message: PickySessionMessage, in group: PickyTurnGroup) -> some View {
        let latestAgentResponse = isLatestAgentResponse(message)
        let latestResponseShortcutHintVisible = shouldShowLatestResponseShortcutHint(for: message)
        if let conversationStore {
            PickyConversationMessageLeafView(
                messageStore: conversationStore.messageStore(id: message.id),
                isLatestAgentResponse: latestAgentResponse,
                isLatestResponseShortcutHintVisible: latestResponseShortcutHintVisible,
                onBodyEvaluation: {
                    onMessageLeafBodyEvaluation(
                        message.id,
                        latestAgentResponse,
                        latestResponseShortcutHintVisible
                    )
                }
            ) { currentMessage, isLatestAgentResponse, isLatestResponseShortcutHintVisible in
                messageView(
                    currentMessage,
                    in: group,
                    latestAgentResponseOverride: isLatestAgentResponse,
                    latestResponseShortcutHintVisibleOverride: isLatestResponseShortcutHintVisible
                )
            }
            .equatable()
        } else {
            messageView(message, in: group)
        }
    }

    @ViewBuilder
    private func messageView(
        _ message: PickySessionMessage,
        in group: PickyTurnGroup,
        latestAgentResponseOverride: Bool? = nil,
        latestResponseShortcutHintVisibleOverride: Bool? = nil
    ) -> some View {
        switch PickyConversationBubbleKind(message: message) {
        case .userText, .commandReceipt:
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
                isLatestAgentResponse: latestAgentResponseOverride ?? isLatestAgentResponse(message),
                isLatestResponseShortcutHintVisible: latestResponseShortcutHintVisibleOverride ?? shouldShowLatestResponseShortcutHint(for: message)
            )
        case .typing:
            PickyTypingBubbleView(message: message, initiallyCollapsed: viewModel.thinkingBlocksHidden(sessionID: session.id))
        case .subagentInvocation:
            if let presentation = PickySubagentInvocationPresentation(
                invocation: message.subagentInvocation,
                runs: session.subagentRuns,
                createdAt: message.createdAt
            ) {
                PickySubagentInvocationBubbleView(
                    presentation: presentation,
                    isExpanded: viewModel.isSubagentInvocationExpanded(
                        invocationID: presentation.invocation.invocationId,
                        sessionID: session.id,
                        isComplete: presentation.isComplete
                    ),
                    setExpanded: { expanded in
                        viewModel.setSubagentInvocationExpanded(
                            expanded,
                            invocationID: presentation.invocation.invocationId,
                            sessionID: session.id
                        )
                    },
                    onOpenRunResponse: { row in
                        guard let runID = row.run?.runId,
                              let invocationID = row.run?.invocationId else { return }
                        Task { try? await viewModel.openSubagentRunResponse(sessionID: session.id, invocationID: invocationID, runId: runID) }
                    }
                )
            }
        case .question:
            if let request = message.question {
                PickyQuestionBubbleView(
                    request: request,
                    cancelledAt: message.cancelledAt,
                    isActiveRequest: session.pendingExtensionUiRequest?.id == request.id,
                    commands: viewModel
                )
            }
        case .questionFallback:
            PickyAgentBubbleView(
                message: message,
                onCopyText: { viewModel.copyMessageText($0) }
            )
        case .error:
            PickyErrorBubbleView(
                message: message,
                onRetry: retryAction(for: message)
            )
        case .activitySummary:
            // Every agentActivity message renders as the compact aggregate
            // chip regardless of turn state. "What's running right now" is
            // surfaced separately by the active-tool indicator pinned to the
            // current turn's body — see `PickyTurnCardView.expandedBody`.
            if let snapshot = message.activitySnapshot {
                PickyActivitySummaryView(summary: snapshot, onTap: { openToolHistory(forAgentActivityID: message.id) })
            }
        case .hiddenActivity:
            EmptyView()
        case .compactCompletion:
            PickyCompactCompletionBubbleView()
        case .compactFailure:
            PickyCompactFailureBubbleView(message: message)
        case .notify:
            PickyNotifyBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message)
            )
        case .systemText:
            PickyAgentBubbleView(
                message: message,
                onOpenAsReport: openMessageReportAction(for: message),
                onCopyText: { viewModel.copyMessageText($0) }
            )
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

    private func isLatestAgentResponse(_ message: PickySessionMessage) -> Bool {
        message.kind == .agentText && message.id == session.latestAgentResponseReportMessageID
    }

    private func shouldShowLatestResponseShortcutHint(for message: PickySessionMessage) -> Bool {
        isCommandShortcutHintVisible && isLatestAgentResponse(message)
    }

    /// Offers Retry only on the latest error while the session is still failed.
    /// A Pi `activeRun` race rejected the request before delivery, so that path
    /// must resend `lastRequestText`. Other runtime failures happened after Pi
    /// accepted the turn; those continue from the existing transcript with a
    /// short localized prompt instead of duplicating the original request.
    private func retryAction(for message: PickySessionMessage) -> (() -> Void)? {
        guard session.status == .failed else { return nil }
        guard message.id == orderedMessages.last(where: { $0.kind == .agentError })?.id else { return nil }

        let sessionID = session.id
        if PickyErrorBubbleView.isRecoverableRuntimeRace(errorMessage: message.errorMessage) {
            guard let text = session.lastRequestText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return { [weak viewModel] in
                Task { try? await viewModel?.retryAfterRuntimeRace(sessionID: sessionID) }
            }
        }

        return { [weak viewModel] in
            Task { try? await viewModel?.continueAfterRuntimeFailure(sessionID: sessionID) }
        }
    }

    /// Render the turn card whenever there are body messages, or when the
    /// current turn has an active/recent tool to surface — without this,
    /// tool-only turns (no thinking, no agent_text, agent_activity not
    /// committed yet) leave the user bubble dangling with nothing below it.
    /// Shared by `turnGroupView` and `renderSnapshot.turnCardCount`.
    private func shouldRenderTurnCard(_ group: PickyTurnGroup) -> Bool {
        guard group.hasUserMessage else { return false }
        return !group.bodyMessages.isEmpty || liveToolForCurrentTurn(group) != nil
    }

    /// Resolves the tool to surface in the active turn's live indicator.
    /// Only the current turn shows one. Falls back from `activeTool` to the
    /// most recent tool started inside the turn so the indicator does not
    /// blink off during the gap between successive tool calls — the completion
    /// state is then conveyed by the row's status indicator (pulsing dot →
    /// checkmark → failure dot).
    private func liveToolForCurrentTurn(_ group: PickyTurnGroup) -> PickyToolActivity? {
        guard group.isCurrent else { return nil }
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
                Task { try? await viewModel.clearQueueRestoringQueuedInputs(sessionID: session.id, kind: .all) }
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
        visibleQueueItems(session.queuedFollowUps)
    }

    private var visibleQueuedSteers: [PickyQueueItem] {
        visibleQueueItems(session.queuedSteers)
    }

    /// Hide pending steer/follow-up bubbles once the matching `user_text` journal
    /// entry has been rendered. The supervisor records a `user_text` for every
    /// queued prompt as soon as Pi accepts it (often before Pi actually dequeues),
    /// so without this filter the card briefly — and for active turns, durably —
    /// shows the same instruction twice (once as the user bubble, once as the
    /// pending bubble). `PickyQueuedInputText.normalized` strips the agentd
    /// prompt envelope so wrapped queue snapshots still match the raw user text.
    private func visibleQueueItems(_ items: [PickyQueueItem]) -> [PickyQueueItem] {
        items.filter { item in
            !recentUserTextMatchesQueuedItem(item)
        }
    }

    private func recentUserTextMatchesQueuedItem(_ item: PickyQueueItem) -> Bool {
        let queuedText = PickyQueuedInputText.normalized(item.text)
        guard !queuedText.isEmpty else { return false }
        return orderedMessages.contains { message in
            guard message.kind == .userText,
                  let text = message.text,
                  abs(message.createdAt.timeIntervalSince(item.enqueuedAt)) <= 300
            else { return false }
            return PickyQueuedInputText.normalized(text) == queuedText
        }
    }

    /// 카드 안에는 기본적으로 마지막 10개 user turn부터 끝까지 노출.
    /// "이전 턴 더 보기" 버튼이 anchor(user_text id)를 뒤로 옮겨 10턴씩 확장하며,
    /// anchor는 절대 id라 새 턴이 스트리밍돼도 펼친 히스토리는 유지된다.
    /// 정책은 `PickyConversationHistoryWindowPolicy` 참조.
    var visibleMessages: [PickySessionMessage] {
        let messages = orderedMessages
        guard let start = PickyConversationHistoryWindowPolicy.visibleStartIndex(
            messages: messages,
            expandedAnchorID: expandedHistoryAnchorID
        ) else {
            return messages
        }
        return Array(messages[start...])
    }

    /// The mounted list reads registry membership by `orderedMessageIDs`, then
    /// resolves each stable leaf store. A streaming replacement therefore keeps
    /// every row ID stable and only changes the replaced leaf's value revision.
    private var orderedMessages: [PickySessionMessage] {
        guard let conversationStore else { return session.messages }
        return conversationStore.orderedMessageIDs.compactMap { messageID in
            guard case .loaded(let message) = conversationStore.messageStore(id: messageID).messageState else {
                return nil
            }
            return message
        }
    }

    var hiddenHistoryCount: Int {
        max(0, orderedMessages.count - visibleMessages.count)
    }

    /// Top-of-list marker, always rendered so its row height is reserved from the
    /// first layout pass. The initial `sessionSnapshot` only carries the visible
    /// window, so `hiddenTurns` is still 0 on first paint and only becomes
    /// positive once the full session arrives. Rendering the pill conditionally
    /// made it pop into existence at that moment and shifted the whole list down.
    @ViewBuilder
    private func historyTopMarker(hiddenTurns: Int, groups: [PickyTurnGroup]) -> some View {
        if hiddenTurns > 0 {
            loadMoreHistoryButton(hiddenTurns: hiddenTurns, groups: groups)
        } else {
            historyPillLabel(systemImage: "flag", text: L10n.t("hud.conversation.historyStart"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    /// Shared chrome for both top markers. Metrics must stay identical between
    /// the two states or swapping them reintroduces the layout shift. Only the
    /// actionable variant gets the capsule fill so the static marker does not
    /// advertise a tap target it does not have.
    private func historyPillLabel(systemImage: String, text: String, actionable: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .pickyFont(size: 8.5, weight: .semibold)
            Text(text)
                .font(PickyHUDTypography.statusMedium)
        }
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(actionable ? DS.Colors.surface2.opacity(0.55) : .clear))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(actionable ? 0.55 : 0), lineWidth: 0.5))
    }

    private func loadMoreHistoryButton(hiddenTurns: Int, groups: [PickyTurnGroup]) -> some View {
        Button(action: {
            let previousTopGroupID = groups.first?.id
            // Prepend + scroll-target in one transaction so the previously-top
            // turn stays anchored within the same layout commit (no flicker).
            withTransaction(Transaction(animation: nil)) {
                historyScrollTargetID = previousTopGroupID
                expandedHistoryAnchorID = PickyConversationHistoryWindowPolicy.anchorIDAfterLoadingMore(
                    messages: orderedMessages,
                    expandedAnchorID: expandedHistoryAnchorID
                )
            }
            // Clear the one-shot target after the repositioning commit. Two
            // hops so the clear cannot coalesce into the same commit.
            DispatchQueue.main.async {
                DispatchQueue.main.async { historyScrollTargetID = nil }
            }
        }) {
            historyPillLabel(
                systemImage: "clock.arrow.circlepath",
                text: L10n.t(
                    "hud.conversation.loadMoreTurns",
                    Int64(min(PickyConversationHistoryWindowPolicy.loadMoreTurnStep, hiddenTurns)),
                    Int64(hiddenTurns)
                ),
                actionable: true
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
        .help("Show earlier turns")
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

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            isPinnedToBottom = true
            hasUnreadContentSinceUnpinning = false
            scrollToBottom(proxy: proxy, animated: PickyConversationScrollPolicy.shouldAnimateScroll(hasAppeared: hasAppeared))
        }) {
            Label(L10n.t("hud.conversation.jumpToLatest"), systemImage: "arrow.down")
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.surface2.opacity(0.96)))
                .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("hud.conversation.jumpToLatest.accessibilityLabel"))
        .help(L10n.t("hud.conversation.jumpToLatest.help"))
    }

    private func updatePinnedStateFromViewportGeometry() {
        guard scrollViewportHeight > 0, bottomAnchorMaxY.isFinite else { return }

        if PickyConversationScrollPolicy.isBottomAnchorPinned(
            maxY: bottomAnchorMaxY,
            viewportHeight: scrollViewportHeight
        ) {
            let completedProgrammaticBottomPin = isAwaitingProgrammaticBottomPin
            isPinnedToBottom = true
            hasUnreadContentSinceUnpinning = false
            isAwaitingProgrammaticBottomPin = false
            if PickyConversationScrollPolicy.shouldReportInitialBottomPinReady(
                completedProgrammaticBottomPin: completedProgrammaticBottomPin,
                hasReported: hasReportedInitialBottomPinReady
            ) {
                hasReportedInitialBottomPinReady = true
                onInitialBottomPinReady()
            }
        } else if !isAwaitingProgrammaticBottomPin {
            isPinnedToBottom = false
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        isAwaitingProgrammaticBottomPin = true
        if animated {
            PickyPerf.event("conversation_scroll_to_bottom_animated")
        } else {
            PickyPerf.event("conversation_scroll_to_bottom_instant")
        }
        // A short transcript can already be bottom-pinned before the deferred
        // scroll executes. Re-check the stored geometry after arming the pin so
        // that path reports readiness without waiting for a preference change.
        updatePinnedStateFromViewportGeometry()
        DispatchQueue.main.async {
            if animated {
                withAnimation(PickyConversationScrollPolicy.liveUpdateAnimation) {
                    PickyPerf.interval("conversation_scroll_proxy_scroll_to") {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
            } else {
                // First hover can inherit the HUD reveal transaction. Force the
                // initial bottom pin to be instantaneous so the user never sees
                // the list animate from its top/pre-measure content offset.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    PickyPerf.interval("conversation_scroll_proxy_scroll_to") {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
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
    private static let scrollCoordinateSpace = "PickyConversationScrollViewport"
}

private struct PickyConversationScrollViewportPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PickyConversationBottomAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum PickyConversationScrollPolicy {
    static let liveUpdateAnimation = Animation.easeOut(duration: 0.18)

    static let questionCollapseRepinDelayNanoseconds: UInt64 = 220_000_000
    /// Treat the bottom as pinned while its sentinel remains within this
    /// distance of the viewport's lower edge. This absorbs sub-pixel layout
    /// movement without stealing the reader's position.
    static let bottomPinThreshold: CGFloat = 28

    static func shouldAnimateScroll(hasAppeared: Bool) -> Bool {
        hasAppeared
    }

    /// A missing prior trigger represents a session switch, which always starts
    /// at the active end of that session's conversation.
    static func shouldAutoScroll(
        from oldValue: PickyConversationBottomScrollTrigger?,
        to newValue: PickyConversationBottomScrollTrigger,
        isPinnedToBottom: Bool
    ) -> Bool {
        guard let oldValue else { return true }
        return isPinnedToBottom
            || isLocalSubmission(from: oldValue, to: newValue)
            || shouldRepinAfterQuestionCollapse(from: oldValue, to: newValue)
    }

    static func shouldMarkContentUnread(
        from oldValue: PickyConversationBottomScrollTrigger,
        to newValue: PickyConversationBottomScrollTrigger,
        isPinnedToBottom: Bool
    ) -> Bool {
        !isPinnedToBottom
            && !shouldAutoScroll(from: oldValue, to: newValue, isPinnedToBottom: false)
            && hasNewContent(from: oldValue, to: newValue)
    }

    static func shouldShowJumpToLatest(isPinnedToBottom: Bool, hasUnreadContent: Bool) -> Bool {
        !isPinnedToBottom && hasUnreadContent
    }

    static func isBottomAnchorPinned(maxY: CGFloat, viewportHeight: CGFloat) -> Bool {
        maxY <= viewportHeight + bottomPinThreshold
    }

    static func shouldReportInitialBottomPinReady(
        completedProgrammaticBottomPin: Bool,
        hasReported: Bool
    ) -> Bool {
        completedProgrammaticBottomPin && !hasReported
    }

    static func shouldRepinAfterQuestionCollapse(
        from oldValue: PickyConversationBottomScrollTrigger,
        to newValue: PickyConversationBottomScrollTrigger
    ) -> Bool {
        oldValue.pendingExtensionUiRequestID != nil && newValue.pendingExtensionUiRequestID == nil
    }

    private static func isLocalSubmission(
        from oldValue: PickyConversationBottomScrollTrigger,
        to newValue: PickyConversationBottomScrollTrigger
    ) -> Bool {
        oldValue.lastRequestAt != newValue.lastRequestAt
    }

    private static func hasNewContent(
        from oldValue: PickyConversationBottomScrollTrigger,
        to newValue: PickyConversationBottomScrollTrigger
    ) -> Bool {
        oldValue.latestMessageID != newValue.latestMessageID
            || oldValue.queuedSteers != newValue.queuedSteers
            || oldValue.queuedFollowUps != newValue.queuedFollowUps
            || (oldValue.pendingExtensionUiRequestID == nil && newValue.pendingExtensionUiRequestID != nil)
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
    var hasProgressOverlay = false
}

/// Single source of truth for the message → bubble mapping. The render path
/// (`PickyConversationListView.messageView`) switches on this to pick the
/// bubble view, and `renderSnapshot` aggregates the same classification, so
/// tests exercise exactly the conditions the UI renders with.
enum PickyConversationBubbleKind: Equatable {
    case userText
    case commandReceipt
    case subagentInvocation
    case agentText
    case typing
    case question
    /// `agentQuestion` without a decoded request falls back to a plain agent bubble.
    case questionFallback
    case error
    case activitySummary
    /// `agentActivity` whose snapshot has no visible tool calls renders nothing.
    case hiddenActivity
    case compactCompletion
    case compactFailure
    case notify
    /// Plain `system` message rendered through the agent bubble surface.
    case systemText

    init(message: PickySessionMessage) {
        switch message.kind {
        case .userText:
            self = .userText
        case .commandReceipt:
            self = .commandReceipt
        case .subagentInvocation:
            self = message.subagentInvocation == nil ? .hiddenActivity : .subagentInvocation
        case .agentText:
            self = .agentText
        case .agentThinking:
            self = .typing
        case .agentQuestion:
            self = message.question != nil ? .question : .questionFallback
        case .agentError:
            self = .error
        case .agentActivity:
            self = message.activitySnapshot?.visibleToolCallItems.isEmpty == false ? .activitySummary : .hiddenActivity
        case .system:
            if message.isCompactCompletionMessage {
                self = .compactCompletion
            } else if message.isCompactFailureMessage {
                self = .compactFailure
            } else if message.notifyType != nil {
                self = .notify
            } else {
                self = .systemText
            }
        }
    }
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
    var subagentInvocationBubbleCount = 0
    var turnCardCount = 0
    var showsActivitySummary = false
}

/// The only bubble value reader in the registry-backed render path. The
/// enclosing turn's identity comes from its leading message ID, while this
/// stable store observes the leaf value. Replacing a streamed message with the
/// same ID therefore preserves both its group and sibling bubble identities.
@MainActor
private struct PickyConversationMessageLeafView<Content: View>: View, Equatable {
    let messageStore: PickyMessageStore
    /// These presentation inputs are computed by the parent from session-scoped
    /// state. They must participate in equality: a new agent reply makes the
    /// preceding reply compact, and holding Command toggles the latest reply's
    /// shortcut badge even when neither stable message value changes.
    let isLatestAgentResponse: Bool
    let isLatestResponseShortcutHintVisible: Bool
    let onBodyEvaluation: () -> Void
    @ViewBuilder let content: (PickySessionMessage, Bool, Bool) -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageStore.messageID == rhs.messageStore.messageID
            && lhs.isLatestAgentResponse == rhs.isLatestAgentResponse
            && lhs.isLatestResponseShortcutHintVisible == rhs.isLatestResponseShortcutHintVisible
    }

    var body: some View {
        let _ = onBodyEvaluation()
        if case .loaded(let message) = messageStore.messageState {
            content(message, isLatestAgentResponse, isLatestResponseShortcutHintVisible)
        }
    }
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
