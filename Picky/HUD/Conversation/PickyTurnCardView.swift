//
//  PickyTurnCardView.swift
//  Picky
//
//  Turn-grouped collapsible container for conversation messages.
//
//  A "turn" is a slice of `session.messages` starting at a `userText`
//  or `commandReceipt` message and continuing until the next boundary (or end of list).
//  Each turn renders as a card whose body is the agent activity in
//  response to that user input. The two most recent turns always stay expanded
//  and have no collapse state. Older turns default to collapsed and retain their
//  manual expansion controls.
//

import Foundation
import SwiftUI

/// One turn worth of conversation messages, derived from `visibleMessages`
/// in `PickyConversationListView`. The leading user/command message itself is held alongside
/// (rendered above the card) while `bodyMessages` is the agent activity that
/// the card actually wraps.
struct PickyTurnGroup: Identifiable, Equatable {
    /// Stable identifier — the leading `userText` or `commandReceipt` message id when present.
    /// Pre-turn slices (no leading boundary) use `Self.preTurnID` so list
    /// `ForEach` stays stable across updates.
    let id: String
    let userMessage: PickySessionMessage?
    let bodyMessages: [PickySessionMessage]
    /// Messages that originated inside this turn but must stay visible
    /// regardless of the card's collapsed/expanded state, so they render
    /// outside the turn card: auto-compaction success/failure system messages
    /// (tail compactions emitted after `agent_end` would otherwise be hidden
    /// inside an auto-collapsed completed turn) and the question bubble for
    /// the session's pending extension-ui request (a confirm/input prompt
    /// must never be hidden behind a collapsed card). See
    /// `PickyTurnGrouper.groups`.
    let trailingMessages: [PickySessionMessage]
    /// The current turn is the latest group while the session is still
    /// active (running / queued / waiting_for_input).
    let isCurrent: Bool
    /// The final group in the journal, regardless of session status.
    let isLatest: Bool
    /// One of the two most recent groups. Recent content stays fully visible and
    /// deliberately has no collapse state.
    let isRecent: Bool
    /// Live cumulative activity counts for the in-progress turn. agentd
    /// increments this on every tool call but only emits an agentActivity
    /// *message* once the turn commits, so the active turn must read this
    /// directly to keep the header `N tools` count current. Always nil for
    /// completed turns — those rely on the committed agentActivity snapshot.
    let liveActivitySummary: PickyActivitySummary?

    init(
        id: String,
        userMessage: PickySessionMessage?,
        bodyMessages: [PickySessionMessage],
        trailingMessages: [PickySessionMessage] = [],
        isCurrent: Bool,
        isLatest: Bool = false,
        isRecent: Bool = false,
        liveActivitySummary: PickyActivitySummary? = nil
    ) {
        self.id = id
        self.userMessage = userMessage
        self.bodyMessages = bodyMessages
        self.trailingMessages = trailingMessages
        self.isCurrent = isCurrent
        self.isLatest = isLatest
        self.isRecent = isRecent || isLatest
        self.liveActivitySummary = liveActivitySummary
    }

    static let preTurnID = "__picky_pre_turn__"

    var hasUserMessage: Bool { userMessage != nil }

    /// The message that should represent the turn when collapsed: the most
    /// recent text-bearing agent reply, falling back to the most recent error.
    /// Compaction system messages are not considered here because the grouper
    /// pulls them into `trailingMessages` and renders them outside the
    /// card.
    var collapsedRepresentativeMessage: PickySessionMessage? {
        if let lastAgentText = bodyMessages.last(where: { msg in
            switch msg.kind {
            case .agentText: return true
            case .system: return true
            default: return false
            }
        }) {
            return lastAgentText
        }
        return bodyMessages.last(where: { $0.kind == .agentError })
    }

    var summary: PickyTurnSummary {
        summary(now: nil)
    }

