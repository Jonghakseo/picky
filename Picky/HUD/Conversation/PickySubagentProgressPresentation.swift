//
//  PickySubagentProgressPresentation.swift
//  Picky
//
//  Pure HUD projection for the subagent extension's daemon-authored run state.
//

import Foundation

struct PickySubagentProgressGroup: Equatable, Identifiable {
    let id: String
    let label: String?
    let runs: [PickySubagentRun]
}

enum PickySubagentProgressExpansionPolicy {
    static func isExpanded(savedValue: Bool?, isComplete: Bool) -> Bool {
        savedValue ?? !isComplete
    }

    static func shouldCollapse(previousIsComplete: Bool?, currentIsComplete: Bool) -> Bool {
        currentIsComplete && previousIsComplete != true
    }
}

struct PickySubagentProgressPresentation: Equatable {
    enum Tone: Equatable { case running, success, error }

    let runs: [PickySubagentRun]
    let completedCount: Int
    let runningCount: Int
    let errorCount: Int
    let totalCount: Int
    let fraction: Double
    let tone: Tone
    let groups: [PickySubagentProgressGroup]

    init?(runs: [PickySubagentRun]) {
        guard !runs.isEmpty else { return nil }
        let ordered = runs.sorted { $0.runId < $1.runId }
        self.runs = ordered
        self.completedCount = ordered.count { $0.status != .running }
        self.runningCount = ordered.count { $0.status == .running }
        self.errorCount = ordered.count { $0.status == .error }
        self.totalCount = ordered.count
        self.fraction = Double(completedCount) / Double(totalCount)
        self.tone = ordered.contains(where: { $0.status == .error }) ? .error : (runningCount > 0 ? .running : .success)
        self.groups = Self.groups(for: ordered)
    }

    var isComplete: Bool { runningCount == 0 }

    /// Collapsed pill copy is state-first: live runs show the running count,
    /// settled sets lead with the outcome (done vs failed) so the pill remains
    /// meaningful after the progress ring stops moving.
    var pillText: String {
        if runningCount > 0 {
            return runningCount == 1
                ? L10n.t("hud.subagent.pill.one", Int64(completedCount), Int64(totalCount))
                : L10n.t("hud.subagent.pill", Int64(runningCount), Int64(completedCount), Int64(totalCount))
        }
        if errorCount > 0 {
            return L10n.t("hud.subagent.pill.failed", Int64(errorCount), Int64(totalCount - errorCount), Int64(totalCount))
        }
        return totalCount == 1
            ? L10n.t("hud.subagent.pill.done.one")
            : L10n.t("hud.subagent.pill.done", Int64(totalCount))
    }

    var headerText: String {
        guard runningCount > 0 else { return pillText }
        return runningCount == 1
            ? L10n.t("hud.subagent.header.one", Int64(completedCount), Int64(totalCount))
            : L10n.t("hud.subagent.header", Int64(runningCount), Int64(completedCount), Int64(totalCount))
    }

    func elapsedText(for run: PickySubagentRun, now: Date = Date()) -> String {
        let milliseconds: Double
        if let elapsedMs = run.elapsedMs {
            milliseconds = elapsedMs
        } else if run.status == .running, let startedAt = run.startedAt {
            milliseconds = max(0, now.timeIntervalSince(startedAt) * 1_000)
        } else {
            return ""
        }
        let seconds = Int(milliseconds / 1_000)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private static func groups(for runs: [PickySubagentRun]) -> [PickySubagentProgressGroup] {
        let singles = runs.filter { $0.batchId == nil && $0.pipelineId == nil }
        var grouped = [PickySubagentProgressGroup]()
        if !singles.isEmpty { grouped.append(.init(id: "singles", label: nil, runs: singles)) }
        let buckets = Dictionary(grouping: runs.filter { $0.batchId != nil || $0.pipelineId != nil }) {
            $0.pipelineId.map { "pipeline:\($0)" } ?? "batch:\($0.batchId!)"
        }
        for key in buckets.keys.sorted() {
            guard let groupedRuns = buckets[key] else { continue }
            let kind = key.hasPrefix("pipeline:") ? "pipeline" : "batch"
            let unit = groupedRuns.count == 1 ? "run" : "runs"
            grouped.append(.init(id: key, label: "\(kind) · \(groupedRuns.count) \(unit)", runs: groupedRuns.sorted { $0.runId < $1.runId }))
        }
        return grouped
    }
}
