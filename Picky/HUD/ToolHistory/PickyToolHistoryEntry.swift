//
//  PickyToolHistoryEntry.swift
//  Picky
//
//  Pure Swift conversion from PickyToolActivity into a structured entry the
//  Tool History viewer can render. Kept free of SwiftUI so it stays testable.
//

import Foundation

enum PickyToolHistoryCategory: String, Equatable, Hashable {
    case read, bash, edit, write, other
}

enum PickyToolHistoryStatus: String, Equatable {
    case running, succeeded, failed
}

struct PickyToolHistoryEditChange: Equatable {
    let oldText: String
    let newText: String
}

enum PickyToolHistoryTodoMarker: Equatable {
    case done, active, pending, added, removed
}

struct PickyToolHistoryTodoItem: Equatable {
    let marker: PickyToolHistoryTodoMarker
    let text: String
}

enum PickyToolHistoryDetail: Equatable {
    case read(file: String?, range: String?)
    case bash(command: String?, title: String?)
    case edit(file: String?, changes: [PickyToolHistoryEditChange])
    case write(file: String?, content: String?)
    case subagent(mode: String, agents: [String], task: String?)
    case todo(summary: String, items: [PickyToolHistoryTodoItem])
    case generic(argsJSON: String?)
}

enum PickyToolHistoryDisplayCategory: Equatable {
    case standard(PickyToolHistoryCategory)
    case agent
    case todo
}

struct PickyToolHistoryEntry: Identifiable, Equatable {
    let id: String
    let index: Int
    let name: String
    let category: PickyToolHistoryCategory
    let status: PickyToolHistoryStatus
    let durationMs: Int?
    let startedAt: Date?
    let detail: PickyToolHistoryDetail
    let result: PickyToolHistoryResult?

    init(
        id: String,
        index: Int,
        name: String,
        category: PickyToolHistoryCategory,
        status: PickyToolHistoryStatus,
        durationMs: Int?,
        startedAt: Date?,
        detail: PickyToolHistoryDetail,
        result: PickyToolHistoryResult? = nil
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.category = category
        self.status = status
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.detail = detail
        self.result = result
    }
}

enum PickyToolHistoryScope: Equatable {
    case session
    case dateRange(start: Date?, end: Date?)

    var isWholeSession: Bool { self == .session }
}

enum PickyToolHistoryRenderer {
    static func entries(from tools: [PickyToolActivity], scope: PickyToolHistoryScope = .session) -> [PickyToolHistoryEntry] {
        let filtered = tools.filter { matches(scope: scope, tool: $0) }
        return filtered.enumerated().map { index, tool in entry(from: tool, index: index + 1) }
    }

    static func matches(scope: PickyToolHistoryScope, tool: PickyToolActivity) -> Bool {
        switch scope {
        case .session:
            return true
        case let .dateRange(start, end):
            // Tools without a startedAt are shown only when the scope is fully open
            // because we cannot decide which turn they belong to.
            guard let started = tool.startedAt else { return start == nil && end == nil }
            if let start, started < start { return false }
            if let end, started >= end { return false }
            return true
        }
    }

    static func entry(from tool: PickyToolActivity, index: Int) -> PickyToolHistoryEntry {
        let category = category(for: tool.name)
        let status = status(for: tool.status)
        let argsJSON = tool.argsPreview
        let resultText = tool.resultPreview ?? (status != .running ? tool.preview : nil)
        let detail = detail(
            for: tool.name,
            category: category,
            argsJSON: argsJSON,
            subagentSummary: tool.subagentSummary
        )
        let result = resultText.map {
            PickyToolHistoryResult(
                text: $0,
                jsonText: tool.resultJSONPreview,
                isTruncated: tool.resultPreviewTruncated == true,
                isRepaired: tool.resultPreviewRepaired == true
            )
        }
        return PickyToolHistoryEntry(
            id: tool.toolCallId,
            index: index,
            name: tool.name,
            category: category,
            status: status,
            durationMs: durationMs(start: tool.startedAt, end: tool.endedAt),
            startedAt: tool.startedAt,
            detail: detail,
            result: result
        )
    }

    static func category(for name: String) -> PickyToolHistoryCategory {
        switch name.lowercased() {
        case "read": return .read
        case "bash": return .bash
        case "edit", "multiedit": return .edit
        case "write": return .write
        default: return .other
        }
    }

    private static func status(for raw: String) -> PickyToolHistoryStatus {
        switch raw {
        case "succeeded": return .succeeded
        case "failed", "error": return .failed
        default: return .running
        }
    }

    private static func durationMs(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let value = end.timeIntervalSince(start) * 1000
        guard value.isFinite, value >= 0 else { return nil }
        return Int(value.rounded())
    }

