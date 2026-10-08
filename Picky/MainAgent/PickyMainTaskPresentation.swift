//
//  PickyMainTaskPresentation.swift
//  Picky
//
//  Pure projection from the `mainTasksUpdated` snapshot to the blocks the main
//  conversation shows on every surface (Hub Recent Conversation, Quick Input):
//  which Tasks and delegation questions appear, where they sit among the
//  messages, one display state per Task, which controls are offered, and the
//  short label keys. The phone room applies the same placement rule in
//  `agentd/web/src/room/policy/main-tasks.ts`.
//
//  No SwiftUI and no daemon access. The daemon decides what a Task may do
//  (`canStop` / `canResume`); this file never infers a control from a status.
//

import Foundation

/// Ten wire statuses collapse to the states a user has to tell apart.
/// `evaluating`, `running`, and `waiting` are all "working": a waiting Task is
/// waiting on its own background job, not on the user.
enum PickyMainTaskDisplayState: Equatable {
    case queued
    case working
    case stopping
    case completed
    case failed
    case blocked
    /// Blocked on production code work and taken over by a Pickle.
    case handedOff
    case cancelled
    case interrupted
    case unknown

    var labelKey: String {
        switch self {
        case .queued: "hub.tasks.status.queued"
        case .working: "hub.tasks.status.working"
        case .stopping: "hub.tasks.status.stopping"
        case .completed: "hub.tasks.status.completed"
        case .failed: "hub.tasks.status.failed"
        case .blocked: "hub.tasks.status.blocked"
        case .handedOff: "hub.tasks.status.handedOff"
        case .cancelled: "hub.tasks.status.cancelled"
        case .interrupted: "hub.tasks.status.interrupted"
        case .unknown: "hub.tasks.status.unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .working: "gearshape.2"
        case .stopping: "stop.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .blocked: "hand.raised.fill"
        case .handedOff: "arrow.turn.up.right"
        case .cancelled: "stop.circle.fill"
        case .interrupted: "pause.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: PickyMainTaskTone {
        switch self {
        case .queued, .cancelled, .handedOff, .unknown: .neutral
        case .working, .stopping: .active
        case .completed: .success
        case .blocked, .interrupted: .warning
        case .failed: .danger
        }
    }

    /// Still holding a worker. Such a block stays in the conversation even when
    /// the messages around its start have left the transcript.
    var isLive: Bool {
        switch self {
        case .queued, .working, .stopping: true
        case .completed, .failed, .blocked, .handedOff, .cancelled, .interrupted, .unknown: false
        }
    }
}

enum PickyMainTaskTone: Equatable {
    case neutral, active, success, warning, danger
}

struct PickyMainTaskRowModel: Equatable, Identifiable {
    let task: PickyMainTask
    let state: PickyMainTaskDisplayState
    let showsStop: Bool
    let showsResume: Bool
    /// Anchor for the elapsed clock while the Task is working; nil otherwise.
    let elapsedSince: Date?
    /// One extra line under the title that the status label alone would hide,
    /// such as an unconfirmed cleanup or why the Task stopped.
    let noteKey: String?
    /// Leads the details: a handed-off Task's status already says where the work
    /// went, and the answered question is its own line in the conversation.
    let detailNoteKey: String?

    var id: String { task.id }
}

/// What the user chose for a delegation question.
enum PickyMainDelegationOutcome: Equatable {
    case handedToPickle(sessionID: String?)
    case keptWithPicky
    case cancelled

    var labelKey: String {
        switch self {
        case .handedToPickle: "hub.tasks.decision.record.pickle"
        case .keptWithPicky: "hub.tasks.decision.record.task"
        case .cancelled: "hub.tasks.decision.record.cancelled"
        }
    }
}

struct PickyMainDelegationRowModel: Equatable, Identifiable {
    /// What the question still asks for, derived from the decision state and its Pickle.
    enum Kind: Equatable {
        /// Waiting for the user. Nothing runs until they choose.
        case pending
        case creatingPickle
        case pickleFailed
        /// Answered. It stays in the conversation as one line, so the
        /// conversation keeps what was decided.
        case answered(PickyMainDelegationOutcome)
    }

