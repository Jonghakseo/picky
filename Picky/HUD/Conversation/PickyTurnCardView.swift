//
//  PickyTurnCardView.swift
//  Picky
//
//  Turn-grouped container for conversation messages.
//
//  A "turn" is a slice of `session.messages` starting at a `userText`
//  or `commandReceipt` message and continuing until the next boundary (or end of list).
//  Turns render messenger-style: no chapter header or collapse state, thinking
//  blocks hidden, and the running turn ends with one presence line
//  (design/proposals/messenger-ux-2026-10.md §2).
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
        liveActivitySummary: PickyActivitySummary? = nil
    ) {
        self.id = id
        self.userMessage = userMessage
        self.bodyMessages = bodyMessages
        self.trailingMessages = trailingMessages
        self.isCurrent = isCurrent
        self.isLatest = isLatest
        self.liveActivitySummary = liveActivitySummary
    }

    static let preTurnID = "__picky_pre_turn__"

    var hasUserMessage: Bool { userMessage != nil }

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
                liveActivitySummary: isLatest && latestIsCurrent ? liveActivitySummary : nil
            )
        }
    }
}

/// Current-state latch for a turn. `hasBeenSeenComplete` latches to true the
/// first time `observe(isCurrent:)` sees `isCurrent == false`; once latched the
/// turn stays visually settled even if `group.isCurrent` flips true again. This
/// guards the race where agentd emits `status:running` before the new user_text
/// journal entry on a follow-up submit (see `pushPendingQueueDelivery` in
/// `agentd/src/session-supervisor.ts`). Without the latch the previous turn
/// briefly regains its presence line.
struct PickyTurnLiveStatePolicy: Equatable {
    var hasBeenSeenComplete: Bool = false

    func isVisuallyCurrent(isCurrent: Bool) -> Bool {
        isCurrent && !hasBeenSeenComplete
    }

    mutating func observe(isCurrent: Bool) {
        if !isCurrent { hasBeenSeenComplete = true }
    }
}

/// Bridges short gaps in the live presence line while the turn is still
/// running. The daemon reports the agent as not responding between Pi runs of
/// one turn (queued follow-up delivery, async completion delivery, compaction
/// followed by continue, auto-retry), so the live value drops to nil for a
/// moment. Removing the row then re-adding it shifts the transcript twice.
/// Instead the last line stays on screen for `grace`; a real settle (the turn
/// leaving `isCurrent`) still removes it at once because the card stops asking.
struct PickyPresenceGapHold: Equatable {
    static let grace: TimeInterval = 3

    private(set) var held: PickyConversationPresencePresentation?
    private var heldUntil: Date?

    /// Records the live value at `now` and returns how long until the held
    /// line expires, or nil when nothing is held.
    mutating func update(
        previous: PickyConversationPresencePresentation?,
        live: PickyConversationPresencePresentation?,
        now: Date
    ) -> TimeInterval? {
        if live != nil {
            release()
            return nil
        }
        if held == nil, let previous {
            held = previous
            heldUntil = now.addingTimeInterval(Self.grace)
        }
        guard let heldUntil else { return nil }
        let remaining = heldUntil.timeIntervalSince(now)
        if remaining <= 0 {
            release()
            return nil
        }
        return remaining
    }

    func presented(live: PickyConversationPresencePresentation?) -> PickyConversationPresencePresentation? {
        live ?? held
    }

    mutating func release() {
        held = nil
        heldUntil = nil
    }
}

enum PickyTurnBodyPolicy {
    /// Thinking stays out of the messenger transcript; the presence line says
    /// "thinking" while it happens.
    static func visibleBodyMessages(_ messages: [PickySessionMessage]) -> [PickySessionMessage] {
        messages.filter { $0.kind != .agentThinking }
    }
}

/// One turn rendered as plain chat rows: the request bubble, the visible
/// response rows, and, while the turn is live, the presence line.
struct PickyTurnCardView<MessageContent: View>: View {
    let group: PickyTurnGroup
    /// Presence line for the live turn. Only the active turn passes a value.
    var presence: PickyConversationPresencePresentation? = nil
    /// Tap handler for the presence line, typically opening the session-scoped
    /// tool history viewer.
    var onOpenActiveToolHistory: (() -> Void)? = nil
    @ViewBuilder let messageContent: (PickySessionMessage) -> MessageContent

    @State private var liveState = PickyTurnLiveStatePolicy()
    @State private var gapHold = PickyPresenceGapHold()

    private var presentedPresence: PickyConversationPresencePresentation? {
        liveState.isVisuallyCurrent(isCurrent: group.isCurrent) ? gapHold.presented(live: presence) : nil
    }

    var body: some View {
        let _ = PickyPerf.event("turn_card_body")
        let visibleBody = PickyTurnBodyPolicy.visibleBodyMessages(group.bodyMessages)
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            if let userMessage = group.userMessage {
                messageContent(userMessage)
            }
            // Render the presence line even when there are no body messages so a
            // tool-only running turn still shows live progress below the request.
            if !visibleBody.isEmpty || presentedPresence != nil {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    ForEach(visibleBody, id: \.id) { message in
                        messageContent(message)
                    }
                    if let presentedPresence {
                        PickyConversationPresenceRow(presentation: presentedPresence, onTap: onOpenActiveToolHistory)
                    }
                }
                // Keep the request bubble and the first response row as separate
                // reading blocks. The outer stack already supplies 8pt; this adds 12pt.
                .padding(.top, group.userMessage == nil ? 0 : DS.Spacing.space3)
            }
        }
        .onAppear { liveState.observe(isCurrent: group.isCurrent) }
        .onChange(of: group.isCurrent) { _, isCurrent in
            liveState.observe(isCurrent: isCurrent)
            if !isCurrent { gapHold.release() }
        }
        .onChange(of: presence) { previous, live in
            guard let wait = gapHold.update(previous: previous, live: live, now: Date()) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                _ = gapHold.update(previous: nil, live: presence, now: Date())
            }
        }
    }
}
