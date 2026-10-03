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
        case let .read(file, range):
            detailText = [file, range]
        case let .bash(command, title):
            detailText = [command, title]
        case let .edit(file, changes):
            detailText = [file] + changes.flatMap { [Optional($0.oldText), Optional($0.newText)] }
        case let .write(file, content):
            detailText = [file, content]
        case let .subagent(mode, agents, task):
            detailText = [mode, task] + agents.map(Optional.some)
        case let .todo(summary, items):
            detailText = [summary] + items.map { $0.text }
        case let .generic(argsJSON):
            detailText = [argsJSON]
        }
        return ([entry.name, entry.result?.text] + detailText).compactMap { $0 }.joined(separator: "\n")
    }
}
