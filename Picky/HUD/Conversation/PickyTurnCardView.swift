//
//  PickyTurnCardView.swift
//  Picky
//
//  Turn-grouped collapsible container for conversation messages.
//
//  A "turn" is a slice of `session.messages` starting at a `userText`
//  message and continuing until the next `userText` (or end of list).
//  Each turn renders as a card whose body is the agent activity in
//  response to that user input. The current turn (last group while the
//  session is still active) defaults to expanded; older turns default
//  to collapsed. The user can toggle the chevron at any time.
//

import SwiftUI

/// One turn worth of conversation messages, derived from `visibleMessages`
/// in `PickyConversationListView`. The user message itself is held alongside
/// (rendered above the card) while `bodyMessages` is the agent activity that
/// the card actually wraps.
struct PickyTurnGroup: Identifiable, Equatable {
    /// Stable identifier — the leading `userText` message id when present.
    /// Pre-turn slices (no leading user_text) use `Self.preTurnID` so list
    /// `ForEach` stays stable across updates.
    let id: String
    let userMessage: PickySessionMessage?
    let bodyMessages: [PickySessionMessage]
    /// The current turn is the latest group while the session is still
    /// "active" (running / queued / waiting_for_input). It is the only
    /// group that defaults to expanded.
    let isCurrent: Bool

    static let preTurnID = "__picky_pre_turn__"

    var hasUserMessage: Bool { userMessage != nil }

    /// The message that should represent the turn when collapsed: the most
    /// recent text-bearing agent reply, falling back to the most recent error.
    var collapsedRepresentativeMessage: PickySessionMessage? {
        if let lastAgentText = bodyMessages.last(where: { msg in
            switch msg.kind {
            case .agentText: return true
            case .system: return !msg.isCompactCompletionMessage
            default: return false
            }
        }) {
            return lastAgentText
        }
        return bodyMessages.last(where: { $0.kind == .agentError })
    }

    var summary: PickyTurnSummary {
        let toolCount = bodyMessages.reduce(0) { acc, msg in
            acc + (msg.activitySnapshot?.visibleToolCallItems.count ?? 0)
        }
        let stepCount = bodyMessages.count
        let firstAt = userMessage?.createdAt ?? bodyMessages.first?.createdAt
        let lastAt = bodyMessages.last?.createdAt ?? firstAt
        let elapsed: Int
        if let first = firstAt, let last = lastAt {
            elapsed = max(0, Int(last.timeIntervalSince(first)))
        } else {
            elapsed = 0
        }
        return PickyTurnSummary(stepCount: stepCount, toolCount: toolCount, elapsedSeconds: elapsed)
    }
}

/// Compact stats for a turn, rendered as a "N steps · M tools · Ts" chip.
struct PickyTurnSummary: Equatable {
    let stepCount: Int
    let toolCount: Int
    let elapsedSeconds: Int

    var displayText: String {
        var parts: [String] = []
        parts.append("\(stepCount) " + (stepCount == 1 ? "step" : "steps"))
        parts.append("\(toolCount) " + (toolCount == 1 ? "tool" : "tools"))
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

    static func groups(
        from messages: [PickySessionMessage],
        sessionStatus: PickySessionStatus
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
            output.append(
                PickyTurnGroup(
                    id: id,
                    userMessage: currentUser,
                    bodyMessages: currentBody,
                    isCurrent: false
                )
            )
            hasOpenedAnyGroup = true
        }

        for message in messages {
            if message.kind == .userText {
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
                    isCurrent: true
                )
            )
        }
        return output
    }
}

/// Collapsible turn container. The card chrome is intentionally subtle —
/// just an outline + summary header — so existing bubble views keep their
/// own visual identity inside.
struct PickyTurnCardView<MessageContent: View>: View {
    let group: PickyTurnGroup
    @ViewBuilder let messageContent: (PickySessionMessage) -> MessageContent

    @State private var manualExpansion: Bool? = nil

    /// Tri-state expansion: nil falls back to the policy default
    /// (current turn = expanded, older turn = collapsed). User toggles
    /// override the default until the view is rebuilt.
    var isExpanded: Bool {
        manualExpansion ?? group.isCurrent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded {
                expandedBody
            } else {
                collapsedBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(turnCardBackground)
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                manualExpansion = !isExpanded
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(headerForegroundColor)
                if group.isCurrent {
                    Circle()
                        .fill(DS.Colors.info)
                        .frame(width: 5, height: 5)
                }
                Text(group.summary.displayText)
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
        .accessibilityValue(group.summary.displayText)
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")
    }

    private var headerForegroundColor: Color {
        group.isCurrent ? DS.Colors.info : DS.Colors.textTertiary
    }

    @ViewBuilder
    private var expandedBody: some View {
        if !group.bodyMessages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.bodyMessages, id: \.id) { message in
                    messageContent(message)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.4), lineWidth: 0.5)
            )
    }
}
