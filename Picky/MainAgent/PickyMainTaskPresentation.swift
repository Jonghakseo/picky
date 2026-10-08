//
//  PickyMainTaskPresentation.swift
//  Picky
//
//  Pure projection from the `mainTasksUpdated` snapshot to what the Tasks
//  section renders: which rows appear and in which order, one display state per
//  Task, which controls are offered, and the short status label key.
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

    /// Ordering tier. Rows the user can act on come first, then live work, then
    /// results. Finished rows are the only ones that get trimmed.
    var sortTier: Int {
        switch self {
        case .blocked, .interrupted: 0
        case .queued, .working, .stopping: 1
        case .completed, .failed, .cancelled, .handedOff, .unknown: 2
        }
    }

    var isFinished: Bool { sortTier == 2 }
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
    /// One extra line the status label alone would hide, such as an unconfirmed
    /// cleanup or a Pickle that took the Task over.
    let noteKey: String?

    var id: String { task.id }
}

struct PickyMainDelegationRowModel: Equatable, Identifiable {
    /// What the row asks for, derived from the decision state and its Pickle.
    enum Kind: Equatable {
        /// Waiting for the user. Nothing runs until they choose.
        case pending
        case creatingPickle
        case pickleCreated
        case pickleFailed
    }

    let decision: PickyMainDelegationDecision
    let kind: Kind

    var id: String { decision.id }
    var showsChoices: Bool { kind == .pending }
    /// A failed Pickle creation can be retried, run here as a Task instead, or cancelled.
    var showsRetry: Bool { kind == .pickleFailed }
    var isBusy: Bool { kind == .creatingPickle }

    var messageKey: String {
        switch kind {
        case .pending: "hub.tasks.decision.pending"
        case .creatingPickle: "hub.tasks.decision.creating"
        case .pickleCreated: "hub.tasks.decision.created"
        case .pickleFailed: "hub.tasks.decision.failed"
        }
    }
}

enum PickyMainTaskPresentation {
    /// Finished Tasks are history, not a worklist. Keep the newest few so the
    /// section cannot grow past the transcript it sits under.
    static let finishedTaskLimit = 8

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

    static func rows(for tasks: [PickyMainTask]) -> [PickyMainTaskRowModel] {
        let models = tasks.map { task -> PickyMainTaskRowModel in
            let state = displayState(for: task)
            return PickyMainTaskRowModel(
                task: task,
                state: state,
                showsStop: task.canStop,
                showsResume: task.canResume,
                elapsedSince: state == .working ? task.revisionStartedAt : nil,
                noteKey: noteKey(for: task, state: state)
            )
        }
        let sorted = models.sorted { lhs, rhs in
            if lhs.state.sortTier != rhs.state.sortTier { return lhs.state.sortTier < rhs.state.sortTier }
            if lhs.task.updatedAt != rhs.task.updatedAt { return lhs.task.updatedAt > rhs.task.updatedAt }
            return lhs.task.id < rhs.task.id
        }
        // Live work always shows. Rows that wait on the user and finished history
        // share one cap, so Tasks nobody resumes cannot pile up at the top.
        let live = sorted.filter { $0.state.sortTier == 1 }
        let kept = sorted.filter { $0.state.sortTier != 1 }.prefix(finishedTaskLimit)
        return kept.filter { $0.state.sortTier == 0 } + live + kept.filter { $0.state.sortTier == 2 }
    }

    /// A blocked Task that a Pickle took over needs nothing more from the user:
    /// it reads as finished history, with the handoff note explaining where it went.
    static func displayState(for task: PickyMainTask) -> PickyMainTaskDisplayState {
        if task.status == .blocked, task.handoff?.pickleSessionId != nil { return .handedOff }
        return displayState(for: task.status)
    }

    /// A decision is shown while it still needs the user or still reports its
    /// own progress. A decision already represented by a Task row's handoff is
    /// dropped so the same fact is not stated twice.
    static func delegationRows(
        for decisions: [PickyMainDelegationDecision],
        tasks: [PickyMainTask]
    ) -> [PickyMainDelegationRowModel] {
        let handedOffDecisionIDs = Set(tasks.compactMap { $0.handoff?.decisionId })
        let models = decisions.compactMap { decision -> PickyMainDelegationRowModel? in
            guard let kind = kind(for: decision, handedOffDecisionIDs: handedOffDecisionIDs) else { return nil }
            return PickyMainDelegationRowModel(decision: decision, kind: kind)
        }
        return models.sorted { lhs, rhs in
            if lhs.showsChoices != rhs.showsChoices { return lhs.showsChoices }
            if lhs.decision.updatedAt != rhs.decision.updatedAt { return lhs.decision.updatedAt > rhs.decision.updatedAt }
            return lhs.decision.id < rhs.decision.id
        }
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
        if task.handoff != nil { return "hub.tasks.note.handoff" }
        if state == .interrupted { return "hub.tasks.note.interrupted" }
        if task.report?.escalation == .productionCode { return "hub.tasks.note.productionCode" }
        return nil
    }

    private static func kind(
        for decision: PickyMainDelegationDecision,
        handedOffDecisionIDs: Set<String>
    ) -> PickyMainDelegationRowModel.Kind? {
        switch decision.state {
        case .pending:
            return .pending
        case .pickle:
            switch decision.pickle?.state {
            case .creating: return .creatingPickle
            case .failed: return .pickleFailed
            // The Pickle exists: say so once, and only where no Task row already says it.
            case .created, .unknown, .none: return handedOffDecisionIDs.contains(decision.id) ? nil : .pickleCreated
            }
        // The Task row carries the work from here on; a cancelled decision is done.
        case .task, .cancelled, .unknown:
            return nil
        }
    }
}