    let decision: PickyMainDelegationDecision
    let kind: Kind

    var id: String { decision.id }
    var showsChoices: Bool { kind == .pending }
    /// A failed Pickle creation can be retried, kept with Picky instead, or cancelled.
    var showsRetry: Bool { kind == .pickleFailed }
    var isBusy: Bool { kind == .creatingPickle }

    var outcome: PickyMainDelegationOutcome? {
        if case .answered(let outcome) = kind { return outcome }
        return nil
    }

    var isRecord: Bool { outcome != nil }

    /// The Pickle an answered question created, for "Open Pickle".
    var pickleSessionID: String? {
        if case .handedToPickle(let sessionID) = outcome { return sessionID }
        return nil
    }

    /// The state line of an open question, or the outcome of an answered one.
    var messageKey: String {
        switch kind {
        case .pending: "hub.tasks.decision.pending"
        case .creatingPickle: "hub.tasks.decision.creating"
        case .pickleFailed: "hub.tasks.decision.failed"
        case .answered(let outcome): outcome.labelKey
        }
    }
}

/// One entry of the main conversation: a message, or a block for a Task or a
/// delegation question.
enum PickyMainConversationTimelineItem: Equatable, Identifiable {
    case message(PickyMainAgentMessage)
    case task(PickyMainTaskRowModel)
    case decision(PickyMainDelegationRowModel)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id)"
        case .task(let row): "task-\(row.id)"
        case .decision(let row): "decision-\(row.id)"
        }
    }

    /// When the entry started. A block keeps this place while its state changes.
    var anchor: Date {
        switch self {
        case .message(let message): message.createdAt
        case .task(let row): row.task.createdAt
        case .decision(let row): row.decision.createdAt
        }
    }

    /// Work still running, or a question still waiting on the user.
    var isOpen: Bool {
        switch self {
        case .message: false
        case .task(let row): row.state.isLive
        case .decision(let row): !row.isRecord
        }
    }

    var isUserMessage: Bool {
        if case .message(let message) = self { return message.role == .user }
        return false
    }

    /// A delegation question the user can still answer, retry, or watch being carried out.
    var isOpenDecision: Bool {
        if case .decision(let row) = self { return !row.isRecord }
        return false
    }
}

enum PickyMainTaskPresentation {
    static func displayState(for status: PickyMainTaskStatus) -> PickyMainTaskDisplayState {
        switch status {
        case .queued: .queued
        case .evaluating, .running, .waiting: .working
        case .stopping: .stopping
        case .completed: .completed
        case .failed: .failed
        case .blocked: .blocked
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        case .unknown: .unknown
        }
    }

    /// One row model per Task, in the order given.
    static func rows(for tasks: [PickyMainTask]) -> [PickyMainTaskRowModel] {
        tasks.map { task in
            let state = displayState(for: task)
            return PickyMainTaskRowModel(
                task: task,
                state: state,
                showsStop: task.canStop,
                showsResume: task.canResume,
                elapsedSince: state == .working ? task.revisionStartedAt : nil,
                noteKey: noteKey(for: task, state: state),
                detailNoteKey: task.handoff == nil ? nil : "hub.tasks.note.handoff"
            )
        }
    }

    /// A blocked Task that a Pickle took over needs nothing more from the user:
    /// it reads as finished history, with the handoff note explaining where it went.
    static func displayState(for task: PickyMainTask) -> PickyMainTaskDisplayState {
        if task.status == .blocked, task.handoff?.pickleSessionId != nil { return .handedOff }
        return displayState(for: task.status)
    }

    /// One row model per decision the app knows, in the order given. Answered
    /// questions become records instead of disappearing.
    static func delegationRows(for decisions: [PickyMainDelegationDecision]) -> [PickyMainDelegationRowModel] {
        decisions.compactMap { decision -> PickyMainDelegationRowModel? in
            guard let kind = kind(for: decision) else { return nil }
            return PickyMainDelegationRowModel(decision: decision, kind: kind)
        }
    }

