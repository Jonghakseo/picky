import Foundation
import SwiftUI

/// Pure projection of canonical async-task state into the conversation footer.
/// The canonical tasks, tickets and summary stay the lifecycle authority; subagent
/// runs only name an agent and supply its exact timing.
enum PickyBackgroundWorkState: String {
    case running, queued, stopping, completed, failed, cancelled, interrupted, unknown

    /// Unfinished work is named before finished work, and attention before history.
    static let summaryOrder: [PickyBackgroundWorkState] = [
        .running, .queued, .stopping, .completed, .failed, .cancelled, .interrupted, .unknown
    ]

    /// A state that a person still has to act on outranks ordinary progress and
    /// finished work when the footer can name only one of them.
    static let statusFallbackOrder: [PickyBackgroundWorkState] = [
        .stopping, .running, .queued, .unknown, .interrupted, .failed, .cancelled, .completed
    ]

    /// Only the states a finished child list cannot explain by itself.
    var isExceptional: Bool {
        switch self {
        case .failed, .cancelled, .interrupted, .unknown, .stopping: true
        case .running, .queued, .completed: false
        }
    }

    /// Canonical execution keys already encode registration and presence uncertainty.
    init(executionKey: String) {
        switch executionKey {
        case "hud.asyncTasks.execution.running": self = .running
        case "hud.asyncTasks.execution.queued": self = .queued
        case "hud.asyncTasks.execution.cancelling": self = .stopping
        case "hud.asyncTasks.execution.succeeded": self = .completed
        case "hud.asyncTasks.execution.failed": self = .failed
        case "hud.asyncTasks.execution.cancelled": self = .cancelled
        case "hud.asyncTasks.execution.interrupted": self = .interrupted
        default: self = .unknown
        }
    }

    var labelKey: String {
        switch self {
        case .running: "hud.asyncTasks.execution.running.short"
        case .queued: "hud.asyncTasks.execution.queued.short"
        case .stopping: "hud.asyncTasks.execution.cancelling.short"
        case .completed: "hud.asyncTasks.execution.succeeded.short"
        case .failed: "hud.asyncTasks.execution.failed.short"
        case .cancelled: "hud.asyncTasks.execution.cancelled.short"
        case .interrupted: "hud.asyncTasks.execution.interrupted.short"
        case .unknown: "hud.asyncTasks.execution.unknown.short"
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .queued: "clock"
        case .stopping: "stop.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .interrupted, .unknown: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .running: DS.Colors.info
        case .completed: DS.Colors.successText
        case .failed: DS.Colors.destructiveText
        case .interrupted, .unknown: DS.Colors.warningText
        case .queued, .stopping, .cancelled: DS.Colors.textSecondary
        }
    }
}

/// Result delivery is separate from execution: a successful run can still fail
/// to reach the agent, and an unverified ticket is not a confirmed failure.
enum PickyBackgroundWorkResult: String {
    case pending, processing, failed, unverified

    init?(tickets: [PickyCompletionTicket]) {
        if tickets.contains(where: { $0.state == .failed }) { self = .failed }
        else if tickets.contains(where: { $0.state == .unknown }) { self = .unverified }
        else if tickets.contains(where: { $0.state == .processing }) { self = .processing }
        else if tickets.contains(where: { [.pending, .submitted, .observed].contains($0.state) }) { self = .pending }
        else { return nil }
    }

    var labelKey: String {
        switch self {
        case .pending: "hud.asyncTasks.result.pending"
        case .processing: "hud.asyncTasks.result.processing"
        case .failed: "hud.asyncTasks.result.failed"
        case .unverified: "hud.asyncTasks.result.unknown"
        }
    }

    var needsAttention: Bool { self == .failed || self == .unverified }
}

/// Elapsed time is reported only when the provider actually knows it. An
/// `updatedAt` change reflects unrelated lifecycle events, so it is never a clock.
enum PickyBackgroundWorkTiming: Equatable {
    case none
    case elapsed(since: Date)
    case fixed(TimeInterval)
}

struct PickyBackgroundWorkCount: Identifiable, Equatable {
    let state: PickyBackgroundWorkState
    let count: Int
    var id: String { state.rawValue }
}

struct PickyBackgroundWorkRow: Identifiable, Equatable {
    /// Owner + task identity, so a progress update never remounts or reorders the row.
    let id: PickyAsyncTaskShelfIdentity
    let title: String
    let state: PickyBackgroundWorkState
    let timing: PickyBackgroundWorkTiming
}