    func summary(now: Date?) -> PickyTurnSummary {
        let stepCount = bodyMessages.count
        let firstAt = userMessage?.createdAt ?? bodyMessages.first?.createdAt
        let lastAt: Date?
        if isCurrent, let now {
            lastAt = now
        } else {
            lastAt = bodyMessages.last?.createdAt ?? firstAt
        }
        let elapsed: Int
        if let first = firstAt, let last = lastAt {
            elapsed = max(0, Int(last.timeIntervalSince(first)))
        } else {
            elapsed = 0
        }
        // For the in-progress turn the agentActivity *message* hasn't been
        // committed yet (agentd emits it only on turn boundary), so fall
        // through to the live session counter that increments per tool call.
        // Completed turns read the committed snapshot embedded in the last
        // agentActivity body message; earlier snapshots are subsumed by it.
        let toolCount: Int = {
            if isCurrent, let live = liveActivitySummary {
                return live.totalToolCalls
            }
            return bodyMessages
                .reversed()
                .first(where: { $0.kind == .agentActivity && $0.activitySnapshot != nil })?
                .activitySnapshot?
                .totalToolCalls ?? 0
        }()
        return PickyTurnSummary(
            stepCount: stepCount,
            toolCount: toolCount,
            elapsedSeconds: elapsed,
            showsStepCount: isCurrent
        )
    }
}

/// Compact stats for a turn. Active turns include the live "N steps" count;
/// completed turns omit it because thinking messages are cleared on terminal
/// status, making the persisted body message count a poor proxy for work steps.
struct PickyTurnSummary: Equatable {
    let stepCount: Int
    let toolCount: Int
    let elapsedSeconds: Int
    let showsStepCount: Bool

    init(stepCount: Int, toolCount: Int, elapsedSeconds: Int, showsStepCount: Bool = true) {
        self.stepCount = stepCount
        self.toolCount = toolCount
        self.elapsedSeconds = elapsedSeconds
        self.showsStepCount = showsStepCount
    }

    var displayText: String {
        var parts: [String] = []
        if showsStepCount {
            parts.append(L10n.t(
                stepCount == 1 ? "hud.conversation.turn.step.one" : "hud.conversation.turn.step.many",
                Int64(stepCount)
            ))
        }
        // Suppress "0 tools" so thinking-only turns / pre-tool-call moments
        // don't draw attention to a zero that does not mean anything yet.
        if toolCount > 0 {
            parts.append(L10n.t(
                toolCount == 1 ? "hud.conversation.turn.tool.one" : "hud.conversation.turn.tool.many",
                Int64(toolCount)
            ))
        }
        parts.append(elapsedDisplayText)
        return parts.joined(separator: " · ")
    }

    var expandedDisplayText: String { elapsedDisplayText }

    var elapsedDisplayText: String {
        if elapsedSeconds < 60 {
            return L10n.t("hud.conversation.duration.seconds", Int64(elapsedSeconds))
        }
        let minutes = elapsedSeconds / 60
        if minutes < 60 {
            return L10n.t("hud.conversation.duration.minutes", Int64(minutes))
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? L10n.t("hud.conversation.duration.hours", Int64(hours))
            : L10n.t("hud.conversation.duration.hoursMinutes", Int64(hours), Int64(remainingMinutes))
    }
}


/// Pure, flat-summary projection for a collapsed Focus Stack chapter. It owns
/// no message state and deliberately keeps the original message leaves out of
/// the collapsed tree. Expanding the chapter renders those original leaves once
/// through `PickyTurnCardView.messageContent`.
struct PickyFocusStackPriorChapterPresentation: Equatable {
    enum ResponseKind: Equatable {
        case response
        case error
        case unavailable
    }

    let requestText: String
    let responseText: String?
    let responseKind: ResponseKind
    let summary: PickyTurnSummary

    init(group: PickyTurnGroup) {
        requestText = Self.oneLinePlainText(
            group.userMessage?.text ?? group.userMessage?.commandReceipt?.command
        ) ?? L10n.t("hud.conversation.turn.request")
        summary = group.summary

        guard let representative = group.collapsedRepresentativeMessage else {
            responseText = nil
            responseKind = .unavailable
            return
        }

        if representative.kind == .agentError {
            responseText = Self.oneLinePlainText(
                representative.errorMessage ?? representative.text ?? representative.errorContext
            ) ?? L10n.t("hud.conversation.turn.error")
            responseKind = .error
        } else {
            responseText = Self.oneLinePlainText(representative.text)
            responseKind = responseText == nil ? .unavailable : .response
        }
    }

