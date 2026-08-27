//
//  PickyTurnCardView.swift
//  Picky
//
//  Turn-grouped collapsible container for conversation messages.
//
//  A "turn" is a slice of `session.messages` starting at a `userText`
//  or `commandReceipt` message and continuing until the next boundary (or end of list).
//  Each turn renders as a card whose body is the agent activity in
//  response to that user input. The current turn (last group while the
//  session is still active) defaults to expanded; older turns default
//  to collapsed. The user can toggle the chevron at any time.
//

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
    /// "active" (running / queued / waiting_for_input). It is the only
    /// group that defaults to expanded.
    let isCurrent: Bool
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
        liveActivitySummary: PickyActivitySummary? = nil
    ) {
        self.id = id
        self.userMessage = userMessage
        self.bodyMessages = bodyMessages
        self.trailingMessages = trailingMessages
        self.isCurrent = isCurrent
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
            parts.append("\(stepCount) " + (stepCount == 1 ? "step" : "steps"))
        }
        // Suppress "0 tools" so thinking-only turns / pre-tool-call moments
        // don't draw attention to a zero that does not mean anything yet.
        if toolCount > 0 {
            parts.append("\(toolCount) " + (toolCount == 1 ? "tool" : "tools"))
        }
        parts.append(elapsedDisplayText)
        return parts.joined(separator: " · ")
    }

    var elapsedDisplayText: String {
        if elapsedSeconds < 60 { return "\(elapsedSeconds)s" }
        let minutes = elapsedSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
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
        requestText = Self.oneLineText(
            group.userMessage?.text ?? group.userMessage?.commandReceipt?.command
        ) ?? "Request"
        summary = group.summary

        guard let representative = group.collapsedRepresentativeMessage else {
            responseText = nil
            responseKind = .unavailable
            return
        }

        if representative.kind == .agentError {
            responseText = Self.oneLineText(
                representative.errorMessage ?? representative.text ?? representative.errorContext
            ) ?? "Error"
            responseKind = .error
        } else {
            responseText = Self.oneLineText(representative.text)
            responseKind = responseText == nil ? .unavailable : .response
        }
    }

    private static func oneLineText(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text
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

        if activeStatuses.contains(sessionStatus) {
            let last = output.removeLast()
            output.append(
                PickyTurnGroup(
                    id: last.id,
                    userMessage: last.userMessage,
                    bodyMessages: last.bodyMessages,
                    trailingMessages: last.trailingMessages,
                    isCurrent: true,
                    liveActivitySummary: liveActivitySummary
                )
            )
        }
        return output
    }
}

/// Default-expansion policy for a turn card. Pulled out of the view so the
/// race-window latching (see `hasBeenSeenComplete`) is directly unit-testable.
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

enum PickyFocusStackChapterAccessibilityPresentation {
    static func label(isCurrent: Bool) -> String {
        isCurrent ? "Current turn" : "Previous turn"
    }

    static func value(isExpanded: Bool, detail: String) -> String {
        "\(isExpanded ? "Expanded" : "Collapsed"). \(detail)"
    }

    static func visualState(isCurrent: Bool) -> String? {
        isCurrent ? "Current" : nil
    }
}

/// Collapsible Focus Stack chapter. Prior turns collapse into a flat summary;
/// expanded chapters render each original message exactly once through the
/// caller's stable leaf closure. The current turn stays expanded by default.
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

    /// Default-expansion policy: current turn = expanded, older turn = collapsed,
    /// user toggles override. The `hasBeenSeenComplete` latch inside
    /// `PickyTurnExpansionPolicy` keeps a previously-completed turn collapsed
    /// during the brief window where agentd emits `status:running` before the
    /// follow-up's user_text journal entry.
    var isExpanded: Bool {
        expansion.isExpanded(isCurrent: group.isCurrent)
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
            expandedHeader
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
            }
        }
        .padding(.leading, group.isCurrent ? DS.Spacing.space2 : 0)
        .overlay(alignment: .leading) {
            if group.isCurrent {
                Rectangle()
                    .fill(DS.Colors.info.opacity(0.45))
                    .frame(width: DS.Spacing.space1)
                    .accessibilityHidden(true)
            }
        }
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
                Text(summary.displayText)
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(isCurrent: group.isCurrent))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: true,
            detail: summary.displayText
        ))
        .accessibilityHint("Collapse chapter")
        .hoverAffordance()
    }

    private var collapsedPriorChapter: some View {
        let presentation = priorChapterPresentation
        return Button {
            expansion.setManualExpansion(true)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                HStack(spacing: DS.Spacing.space1) {
                    if let visualState = PickyFocusStackChapterAccessibilityPresentation.visualState(isCurrent: group.isCurrent) {
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
                HStack(spacing: DS.Spacing.space2) {
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
                    Spacer(minLength: 0)
                    Text(presentation.summary.displayText)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.vertical, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PickyFocusStackChapterAccessibilityPresentation.label(isCurrent: group.isCurrent))
        .accessibilityValue(PickyFocusStackChapterAccessibilityPresentation.value(
            isExpanded: false,
            detail: collapsedAccessibilityValue(for: presentation)
        ))
        .accessibilityHint("Expand chapter")
        .hoverAffordance()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.65))
                .frame(height: 0.5) // design-token-exception: one-point separator needs a half-point hairline for pixel alignment
                .accessibilityHidden(true)
        }
    }

    private var headerForegroundColor: Color {
        group.isCurrent ? DS.Colors.info : DS.Colors.textTertiary
    }

    private func collapsedAccessibilityValue(for presentation: PickyFocusStackPriorChapterPresentation) -> String {
        [presentation.requestText, presentation.responseText, presentation.summary.displayText]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
