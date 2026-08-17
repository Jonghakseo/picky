//
//  PickyToolHistoryFilterPolicy.swift
//  Picky
//
//  Pure filtering rules for the tool history viewer.
//

import Foundation

struct PickyToolHistoryFilterResult: Equatable {
    let entries: [PickyToolHistoryEntry]
    let totalCount: Int

    var visibleCount: Int { entries.count }
}

enum PickyToolHistoryActivityFilter: CaseIterable, Equatable, Identifiable {
    case all
    case files
    case commands
    case agents
    case failures

    var id: Self { self }
}

enum PickyToolHistoryFilterPolicy {
    static func filter(
        entries: [PickyToolHistoryEntry],
        selectedCategories: Set<PickyToolHistoryCategory> = [],
        failuresOnly: Bool = false,
        query: String = ""
    ) -> [PickyToolHistoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesCategory = selectedCategories.isEmpty || selectedCategories.contains(entry.category)
            let matchesFailure = !failuresOnly || entry.status == .failed
            let matchesQuery = normalizedQuery.isEmpty || searchableText(for: entry)
                .localizedCaseInsensitiveContains(normalizedQuery)
            return matchesCategory && matchesFailure && matchesQuery
        }
    }

    static func activityEntries(
        from entries: [PickyToolHistoryEntry],
        filter selectedFilter: PickyToolHistoryActivityFilter
    ) -> [PickyToolHistoryEntry] {
        switch selectedFilter {
        case .all:
            entries
        case .files:
            filter(entries: entries, selectedCategories: [.edit, .write])
        case .commands:
            filter(entries: entries, selectedCategories: [.bash])
        case .agents:
            entries.filter(\.isAgentActivity)
        case .failures:
            filter(entries: entries, failuresOnly: true)
        }
    }

    static func result(
        entries: [PickyToolHistoryEntry],
        selectedCategories: Set<PickyToolHistoryCategory> = [],
        failuresOnly: Bool = false,
        query: String = ""
    ) -> PickyToolHistoryFilterResult {
        PickyToolHistoryFilterResult(
            entries: filter(
                entries: entries,
                selectedCategories: selectedCategories,
                failuresOnly: failuresOnly,
                query: query
            ),
            totalCount: entries.count
        )
    }

    static func searchableText(for entry: PickyToolHistoryEntry) -> String {
        let detailText: [String?]
        switch entry.detail {
        case let .read(file, range, resultSummary):
            detailText = [file, range, resultSummary]
        case let .bash(command, title, output):
            detailText = [command, title, output]
        case let .edit(file, changes):
            detailText = [file] + changes.flatMap { [Optional($0.oldText), Optional($0.newText)] }
        case let .write(file, content):
            detailText = [file, content]
        case let .subagent(mode, agents, task, result):
            detailText = [mode, task, result] + agents.map(Optional.some)
        case let .todo(summary, items):
            detailText = [summary] + items.map { $0.text }
        case let .generic(argsJSON, result):
            detailText = [argsJSON, result]
        }
        return ([entry.name] + detailText.compactMap { $0 }).joined(separator: "\n")
    }
}