    static func displayCategory(for detail: PickyToolHistoryDetail) -> PickyToolHistoryDisplayCategory {
        switch detail {
        case .subagent:
            return .agent
        case .todo:
            return .todo
        default:
            return .standard(category(for: detail))
        }
    }

    private static func category(for detail: PickyToolHistoryDetail) -> PickyToolHistoryCategory {
        switch detail {
        case .read: return .read
        case .bash: return .bash
        case .edit: return .edit
        case .write: return .write
        case .subagent, .todo, .generic: return .other
        }
    }

    private static func detail(
        for name: String,
        category: PickyToolHistoryCategory,
        argsJSON: String?,
        subagentSummary: PickySubagentToolSummary?
    ) -> PickyToolHistoryDetail {
        let args = parseArgs(argsJSON)
        switch name.lowercased() {
        case "subagent":
            if let detail = subagentDetail(summary: subagentSummary) { return detail }
            if let detail = subagentDetail(args: args, fallbackJSON: argsJSON) { return detail }
        case "todo_write", "todowrite":
            if let detail = todoDetail(args: args) { return detail }
        default:
            break
        }

        switch category {
        case .read:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"], fallbackJSON: argsJSON)
            return .read(file: file, range: readRange(args))
        case .bash:
            let command = stringValue(args, keys: ["command", "cmd", "script"], fallbackJSON: argsJSON)
            let title = stringValue(args, keys: ["title"], fallbackJSON: argsJSON)
            return .bash(command: command, title: title)
        case .edit:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"], fallbackJSON: argsJSON)
            return .edit(file: file, changes: editChanges(args, fallbackJSON: argsJSON))
        case .write:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"], fallbackJSON: argsJSON)
            let content = stringValue(args, keys: ["content", "text", "body"], fallbackJSON: argsJSON)
            return .write(file: file, content: content)
        case .other:
            return .generic(argsJSON: prettyJSON(argsJSON) ?? argsJSON)
        }
    }