/// A root and the work that belongs to it. `children` is empty for a standalone
/// command, which renders as a single row instead of a counted group.
struct PickyBackgroundWorkGroup: Identifiable, Equatable {
    let id: PickyAsyncTaskShelfIdentity
    let title: String
    let state: PickyBackgroundWorkState
    let timing: PickyBackgroundWorkTiming
    let children: [PickyBackgroundWorkRow]
    let result: PickyBackgroundWorkResult?

    var isGroup: Bool { !children.isEmpty }

    /// The invocation itself failed, stopped or cannot be verified while its
    /// agents report something else. It is shown on the group line, and it is
    /// never counted as one more agent.
    var rootIssue: PickyBackgroundWorkState? {
        guard isGroup, state.isExceptional,
              !children.contains(where: { $0.state == state }) else { return nil }
        return state
    }

    var counts: [PickyBackgroundWorkCount] {
        PickyBackgroundWorkState.summaryOrder.compactMap { state in
            let count = children.filter { $0.state == state }.count
            return count == 0 ? nil : PickyBackgroundWorkCount(state: state, count: count)
        }
    }
}

struct PickyBackgroundWorkStatus: Equatable {
    let text: String
    let state: PickyBackgroundWorkState
}

struct PickyBackgroundWorkFooterModel: Equatable {
    /// Canonical counts report work the expanded list cannot itemize yet.
    enum Note: String, Equatable {
        case detailUnavailable, attention

        var key: String {
            switch self {
            case .detailUnavailable: "hud.asyncTasks.detailUnavailable"
            case .attention: "hud.asyncTasks.attentionUnknown"
            }
        }
    }

    var groups: [PickyBackgroundWorkGroup]
    var status: PickyBackgroundWorkStatus
    var note: Note?
}

enum PickyBackgroundWorkFooterPresentation {
    private static let subagentKinds: Set<String> = ["subagent", "subagent_group", "subagent-group"]

    /// `runs` is a closure because subagent names are needed only when a
    /// subagent group is actually current; an ordinary command footer must not
    /// start observing the transcript-wide run list.
    static func model(summary: PickyAsyncWorkSummary,
                      detail: PickyProjectionSectionState<PickyAsyncTaskDetail>,
                      runs: () -> [PickySubagentRun],
                      runtimeInstanceId: String?) -> PickyBackgroundWorkFooterModel? {
        guard case .loaded(let value) = detail else {
            // Omitted detail is unavailable, not empty: canonical counts still report work.
            guard let status = canonicalStatus(summary) else { return nil }
            return PickyBackgroundWorkFooterModel(groups: [], status: status, note: .detailUnavailable)
        }
        let roots = PickyAsyncTaskShelfPresentation.roots(in: value).filter { isCurrent($0, in: value) }
        let resolvedRuns = roots.contains { subagentKinds.contains($0.kind) } ? runs() : []
        let groups = roots.map { group($0, in: value, runs: resolvedRuns, summary: summary,
                                      runtimeInstanceId: runtimeInstanceId) }
        let footerNote = note(for: groups, summary: summary)
        let progress = status(for: groups)
        // Canonical attention the groups cannot explain stays in the collapsed
        // summary, even while other work is still running.
        let canonical = footerNote == .attention ? canonicalStatus(summary) : nil
        guard let status = merge(canonical, progress) ?? canonicalStatus(summary) else { return nil }
        return PickyBackgroundWorkFooterModel(groups: groups, status: status, note: footerNote)
    }

    /// A root belongs to the current work only while something of its own is
    /// unfinished or its result is still unresolved. Settled history must not
    /// reappear because unrelated work later needed attention.
    private static func isCurrent(_ root: PickyAsyncTask, in detail: PickyAsyncTaskDetail) -> Bool {
        let members = PickyAsyncTaskShelfPresentation.members(of: root, in: detail)
        if members.contains(where: hasWork) { return true }
        let tickets = PickyAsyncTaskShelfPresentation.tickets(for: root, in: detail)
        return tickets.contains { $0.state != .handled && $0.state != .suppressed }
    }

    private static func hasWork(_ task: PickyAsyncTask) -> Bool {
        task.presence != .settled || [.queued, .running, .cancelling].contains(task.execution)
            || [.reserved, .approved].contains(task.registration)
    }