    /// The main conversation with each Task and delegation question placed in
    /// the turn it started in (see `slot(for:in:)`). Messages keep their
    /// transcript order. A block older than the oldest message the transcript
    /// still holds leaves with those messages unless it is still open, and an
    /// empty transcript (a new conversation) shows only open blocks.
    static func timelineItems(
        messages: [PickyMainAgentMessage],
        snapshot: PickyMainTasksSnapshot
    ) -> [PickyMainConversationTimelineItem] {
        let windowStart = messages.first?.createdAt
        let taskBlocks: [PickyMainConversationTimelineItem] = rows(for: snapshot.tasks).map { .task($0) }
        let decisionBlocks: [PickyMainConversationTimelineItem] = delegationRows(for: snapshot.decisions).map { .decision($0) }
        let blocks = (taskBlocks + decisionBlocks)
            .filter { (block: PickyMainConversationTimelineItem) -> Bool in
                guard let windowStart else { return block.isOpen }
                return block.anchor >= windowStart || block.isOpen
            }
            .sorted { (lhs: PickyMainConversationTimelineItem, rhs: PickyMainConversationTimelineItem) -> Bool in
                if lhs.anchor != rhs.anchor { return lhs.anchor < rhs.anchor }
                return lhs.id < rhs.id
            }

        var blocksBySlot: [Int: [PickyMainConversationTimelineItem]] = [:]
        for block in blocks {
            blocksBySlot[slot(for: block.anchor, in: messages), default: []].append(block)
        }
        var items: [PickyMainConversationTimelineItem] = []
        items.reserveCapacity(messages.count + blocks.count)
        for (index, message) in messages.enumerated() {
            items.append(contentsOf: blocksBySlot[index] ?? [])
            items.append(.message(message))
        }
        items.append(contentsOf: blocksBySlot[messages.count] ?? [])
        return items
    }

    /// The index of the message a block that started at `anchor` goes before,
    /// or `messages.count` for the end.
    ///
    /// The block belongs to the turn it started in: the messages after the last
    /// user message sent at or before it, up to the next user message. Inside
    /// that turn it follows what Picky said last before it started (a sentence
    /// Picky writes before calling a tool is recorded first), or else Picky's
    /// first reply after it, which is the sentence announcing the work. With no
    /// reply in the turn it closes the turn. A block older than every message
    /// opens the list.
    static func slot(for anchor: Date, in messages: [PickyMainAgentMessage]) -> Int {
        guard let first = messages.first, anchor >= first.createdAt else { return 0 }
        let turnStart = messages.lastIndex { $0.role == .user && $0.createdAt <= anchor }.map { $0 + 1 } ?? 0
        let turnEnd = messages[turnStart...].firstIndex { $0.role == .user } ?? messages.count
        let replies = messages[turnStart..<turnEnd]
        if let said = replies.lastIndex(where: { $0.createdAt <= anchor }) { return said + 1 }
        if let announced = replies.firstIndex(where: { $0.createdAt > anchor }) { return announced + 1 }
        return turnEnd
    }

    /// `m:ss` under an hour, `h:mm:ss` above it. Digits only, so it needs no
    /// translation, and it is recomputed from a clock the view ticks slowly.
    static func elapsedText(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private static func noteKey(for task: PickyMainTask, state: PickyMainTaskDisplayState) -> String? {
        if state == .cancelled, task.cleanup == .uncertain { return "hub.tasks.note.cleanupUncertain" }
        // Taken over by a Pickle: the status says so and the details explain it.
        if task.handoff != nil { return nil }
        if state == .interrupted { return "hub.tasks.note.interrupted" }
        if task.report?.escalation == .productionCode { return "hub.tasks.note.productionCode" }
        return nil
    }

    private static func kind(for decision: PickyMainDelegationDecision) -> PickyMainDelegationRowModel.Kind? {
        switch decision.state {
        case .pending:
            return .pending
        case .pickle:
            switch decision.pickle?.state {
            case .creating: return .creatingPickle
            case .failed: return .pickleFailed
            case .created, .unknown, .none: return .answered(.handedToPickle(sessionID: decision.pickle?.sessionId))
            }
        case .task:
            return .answered(.keptWithPicky)
        case .cancelled:
            return .answered(.cancelled)
        // A state from a newer daemon: nothing trustworthy to say about it.
        case .unknown:
            return nil
        }
    }
}
