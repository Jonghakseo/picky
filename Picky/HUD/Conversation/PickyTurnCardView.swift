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
    /// Auto-compaction success/failure system messages that originated inside
    /// this turn. They live outside the turn card so they remain visible
    /// regardless of the card's collapsed/expanded state — tail compactions
    /// emitted after `agent_end` would otherwise be hidden inside an
    /// auto-collapsed completed turn. See `PickyTurnGrouper.groups`.
    let trailingCompactMessages: [PickySessionMessage]
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
        trailingCompactMessages: [PickySessionMessage] = [],
        isCurrent: Bool,
        liveActivitySummary: PickyActivitySummary? = nil
    ) {
        self.id = id
        self.userMessage = userMessage
        self.bodyMessages = bodyMessages
        self.trailingCompactMessages = trailingCompactMessages
        self.isCurrent = isCurrent
        self.liveActivitySummary = liveActivitySummary
    }

    static let preTurnID = "__picky_pre_turn__"

    var hasUserMessage: Bool { userMessage != nil }

    /// The message that should represent the turn when collapsed: the most
    /// recent text-bearing agent reply, falling back to the most recent error.
    /// Compaction system messages are not considered here because the grouper
    /// pulls them into `trailingCompactMessages` and renders them outside the
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

    static func groups(
        from messages: [PickySessionMessage],
        sessionStatus: PickySessionStatus,
        liveActivitySummary: PickyActivitySummary? = nil
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
            let merged = mergeActivitySnapshots(currentBody)
            let split = splitCompactSystemMessages(merged)
            output.append(
                PickyTurnGroup(
                    id: id,
                    userMessage: currentUser,
                    bodyMessages: split.body,
                    trailingCompactMessages: split.compact,
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
                    trailingCompactMessages: last.trailingCompactMessages,
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

/// Collapsible turn container. The card chrome is intentionally subtle —
/// just an outline + summary header — so existing bubble views keep their
/// own visual identity inside.
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
    /// follow-up's user_text journal entry — without the latch, the prior turn
    /// momentarily becomes the "last/active" group and auto-expands for a frame.
    var isExpanded: Bool {
        expansion.isExpanded(isCurrent: group.isCurrent)
    }

    var body: some View {
        let _ = PickyPerf.event("turn_card_body")
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded {
                expandedBody
                    .transition(.opacity)
            } else {
                collapsedBody
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(turnCardBackground)
        // Clip the body so the fade-out of children during collapse/expand is
        // bounded by the card's shrinking frame. Without this, the default
        // opacity transition leaves ghost rows drawn at their original Y while
        // the sibling user bubble of the next turn slides up through them —
        // see the implicit-animation-scope memo in project memory.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Scope the toggle animation to this card only. Previously a
        // `withAnimation` block in the header tap captured every downstream
        // layout change (next turn's user bubble, the following card,
        // composer) into one transaction, which is what caused the visual
        // overlap during collapse.
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .onAppear { expansion.observe(isCurrent: group.isCurrent) }
        .onChange(of: group.isCurrent) { _, isCurrent in
            expansion.observe(isCurrent: isCurrent)
        }
    }

    @ViewBuilder
    private var header: some View {
        if group.isCurrent {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let _ = PickyPerf.event("turn_card_header_timeline_tick")
                headerButton(summary: group.summary(now: context.date))
            }
        } else {
            headerButton(summary: group.summary)
        }
    }

    private func headerButton(summary: PickyTurnSummary) -> some View {
        Button {
            expansion.setManualExpansion(!isExpanded)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .pickyFont(size: 9, weight: .bold)
                    .foregroundColor(headerForegroundColor)
                if group.isCurrent {
                    Circle()
                        .fill(DS.Colors.info)
                        .frame(width: 5, height: 5)
                }
                Text(summary.displayText)
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Turn summary")
        .accessibilityValue(summary.displayText)
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")
    }

    private var headerForegroundColor: Color {
        group.isCurrent ? DS.Colors.info : DS.Colors.textTertiary
    }

    @ViewBuilder
    private var expandedBody: some View {
        // Render the active tool row even when there are no body messages so a
        // tool-only running turn (no thinking, no agent_text, no committed
        // agent_activity yet) still shows live progress below the user bubble.
        if !group.bodyMessages.isEmpty || activeTool != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.bodyMessages, id: \.id) { message in
                    messageContent(message)
                }
                if let activeTool {
                    PickyToolCallInlineRow(tool: activeTool, onTap: onOpenActiveToolHistory ?? {})
                }
            }
        }
    }

    @ViewBuilder
    private var collapsedBody: some View {
        if let representative = group.collapsedRepresentativeMessage {
            messageContent(representative)
        }
    }

    private var turnCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(group.isCurrent ? Color.clear : DS.Colors.surface2.opacity(0.18))
            .overlay(
                // `strokeBorder` draws inside the path so the outline is not
                // cropped by the body's `.clipShape` with the same shape.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
            )
    }
}