    private static func group(_ root: PickyAsyncTask, in detail: PickyAsyncTaskDetail,
                              runs: [PickySubagentRun], summary: PickyAsyncWorkSummary,
                              runtimeInstanceId: String?) -> PickyBackgroundWorkGroup {
        let isSubagent = subagentKinds.contains(root.kind)
        let children = PickyAsyncTaskShelfPresentation.members(of: root, in: detail)
            .filter { $0.taskId != root.taskId }
            .map { child -> PickyBackgroundWorkRow in
                let run = isSubagent ? subagentRun(for: child, root: root, runs: runs) : nil
                let name = run?.agent.trimmingCharacters(in: .whitespacesAndNewlines)
                // A subagent child's title carries the delegation instruction, so it is
                // never shown. A missing name degrades to a neutral label, not a hidden row.
                let title = isSubagent
                    ? (name.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.t("hud.backgroundWork.unnamedAgent"))
                    : child.title
                let state = PickyBackgroundWorkState(executionKey: PickyAsyncTaskShelfPresentation.executionKey(
                    child, summary: summary, runtimeInstanceId: runtimeInstanceId))
                return PickyBackgroundWorkRow(id: child.shelfIdentity, title: title, state: state,
                    timing: timing(for: child, run: run, state: state, presence: child.presence))
            }
        let rootState = PickyBackgroundWorkState(executionKey: PickyAsyncTaskShelfPresentation.executionKey(
            root, summary: summary, runtimeInstanceId: runtimeInstanceId))
        return PickyBackgroundWorkGroup(
            id: root.shelfIdentity,
            title: isSubagent ? L10n.t("hud.backgroundWork.subagentGroup") : root.title,
            state: rootState,
            // A group line carries its members' counts, not one more clock, so the
            // invocation's own timing is never parsed just to be discarded.
            timing: children.isEmpty
                ? timing(for: root, run: nil, state: rootState, presence: root.presence) : .none,
            children: children,
            result: PickyBackgroundWorkResult(
                tickets: PickyAsyncTaskShelfPresentation.tickets(for: root, in: detail)))
    }

    /// The run metadata belongs to this invocation only; an older invocation can
    /// reuse the same run identifier.
    private static func subagentRun(for task: PickyAsyncTask, root: PickyAsyncTask,
                                    runs: [PickySubagentRun]) -> PickySubagentRun? {
        guard let invocationID = root.invocationId,
              case .number(let runID)? = task.details?["runId"] else { return nil }
        return runs.first { Double($0.runId) == runID && $0.invocationId == invocationID }
    }

    /// `createdAt` includes reservation and queue wait, so it is not an execution
    /// start. A run without a reported start stays blank rather than inventing one.
    static func timing(for task: PickyAsyncTask, run: PickySubagentRun?,
                       state: PickyBackgroundWorkState,
                       presence: PickyExecutionPresence) -> PickyBackgroundWorkTiming {
        let started = date(task.details?["startedAt"]) ?? run?.startedAt
        if [.running, .stopping].contains(state) && presence == .active {
            // A start in the future or implausibly far in the past is corrupt metadata.
            guard let started, case .fixed = duration(Date().timeIntervalSince(started)) else { return .none }
            return .elapsed(since: started)
        }
        guard [.completed, .failed, .cancelled, .interrupted].contains(state) else { return .none }
        if let milliseconds = number(task.details?["elapsedMs"]) ?? run?.elapsedMs {
            return duration(milliseconds / 1000)
        }
        if let started, let finished = date(task.details?["finishedAt"]), finished >= started {
            return duration(finished.timeIntervalSince(started))
        }
        return .none
    }

    /// Provider metadata is untrusted input. A value that cannot be rendered as a
    /// duration is discarded instead of being clamped into an invented number.
    private static func duration(_ seconds: TimeInterval) -> PickyBackgroundWorkTiming {
        guard seconds.isFinite, seconds >= 0, seconds < maximumReportedDuration else { return .none }
        return .fixed(seconds)
    }

    /// A hundred years of execution is already impossible; beyond it the value is
    /// provider corruption, not a duration.
    private static let maximumReportedDuration: TimeInterval = 100 * 365 * 24 * 3600