    static func oneLinePlainText(_ text: String?) -> String? {
        guard let text else { return nil }
        let plainText: String
        if let attributed = try? AttributedString(markdown: text) {
            plainText = String(attributed.characters)
        } else {
            plainText = text
        }
        let normalized = plainText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

/// Builds turn groups from a flat slice of `visibleMessages`. Marks the last
/// group as `isCurrent` when the session is still in an active state.
enum PickyTurnGrouper {
    static let activeStatuses: Set<PickySessionStatus> = [.running, .queued, .waiting_for_input]

    /// Collapses multiple `agent_activity` snapshots inside a single turn into
    /// one synthesized chip placed at the position of the last activity entry.
    /// The Pi terminal session syncer emits one `agent_activity` per Pi
    /// assistant entry (see `agentd/src/application/pi-session-syncer.ts`),
    /// which would otherwise render as a long ladder of `read 1 / bash 1 / …`
    /// chips. Live sessions already commit a single per-turn snapshot via
    /// `commitTurnActivityNow`, so this is a no-op for them.
    ///
    /// The synthesized message keeps the last activity's `id` and `createdAt`
    /// so `agentActivityScope` still walks back to the prior `user_text` and
    /// the resulting tool-history scope covers every tool in the turn.
    /// Removes auto-compaction system messages from the in-card body and
    /// returns them as a separate list so the conversation list can render
    /// them outside the (possibly collapsed) turn card. Tail compactions that
    /// run after `agent_end` would otherwise be hidden behind the
    /// auto-collapsed completed-turn header.
    static func splitCompactSystemMessages(_ messages: [PickySessionMessage]) -> (body: [PickySessionMessage], compact: [PickySessionMessage]) {
        var body: [PickySessionMessage] = []
        var compact: [PickySessionMessage] = []
        body.reserveCapacity(messages.count)
        for message in messages {
            if message.isCompactCompletionMessage || message.isCompactFailureMessage {
                compact.append(message)
            } else {
                body.append(message)
            }
        }
        return (body, compact)
    }

    static func mergeActivitySnapshots(_ messages: [PickySessionMessage]) -> [PickySessionMessage] {
        let activityIndices = messages.indices.filter { idx in
            messages[idx].kind == .agentActivity && messages[idx].activitySnapshot != nil
        }
        guard activityIndices.count > 1 else { return messages }

        var combined = PickyActivitySummary.zero
        for idx in activityIndices {
            guard let snap = messages[idx].activitySnapshot else { continue }
            combined.read += snap.read
            combined.bash += snap.bash
            combined.edit += snap.edit
            combined.write += snap.write
            combined.todo += snap.todo
            combined.subagent += snap.subagent
            combined.thinking += snap.thinking
            combined.other += snap.other
        }

        let lastIdx = activityIndices.last!
        let template = messages[lastIdx]
        let merged = PickySessionMessage(
            id: template.id,
            kind: .agentActivity,
            createdAt: template.createdAt,
            originatedBy: template.originatedBy,
            text: nil,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: combined,
            assistantRun: nil,
            errorContext: nil,
            errorMessage: nil
        )

        var result: [PickySessionMessage] = []
        result.reserveCapacity(messages.count - activityIndices.count + 1)
        for (idx, message) in messages.enumerated() {
            if message.kind == .agentActivity && message.activitySnapshot != nil {
                if idx == lastIdx { result.append(merged) }
            } else {
                result.append(message)
            }
        }
        return result
    }

    /// Collapses adjacent `agentThinking` messages inside a turn into a single,
    /// chronologically anchored message. The first message id is preserved so
    /// SwiftUI identity remains stable while the final timestamp is used for
    /// elapsed/summary ordering.
    static func mergeConsecutiveThinking(_ messages: [PickySessionMessage]) -> [PickySessionMessage] {
        guard messages.count > 1 else { return messages }

        var output: [PickySessionMessage] = []
        output.reserveCapacity(messages.count)

        for message in messages {
            guard
                let last = output.last,
                last.kind == .agentThinking,
                message.kind == .agentThinking
            else {
                output.append(message)
                continue
            }

            let mergedTextPieces = [last.text, message.text].compactMap { text -> String? in
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : text
            }
            let mergedText = mergedTextPieces.isEmpty ? nil : mergedTextPieces.joined(separator: "\n\n")

            let merged = PickySessionMessage(
                id: last.id,
                kind: .agentThinking,
                createdAt: message.createdAt,
                originatedBy: last.originatedBy,
                text: mergedText,
                question: last.question,
                cancelledAt: last.cancelledAt,
                activitySnapshot: last.activitySnapshot,
                assistantRun: last.assistantRun,
                errorContext: last.errorContext,
                errorMessage: last.errorMessage,
                notifyType: last.notifyType,
                commandReceipt: last.commandReceipt,
                attachedImagesCount: last.attachedImagesCount
            )
            output[output.count - 1] = merged
        }

        return output
    }

    static func groups(
        from messages: [PickySessionMessage],
        sessionStatus: PickySessionStatus,
        liveActivitySummary: PickyActivitySummary? = nil,
        pendingQuestionRequestID: String? = nil
    ) -> [PickyTurnGroup] {
        guard !messages.isEmpty else { return [] }

        var output: [PickyTurnGroup] = []
        var currentUser: PickySessionMessage? = nil
        var currentBody: [PickySessionMessage] = []
        var hasOpenedAnyGroup = false

        func flush() {
            // Skip the implicit pre-turn slice when it carries no body messages.
            if currentUser == nil && currentBody.isEmpty { return }
            let id = currentUser?.id ?? PickyTurnGroup.preTurnID
            let merged = mergeConsecutiveThinking(mergeActivitySnapshots(currentBody))
            var (body, trailing) = splitCompactSystemMessages(merged)
            // Hoist the pending extension-ui question out of the card body so an
            // active INPUT NEEDED bubble can never hide behind a collapsed turn
            // card. This matters when the question arrives before the turn's
            // leading user_text/command_receipt materializes (e.g. a follow-up on
            // an idle session whose user_text drains only after the turn ends):
            // the question then lands in the previous completed turn, whose card
            // has latched to collapsed. Once answered, the request id no longer
            // matches and the message returns to the body as regular history.
            if let pendingQuestionRequestID {
                let hoisted = body.filter { $0.question?.id == pendingQuestionRequestID }
                if !hoisted.isEmpty {
                    body.removeAll { $0.question?.id == pendingQuestionRequestID }
                    trailing.append(contentsOf: hoisted)
                }
            }
            output.append(
                PickyTurnGroup(
                    id: id,
                    userMessage: currentUser,
                    bodyMessages: body,
                    trailingMessages: trailing,
                    isCurrent: false
                )
            )
            hasOpenedAnyGroup = true
        }

        for message in messages {
            if message.kind == .userText || message.kind == .commandReceipt {
                if hasOpenedAnyGroup || currentUser != nil || !currentBody.isEmpty {
                    flush()
                }
                currentUser = message
                currentBody = []
            } else {
                currentBody.append(message)
            }
        }
        flush()

        guard !output.isEmpty else { return [] }

        let latestIndex = output.count - 1
        let recentStartIndex = max(0, output.count - 2)
        let latestIsCurrent = activeStatuses.contains(sessionStatus)
        return output.enumerated().map { index, group in
            let isLatest = index == latestIndex
            return PickyTurnGroup(
                id: group.id,
                userMessage: group.userMessage,
                bodyMessages: group.bodyMessages,
                trailingMessages: group.trailingMessages,
                isCurrent: isLatest && latestIsCurrent,
                isLatest: isLatest,
                isRecent: index >= recentStartIndex,
                liveActivitySummary: isLatest && latestIsCurrent ? liveActivitySummary : nil
            )
        }
    }
}

/// Expansion policy for older turn cards. Pulled out of the view so the
/// race-window latching (see `hasBeenSeenComplete`) is directly unit-testable.
/// `PickyTurnChapterPolicy` bypasses it for the two most recent groups.
///
/// Lifecycle:
///   • `manualExpansion` wins when set — user toggles override the default.
///   • `hasBeenSeenComplete` latches to true the first time `observe(isCurrent:)`
///     is called with `isCurrent == false`. Once latched, the default falls back
///     to collapsed even if `group.isCurrent` flips true again. This guards the
///     race where agentd emits `status:running` before the new user_text journal
///     entry on a follow-up submit (see `pushPendingQueueDelivery` in
///     `agentd/src/session-supervisor.ts`): without latching, the previously
///     completed turn briefly becomes the "last group" of an active session and
///     auto-expands for a single frame before the new user_text arrives and
///     pushes it back to non-current.
struct PickyTurnExpansionPolicy: Equatable {
    var manualExpansion: Bool? = nil
    var hasBeenSeenComplete: Bool = false

    func isExpanded(isCurrent: Bool) -> Bool {
        if let manualExpansion { return manualExpansion }
        if hasBeenSeenComplete { return false }
        return isCurrent
    }

    mutating func observe(isCurrent: Bool) {
        if !isCurrent { hasBeenSeenComplete = true }
    }

    mutating func setManualExpansion(_ value: Bool) {
        manualExpansion = value
    }
}

enum PickyTurnChapterPolicy {
    static func canCollapse(isRecent: Bool) -> Bool {
        !isRecent
    }

    static func isExpanded(
        isRecent: Bool,
        isCurrent: Bool,
        expansion: PickyTurnExpansionPolicy
    ) -> Bool {
        isRecent || expansion.isExpanded(isCurrent: isCurrent)
    }
}

enum PickyFocusStackChapterAccessibilityPresentation {
    static func label(isCurrent: Bool, isLatest: Bool) -> String {
        if isLatest { return L10n.t("hud.conversation.turn.latest.accessibilityLabel") }
        return isCurrent
            ? L10n.t("hud.conversation.turn.current.accessibilityLabel")
            : L10n.t("hud.conversation.turn.previous.accessibilityLabel")
    }

    static func value(isExpanded: Bool, detail: String) -> String {
        L10n.t(
            isExpanded ? "hud.conversation.turn.expanded.accessibilityValue" : "hud.conversation.turn.collapsed.accessibilityValue",
            detail
        )
    }

    static func visualState(isCurrent: Bool, isLatest: Bool) -> String? {
        if isLatest { return L10n.t("hud.conversation.turn.latest") }
        return isCurrent ? L10n.t("hud.conversation.turn.current") : nil
    }
}

/// Focus Stack chapter. Older turns collapse into a flat summary; expanded
/// chapters render each original message exactly once through the caller's
/// stable leaf closure. The two most recent turns are permanently expanded.
struct PickyTurnCardView<MessageContent: View>: View {
    let group: PickyTurnGroup
    /// The tool currently running in this turn, used to render a live
    /// "what the agent is doing right now" indicator at the bottom of the
    /// expanded body. Only the active turn passes a non-nil value.
    var activeTool: PickyToolActivity? = nil
    /// Tap handler for the active-tool indicator, typically opening the
    /// session-scoped tool history viewer.
    var onOpenActiveToolHistory: (() -> Void)? = nil
    @ViewBuilder let messageContent: (PickySessionMessage) -> MessageContent

    @State private var expansion = PickyTurnExpansionPolicy()

    /// The two most recent turns are permanent, non-collapsible reading
    /// surfaces. Older turns retain the manual expansion and race-latch policy.
    var isExpanded: Bool {
        PickyTurnChapterPolicy.isExpanded(
            isRecent: group.isRecent,
            isCurrent: group.isCurrent,
            expansion: expansion
        )
    }

    private var priorChapterPresentation: PickyFocusStackPriorChapterPresentation {
        PickyFocusStackPriorChapterPresentation(group: group)
    }

    var body: some View {
        let _ = PickyPerf.event("turn_card_body")
        Group {
            if isExpanded {
                expandedChapter
                    .transition(.opacity)
            } else {
                collapsedPriorChapter
                    .transition(.opacity)
            }
        }
        // Scope the toggle animation to this chapter. The parent list and
        // composer remain outside the transaction, preventing downstream rows
        // from sliding through a fading collapsed chapter.
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .onAppear { expansion.observe(isCurrent: group.isCurrent) }
        .onChange(of: group.isCurrent) { _, isCurrent in
            expansion.observe(isCurrent: isCurrent)
        }
    }

    private var expandedChapter: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            if group.isLatest {
                latestHeader
            } else if group.isRecent {
                recentHeader
            } else {
                expandedHeader
            }
            if let userMessage = group.userMessage {
                messageContent(userMessage)
            }
            // Render the active tool row even when there are no body messages so a
            // tool-only running turn (no thinking, no agent_text, no committed
            // agent_activity yet) still shows live progress below the user bubble.
            if !group.bodyMessages.isEmpty || activeTool != nil {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    ForEach(group.bodyMessages, id: \.id) { message in
                        messageContent(message)
                    }
                    if let activeTool {
                        PickyToolCallInlineRow(tool: activeTool, onTap: onOpenActiveToolHistory ?? {})
                    }
                }
                // Keep the request bubble and the first reasoning/response row
                // as separate reading blocks. The outer stack already supplies
                // 8pt; this adds 12pt without loosening spacing inside the response.
                .padding(.top, group.userMessage == nil ? 0 : DS.Spacing.space3)
            }
        }
    }