    static func parseArgs(_ json: String?) -> [String: Any] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        let object = try? JSONSerialization.jsonObject(with: data, options: [])
        return (object as? [String: Any]) ?? [:]
    }

    /// Recovers a string value from possibly truncated JSON like `{"command":"long command...`.
    /// Falls back to a regex-based scrape so a 500-char preview that cuts mid-string still
    /// surfaces the readable head of the value instead of nothing.
    static func recoverStringValue(from json: String?, key: String) -> String? {
        guard let json else { return nil }
        let pattern = #"\"\#(NSRegularExpression.escapedPattern(for: key))\"\s*:\s*\"((?:\\.|[^\"])*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: json) else { return nil }
        let raw = String(json[range])
        let unescaped = unescapeJSONStringFragment(raw)
        return unescaped.isEmpty ? nil : unescaped
    }

    private static func unescapeJSONStringFragment(_ raw: String) -> String {
        var output = ""
        var isEscaping = false
        for character in raw {
            if isEscaping {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                default: output.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                output.append(character)
            }
        }
        if isEscaping { output.append("\\") }
        return output
    }

    static func inlineSummary(for detail: PickyToolHistoryDetail) -> String? {
        switch detail {
        case let .subagent(mode, agents, task):
            let action = mode.split(separator: "·", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? mode
            switch action {
            case "run", "continue":
                guard let agent = agents.first, let task else { return mode }
                return "\(action) \(agent) · \(firstLine(task))"
            case "batch":
                return "batch ×\(agents.count) (\(agentList(agents)))"
            case "chain":
                return "chain ×\(agents.count) (\(agents.joined(separator: " → ")))"
            default:
                return mode
            }
        case let .todo(summary, items):
            if summary.hasPrefix("replace") {
                let count = items.count
                if let active = items.first(where: { $0.marker == .active }) {
                    return "\(count) tasks · → \(active.text)"
                }
                return "\(count) tasks"
            }
            let counts = Dictionary(grouping: items, by: \.marker).mapValues(\.count)
            let parts = [
                counts[.done].map { "✓ \($0) done" },
                counts[.active].map { "→ \($0) started" },
                counts[.added].map { "+ \($0)" },
                counts[.removed].map { "− \($0)" },
            ].compactMap { $0 }
            return parts.isEmpty ? summary : parts.joined(separator: " · ")
        default:
            return nil
        }
    }

    private static func subagentDetail(
        summary: PickySubagentToolSummary?
    ) -> PickyToolHistoryDetail? {
        guard let summary,
              summary.action == "batch" || summary.action == "chain",
              !summary.agents.isEmpty,
              summary.agents.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
        return .subagent(mode: summary.action, agents: summary.agents, task: nil)
    }

    private static func subagentDetail(args: [String: Any], fallbackJSON: String?) -> PickyToolHistoryDetail? {
        guard let command = stringValue(args, keys: ["command"], fallbackJSON: fallbackJSON) else { return nil }
        let tokens = shellTokens(command)
        guard tokens.first?.value == "subagent", let action = tokens.dropFirst().first?.value else { return nil }

        if action == "run" || action == "continue" {
            guard tokens.count >= 4,
                  let delimiter = tokens.dropFirst(3).firstIndex(where: { $0.value == "--" }),
                  delimiter + 1 < tokens.count
            else { return nil }
            let agent = tokens[2].value
            let task = tokens[(delimiter + 1)...].map(\.value).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agent.isEmpty, !task.isEmpty else { return nil }
            let flags = tokens[3..<delimiter].map(\.value).filter { $0.hasPrefix("--") }
            let mode = ([action] + flags).joined(separator: " · ")
            return .subagent(mode: mode, agents: [agent], task: task)
        }

        if action == "batch" || action == "chain" {
            var agents: [String] = []
            var currentAgent: String?
            var index = 2
            while index < tokens.count {
                switch tokens[index].value {
                case "--agent":
                    guard index + 1 < tokens.count else { return nil }
                    currentAgent = tokens[index + 1].value
                    index += 2
                case "--task":
                    guard let agent = currentAgent, index + 1 < tokens.count, !tokens[index + 1].value.isEmpty else { return nil }
                    agents.append(agent)
                    currentAgent = nil
                    index += 2
                default:
                    index += 1
                }
            }
            guard !agents.isEmpty else { return nil }
            return .subagent(mode: action, agents: agents, task: nil)
        }

        let controlActions = Set(["status", "detail", "list", "abort"])
        guard controlActions.contains(action) else { return nil }
        let suffix = tokens.dropFirst(2).map(\.value).joined(separator: " ")
        return .subagent(mode: suffix.isEmpty ? action : "\(action) \(suffix)", agents: [], task: nil)
    }

    private static func todoDetail(args: [String: Any]) -> PickyToolHistoryDetail? {
        if let todos = args["todos"] as? [[String: Any]] {
            let items = todos.compactMap(todoReplacementItem)
            guard items.count == todos.count else { return nil }
            return .todo(summary: "replace · \(items.count) tasks", items: items)
        }

        guard args["op"] as? String == "patch" else { return nil }
        let set = args["set"] as? [[String: Any]] ?? []
        let add = args["add"] as? [[String: Any]] ?? []
        let remove = args["remove"] as? [String] ?? []
        guard !set.isEmpty || !add.isEmpty || !remove.isEmpty else { return nil }

        let setItems = set.compactMap(todoPatchSetItem)
        let addItems = add.compactMap(todoAddedItem)
        guard setItems.count == set.count, addItems.count == add.count,
              remove.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }

        var summaryParts: [String] = []
        if !set.isEmpty { summaryParts.append("\(set.count) set") }
        if !add.isEmpty { summaryParts.append("\(add.count) add") }
        if !remove.isEmpty { summaryParts.append("\(remove.count) remove") }
        return .todo(
            summary: "patch · \(summaryParts.joined(separator: ", "))",
            items: setItems + addItems + remove.map { .init(marker: .removed, text: $0) }
        )
    }

    private static func todoReplacementItem(_ raw: [String: Any]) -> PickyToolHistoryTodoItem? {
        guard let content = nonEmptyString(raw["content"]), let marker = todoMarker(status: raw["status"] as? String) else { return nil }
        return .init(marker: marker, text: content)
    }

    private static func todoPatchSetItem(_ raw: [String: Any]) -> PickyToolHistoryTodoItem? {
        guard let status = raw["status"] as? String, let marker = todoMarker(status: status) else { return nil }
        let identity = nonEmptyString(raw["content"]) ?? nonEmptyString(raw["id"])
        guard let identity else { return nil }
        return .init(marker: marker, text: "\(identity) → \(status)")
    }

    private static func todoAddedItem(_ raw: [String: Any]) -> PickyToolHistoryTodoItem? {
        guard let content = nonEmptyString(raw["content"]) else { return nil }
        return .init(marker: .added, text: content)
    }

    private static func todoMarker(status: String?) -> PickyToolHistoryTodoMarker? {
        switch status {
        case "completed": return .done
        case "in_progress": return .active
        case "pending": return .pending
        default: return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func agentList(_ agents: [String]) -> String {
        let unique = agents.reduce(into: [String]()) { result, agent in
            if !result.contains(agent) { result.append(agent) }
        }
        return unique.prefix(2).joined(separator: ", ") + (unique.count > 2 ? ", …" : "")
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private struct ShellToken {
        let value: String
    }

    private static func shellTokens(_ command: String) -> [ShellToken] {
        var tokens: [ShellToken] = []
        var index = command.startIndex
        while index < command.endIndex {
            while index < command.endIndex, command[index].isWhitespace { index = command.index(after: index) }
            guard index < command.endIndex else { break }
            var value = ""
            var quote: Character?
            while index < command.endIndex {
                let character = command[index]
                if let activeQuote = quote {
                    if character == activeQuote {
                        selfAdvance(&index, in: command)
                        quote = nil
                    } else if character == "\\", activeQuote == "\"" {
                        selfAdvance(&index, in: command)
                        if index < command.endIndex {
                            value.append(command[index])
                            selfAdvance(&index, in: command)
                        }
                    } else {
                        value.append(character)
                        selfAdvance(&index, in: command)
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                    selfAdvance(&index, in: command)
                } else if character == "\\" {
                    selfAdvance(&index, in: command)
                    if index < command.endIndex {
                        value.append(command[index])
                        selfAdvance(&index, in: command)
                    }
                } else if character.isWhitespace {
                    break
                } else {
                    value.append(character)
                    selfAdvance(&index, in: command)
                }
            }
            tokens.append(.init(value: value))
        }
        return tokens
    }

    private static func selfAdvance(_ index: inout String.Index, in command: String) {
        index = command.index(after: index)
    }

    private static func stringValue(_ args: [String: Any], keys: [String], fallbackJSON: String? = nil) -> String? {
        for key in keys {
            if let raw = args[key] as? String, !raw.isEmpty { return raw }
        }
        for key in keys {
            if let recovered = recoverStringValue(from: fallbackJSON, key: key), !recovered.isEmpty { return recovered }
        }
        return nil
    }

    private static func readRange(_ args: [String: Any]) -> String? {
        let offset = (args["offset"] as? Int) ?? (args["start"] as? Int)
        let limit = (args["limit"] as? Int) ?? (args["count"] as? Int)
        switch (offset, limit) {
        case let (offset?, limit?):
            return "L\(offset)–L\(offset + limit - 1)"
        case let (offset?, nil):
            return "from L\(offset)"
        case let (nil, limit?):
            return "first \(limit) lines"
        default:
            return nil
        }
    }

    static func summarizeReadResult(_ result: String) -> String {
        let lines = result.split(whereSeparator: \.isNewline).count
        let bytes = result.utf8.count
        return "\(lines) lines · \(formatBytes(bytes))"
    }

    private static func formatBytes(_ count: Int) -> String {
        if count >= 1024 * 1024 { return String(format: "%.1fMB", Double(count) / 1024.0 / 1024.0) }
        if count >= 1024 { return String(format: "%.1fKB", Double(count) / 1024.0) }
        return "\(count)B"
    }

    private static func editChanges(_ args: [String: Any], fallbackJSON: String? = nil) -> [PickyToolHistoryEditChange] {
        if let edits = args["edits"] as? [[String: Any]], !edits.isEmpty {
            let changes = edits.compactMap { change(from: $0) }
            if !changes.isEmpty { return changes }
        }
        if let single = change(from: args) { return [single] }
        if let recovered = recoveredChange(from: fallbackJSON) { return [recovered] }
        return []
    }

    private static func recoveredChange(from json: String?) -> PickyToolHistoryEditChange? {
        let oldKeys = ["oldText", "old_string", "oldString", "old"]
        let newKeys = ["newText", "new_string", "newString", "new"]
        let oldText = oldKeys.compactMap { recoverStringValue(from: json, key: $0) }.first(where: { !$0.isEmpty })
        let newText = newKeys.compactMap { recoverStringValue(from: json, key: $0) }.first(where: { !$0.isEmpty })
        guard oldText != nil || newText != nil else { return nil }
        return PickyToolHistoryEditChange(oldText: oldText ?? "", newText: newText ?? "")
    }

    private static func change(from raw: [String: Any]) -> PickyToolHistoryEditChange? {
        let oldKeys = ["oldText", "old_string", "oldString", "old"]
        let newKeys = ["newText", "new_string", "newString", "new"]
        let oldText = oldKeys.compactMap { raw[$0] as? String }.first(where: { !$0.isEmpty })
        let newText = newKeys.compactMap { raw[$0] as? String }.first(where: { !$0.isEmpty })
        guard oldText != nil || newText != nil else { return nil }
        return PickyToolHistoryEditChange(oldText: oldText ?? "", newText: newText ?? "")
    }

    static func prettyJSON(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }
}

struct PickyToolHistorySummary: Equatable {
    let total: Int
    let counts: [PickyToolHistoryCategory: Int]
    let totalDurationMs: Int

    init(entries: [PickyToolHistoryEntry]) {
        var counts: [PickyToolHistoryCategory: Int] = [:]
        var duration = 0
        for entry in entries {
            counts[entry.category, default: 0] += 1
            duration += entry.durationMs ?? 0
        }
        self.total = entries.count
        self.counts = counts
        self.totalDurationMs = duration
    }

    func count(of category: PickyToolHistoryCategory) -> Int { counts[category] ?? 0 }
}
