//
//  PickySubagentInvocationPresentation.swift
//  Picky
//
//  Pure conversation-bubble projection for one subagent tool invocation.
//

import Foundation

struct PickySubagentInvocationRow: Equatable, Identifiable {
    enum Status: Equatable { case pending, running, done, error }

    let id: String
    let planIndex: Int?
    let agent: String
    let task: String
    let run: PickySubagentRun?
    let status: Status

    var runIDText: String? { run.map { "#\($0.runId)" } }
    var displayTask: String { run?.displayTask ?? task }

    /// The complete result is retained only for recent runs, so it controls the
    /// report-viewer affordance independently from the compact row preview.
    var hasResponseText: Bool {
        guard let resultText = run?.resultText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !resultText.isEmpty
    }

    /// Settled runs prioritize their compact response preview over the launch task.
    /// A row remains task-first while running, even if an interim result arrives.
    var displayText: String {
        guard status == .done || status == .error,
              let response = run?.resultPreview ?? run?.resultText,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return displayTask
        }
        return response.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum PickySubagentInvocationExpansionPolicy {
    static func isExpanded(savedValue: Bool?, isComplete: Bool) -> Bool {
        savedValue ?? !isComplete
    }

    static func shouldCollapse(previousIsComplete: Bool?, currentIsComplete: Bool) -> Bool {
        currentIsComplete && previousIsComplete != true
    }
}

struct PickySubagentInvocationPresentation: Equatable {
    enum Tone: Equatable { case running, success, error, pending }

    let invocation: PickySubagentInvocation
    let rows: [PickySubagentInvocationRow]
    let completedCount: Int
    let runningCount: Int
    let pendingCount: Int
    let errorCount: Int
    let totalCount: Int
    let startedAt: Date

    init?(invocation: PickySubagentInvocation?, runs: [PickySubagentRun], createdAt: Date) {
        guard let invocation else { return nil }
        self.invocation = invocation
        let invocationRuns = runs.filter { $0.invocationId == invocation.invocationId }
        self.rows = Self.rows(planned: invocation.planned, runs: invocationRuns, completed: invocation.completed == true)
        self.completedCount = rows.count { $0.status == .done || $0.status == .error }
        self.runningCount = rows.count { $0.status == .running }
        self.pendingCount = rows.count { $0.status == .pending }
        self.errorCount = rows.count { $0.status == .error }
        self.totalCount = rows.count
        self.startedAt = invocationRuns.compactMap(\.startedAt).min() ?? createdAt
    }

    /// The tool completion event is authoritative even when pre-fix history has
    /// no matching run records or a delayed diagnostic still reports running.
    var isComplete: Bool { invocation.completed == true || (runningCount == 0 && pendingCount == 0) }

    var tone: Tone {
        if errorCount > 0 { return .error }
        if runningCount > 0 { return .running }
        if pendingCount > 0 { return .pending }
        return .success
    }

    var headerLabel: String {
        switch invocation.action {
        case .run:
            return L10n.t("hud.subagent.invocation.run")
        case .batch:
            return L10n.t("hud.subagent.invocation.batch", Int64(totalCount))
        case .chain:
            let startedCount = totalCount - pendingCount
            return L10n.t("hud.subagent.invocation.chain", Int64(startedCount), Int64(totalCount))
        }
    }

    var chainAgentsText: String? {
        guard invocation.action == .chain else { return nil }
        return invocation.planned.map(\.agent).joined(separator: " → ")
    }

    var statusText: String {
        guard totalCount > 0 else { return "" }
        if runningCount > 0 {
            return runningCount == 1
                ? L10n.t("hud.subagent.header.one", Int64(completedCount), Int64(totalCount))
                : L10n.t("hud.subagent.header", Int64(runningCount), Int64(completedCount), Int64(totalCount))
        }
        if pendingCount > 0 {
            return L10n.t("hud.subagent.pending", Int64(pendingCount), Int64(completedCount), Int64(totalCount))
        }
        if errorCount > 0 {
            return L10n.t("hud.subagent.pill.failed", Int64(errorCount), Int64(totalCount - errorCount), Int64(totalCount))
        }
        return totalCount == 1
            ? L10n.t("hud.subagent.pill.done.one")
            : L10n.t("hud.subagent.pill.done", Int64(totalCount))
    }