    @ViewBuilder
    private var latestHeader: some View {
        if group.isCurrent {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let _ = PickyPerf.event("turn_card_header_timeline_tick")
                latestChapterHeader(summary: group.summary(now: context.date))
            }
        } else {
            latestChapterHeader(summary: group.summary)
        }
    }

    private func latestChapterHeader(summary: PickyTurnSummary) -> some View {
        HStack(spacing: DS.Spacing.space1) {
            Text(L10n.t("hud.conversation.turn.latest"))
                .font(PickyHUDTypography.metaSemibold)
                .foregroundColor(group.isCurrent ? DS.Colors.info : DS.Colors.textSecondary)
            Text(summary.expandedDisplayText)
                .font(PickyHUDTypography.metaSemibold)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(
            isCurrent: group.isCurrent,
            isLatest: true
        ))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: true,
            detail: summary.expandedDisplayText
        ))
    }

    private var recentHeader: some View {
        HStack(spacing: DS.Spacing.space1) {
            Text(group.summary.expandedDisplayText)
                .font(PickyHUDTypography.metaSemibold)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(
            isCurrent: group.isCurrent,
            isLatest: false
        ))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: true,
            detail: group.summary.expandedDisplayText
        ))
    }

    @ViewBuilder
    private var expandedHeader: some View {
        if group.isCurrent {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let _ = PickyPerf.event("turn_card_header_timeline_tick")
                chapterHeader(summary: group.summary(now: context.date))
            }
        } else {
            chapterHeader(summary: group.summary)
        }
    }

    private func chapterHeader(summary: PickyTurnSummary) -> some View {
        Button {
            expansion.setManualExpansion(false)
        } label: {
            HStack(spacing: DS.Spacing.space1) {
                Image(systemName: "chevron.down")
                    .pickyFont(size: 9, weight: .bold)
                    .foregroundColor(headerForegroundColor)
                if group.isCurrent {
                    Circle()
                        .fill(DS.Colors.info)
                        .frame(width: DS.Spacing.space1, height: DS.Spacing.space1)
                }
                Text(summary.expandedDisplayText)
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(
            isCurrent: group.isCurrent,
            isLatest: group.isLatest
        ))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: true,
            detail: summary.expandedDisplayText
        ))
        .accessibilityHint(L10n.t("hud.conversation.turn.collapse.accessibilityHint"))
        .hoverAffordance()
    }

    private var collapsedPriorChapter: some View {
        let presentation = priorChapterPresentation
        return Button {
            expansion.setManualExpansion(true)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                HStack(spacing: DS.Spacing.space1) {
                    if let visualState = PickyFocusStackChapterAccessibilityPresentation.visualState(
                        isCurrent: group.isCurrent,
                        isLatest: group.isLatest
                    ) {
                        Text(visualState)
                            .font(PickyHUDTypography.metaSemibold)
                            .foregroundColor(headerForegroundColor)
                    }
                    Image(systemName: "chevron.right")
                        .pickyFont(size: 9, weight: .bold)
                        .foregroundColor(headerForegroundColor)
                    Text(presentation.requestText)
                        .font(PickyHUDTypography.bodyCompactMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                if let responseText = presentation.responseText {
                    Text(responseText)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(
                            presentation.responseKind == .error
                                ? DS.Colors.destructiveText
                                : DS.Colors.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(
            isCurrent: group.isCurrent,
            isLatest: group.isLatest
        ))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: false,
            detail: collapsedAccessibilityValue(for: presentation)
        ))
        .accessibilityHint(L10n.t("hud.conversation.turn.expand.accessibilityHint"))
        .hoverAffordance()
    }

    private var headerForegroundColor: Color {
        group.isCurrent ? DS.Colors.info : DS.Colors.textTertiary
    }

    private func collapsedAccessibilityValue(for presentation: PickyFocusStackPriorChapterPresentation) -> String {
        [presentation.requestText, presentation.responseText]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