    /// Canonical attention that the visible groups do not already explain, plus
    /// the ordinary "counts without detail" case.
    private static func note(for groups: [PickyBackgroundWorkGroup],
                             summary: PickyAsyncWorkSummary) -> PickyBackgroundWorkFooterModel.Note? {
        let (states, results) = reported(in: groups)
        let explainsAttention = states.contains(.failed) || states.contains(.interrupted)
            || states.contains(.unknown) || results.contains(where: \.needsAttention)
        if summary.attentionCount > 0 && !explainsAttention { return .attention }
        if summary.uncertainExecutionCount > 0 && !states.contains(.unknown)
            && !results.contains(.unverified) { return .attention }
        // Ordinary active or pending counts without rows are a detail gap, not a warning.
        return groups.isEmpty ? .detailUnavailable : nil
    }

    private static func merge(_ first: PickyBackgroundWorkStatus?,
                              _ second: PickyBackgroundWorkStatus?) -> PickyBackgroundWorkStatus? {
        guard let first else { return second }
        guard let second, second.text != first.text else { return first }
        return .init(text: "\(first.text) · \(second.text)", state: first.state)
    }

    /// Every state the expanded list shows, including each group's own root state.
    private static func reported(in groups: [PickyBackgroundWorkGroup])
        -> (states: Set<PickyBackgroundWorkState>, results: Set<PickyBackgroundWorkResult>) {
        var states: Set<PickyBackgroundWorkState> = []
        var results: Set<PickyBackgroundWorkResult> = []
        for group in groups {
            states.insert(group.state)
            group.children.forEach { states.insert($0.state) }
            if let result = group.result { results.insert(result) }
        }
        return (states, results)
    }

    /// Up to one attention segment and one progress segment, highest priority first.
    private static func status(for groups: [PickyBackgroundWorkGroup]) -> PickyBackgroundWorkStatus? {
        let (states, results) = reported(in: groups)
        var segments: [PickyBackgroundWorkStatus] = []
        if states.contains(.failed) {
            segments.append(.init(text: L10n.t("hud.backgroundWork.needsAttention"), state: .failed))
        } else if results.contains(.failed) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.result.failed"), state: .failed))
        } else if states.contains(.unknown) {
            segments.append(.init(text: L10n.t("hud.backgroundWork.statusUnknown"), state: .unknown))
        } else if results.contains(.unverified) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.result.unknown"), state: .unknown))
        } else if states.contains(.interrupted) {
            // A person's own stop request is ordinary; an interruption is not.
            segments.append(.init(text: L10n.t("hud.backgroundWork.needsAttention"), state: .interrupted))
        }
        if states.contains(.stopping) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.execution.cancelling.short"), state: .stopping))
        } else if states.contains(.running) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.execution.running.short"), state: .running))
        } else if states.contains(.queued) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.execution.queued.short"), state: .queued))
        } else if results.contains(.processing) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.result.processing"), state: .running))
        } else if results.contains(.pending) {
            segments.append(.init(text: L10n.t("hud.asyncTasks.result.pending"), state: .queued))
        }
        if segments.isEmpty, let remaining = PickyBackgroundWorkState.statusFallbackOrder
            .first(where: states.contains) {
            // Work that is still listed always names its own state, even when it
            // finished or was stopped without needing attention.
            segments.append(.init(text: L10n.t(remaining.labelKey), state: remaining))
        }
        guard let first = segments.first else { return nil }
        return .init(text: segments.map(\.text).joined(separator: " · "), state: first.state)
    }

    /// Counts alone never prove a failure: `attentionCount` also sums uncertain
    /// executions and unverified deliveries. Without detail the footer reports
    /// that the state has to be checked; a red state needs a task that failed.
    private static func canonicalStatus(_ summary: PickyAsyncWorkSummary) -> PickyBackgroundWorkStatus? {
        if summary.uncertainExecutionCount > 0 {
            return .init(text: L10n.t("hud.backgroundWork.statusUnknown"), state: .unknown)
        }
        if summary.attentionCount > 0 {
            return .init(text: L10n.t("hud.backgroundWork.needsAttention"), state: .unknown)
        }
        if summary.activeRootCount > 0 {
            return .init(text: L10n.t("hud.asyncTasks.execution.running.short"), state: .running)
        }
        if summary.pendingCompletionCount > 0 {
            return .init(text: L10n.t("hud.asyncTasks.result.pending"), state: .queued)
        }
        return nil
    }

    static func durationText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < maximumReportedDuration else { return "" }
        let total = Int(interval.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value else { return nil }
        return number
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard case .string(let text)? = value else { return nil }
        return fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()
}