    /// Collapsed headers represent the authoritative invocation completion event,
    /// even if a delayed diagnostic leaves a row in its running state.
    var collapsedTone: Tone {
        guard isComplete else { return tone }
        return errorCount > 0 ? .error : .success
    }

    var collapsedText: String {
        guard isComplete, totalCount > 0 else { return statusText }
        if errorCount > 0 {
            return L10n.t("hud.subagent.pill.failed", Int64(errorCount), Int64(totalCount - errorCount), Int64(totalCount))
        }
        return totalCount == 1
            ? L10n.t("hud.subagent.pill.done.one")
            : L10n.t("hud.subagent.pill.done", Int64(totalCount))
    }

    func elapsedText(now: Date = Date()) -> String {
        if isComplete {
            guard let completedAt = rows.compactMap({ row -> Date? in
                guard let startedAt = row.run?.startedAt,
                      let elapsedMs = row.run?.elapsedMs else { return nil }
                return startedAt.addingTimeInterval(elapsedMs / 1_000)
            }).max() else {
                return ""
            }
            return Self.elapsedText(milliseconds: max(0, completedAt.timeIntervalSince(startedAt) * 1_000))
        }
        return Self.elapsedText(milliseconds: max(0, now.timeIntervalSince(startedAt) * 1_000))
    }

    func elapsedText(for row: PickySubagentInvocationRow, now: Date = Date()) -> String {
        guard let run = row.run else { return "" }
        if let elapsedMs = run.elapsedMs { return Self.elapsedText(milliseconds: elapsedMs) }
        guard run.status == .running, let startedAt = run.startedAt else { return "" }
        return Self.elapsedText(milliseconds: max(0, now.timeIntervalSince(startedAt) * 1_000))
    }

    func activityText(for row: PickySubagentInvocationRow) -> String? {
        guard row.status == .running, let activity = row.run?.lastActivity else { return nil }
        if let lastLine = activity.lastLine?.trimmingCharacters(in: .whitespacesAndNewlines), !lastLine.isEmpty {
            return lastLine.replacingOccurrences(of: #"^→\s*"#, with: "", options: .regularExpression)
        }
        guard let toolName = activity.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty else { return nil }
        return toolName
    }

    func toolCountText(for row: PickySubagentInvocationRow) -> String? {
        guard row.status == .running, let count = row.run?.lastActivity?.toolCallCount else { return nil }
        return "\(count) tools"
    }

    func contextUsage(for row: PickySubagentInvocationRow) -> PickyContextUsage? {
        row.run?.lastActivity?.contextUsage
    }

    private static func rows(
        planned: [PickySubagentInvocationPlan],
        runs: [PickySubagentRun],
        completed: Bool
    ) -> [PickySubagentInvocationRow] {
        var unmatchedRuns = runs.sorted { $0.runId < $1.runId }
        var rows: [PickySubagentInvocationRow] = []
        for (index, plannedRun) in planned.enumerated() {
            let matchedIndex = unmatchedRuns.firstIndex { $0.agent == plannedRun.agent }
            let matchedRun = matchedIndex.map { unmatchedRuns.remove(at: $0) }
            rows.append(PickySubagentInvocationRow(
                id: matchedRun.map { "run-\($0.invocationId ?? "legacy")-\($0.runId)" } ?? "planned-\(index)",
                planIndex: index,
                agent: plannedRun.agent,
                task: plannedRun.task,
                run: matchedRun,
                status: status(for: matchedRun, completed: completed)
            ))
        }
        rows.append(contentsOf: unmatchedRuns.map { run in
            PickySubagentInvocationRow(
                id: "run-\(run.invocationId ?? "legacy")-\(run.runId)",
                planIndex: nil,
                agent: run.agent,
                task: run.task,
                run: run,
                status: status(for: run, completed: false)
            )
        })
        return rows
    }

    private static func status(for run: PickySubagentRun?, completed: Bool) -> PickySubagentInvocationRow.Status {
        guard let run else { return completed ? .error : .pending }
        switch run.status {
        case .running: return .running
        case .done: return .done
        case .error: return .error
        }
    }

    private static func elapsedText(milliseconds: Double) -> String {
        let seconds = Int(milliseconds / 1_000)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
