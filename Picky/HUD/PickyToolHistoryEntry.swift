//
//  PickyToolHistoryEntry.swift
//  Picky
//
//  Pure Swift conversion from PickyToolActivity into a structured entry the
//  Tool History viewer can render. Kept free of SwiftUI so it stays testable.
//

import Foundation

enum PickyToolHistoryCategory: String, Equatable {
    case read, bash, edit, write, other
}

enum PickyToolHistoryStatus: String, Equatable {
    case running, succeeded, failed
}

struct PickyToolHistoryEditChange: Equatable {
    let oldText: String
    let newText: String
}

enum PickyToolHistoryDetail: Equatable {
    case read(file: String?, range: String?, resultSummary: String?)
    case bash(command: String?, output: String?)
    case edit(file: String?, changes: [PickyToolHistoryEditChange])
    case write(file: String?, content: String?)
    case generic(argsJSON: String?, result: String?)
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
        let result = tool.resultPreview ?? (status != .running ? tool.preview : nil)
        let detail = detail(for: category, argsJSON: argsJSON, result: result)
        return PickyToolHistoryEntry(
            id: tool.toolCallId,
            index: index,
            name: tool.name,
            category: category,
            status: status,
            durationMs: durationMs(start: tool.startedAt, end: tool.endedAt),
            startedAt: tool.startedAt,
            detail: detail
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

    private static func detail(for category: PickyToolHistoryCategory, argsJSON: String?, result: String?) -> PickyToolHistoryDetail {
        let args = parseArgs(argsJSON)
        switch category {
        case .read:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"])
            let range = readRange(args)
            let resultSummary = result.map { summarizeReadResult($0) }
            return .read(file: file, range: range, resultSummary: resultSummary)
        case .bash:
            let command = stringValue(args, keys: ["command", "cmd", "script"]) ?? recoverStringValue(from: argsJSON, key: "command")
            return .bash(command: command, output: result)
        case .edit:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"])
            return .edit(file: file, changes: editChanges(args))
        case .write:
            let file = stringValue(args, keys: ["path", "file", "file_path", "filePath"])
            let content = stringValue(args, keys: ["content", "text", "body"])
            return .write(file: file, content: content)
        case .other:
            return .generic(argsJSON: prettyJSON(argsJSON) ?? argsJSON, result: result)
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
        let unescaped = raw
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\\\""#, with: "\"")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
        return unescaped.isEmpty ? nil : unescaped
    }

    private static func stringValue(_ args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let raw = args[key] as? String, !raw.isEmpty { return raw }
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

    private static func summarizeReadResult(_ result: String) -> String {
        let lines = result.split(whereSeparator: \.isNewline).count
        let bytes = result.utf8.count
        return "\(lines) lines · \(formatBytes(bytes))"
    }

    private static func formatBytes(_ count: Int) -> String {
        if count >= 1024 * 1024 { return String(format: "%.1fMB", Double(count) / 1024.0 / 1024.0) }
        if count >= 1024 { return String(format: "%.1fKB", Double(count) / 1024.0) }
        return "\(count)B"
    }

    private static func editChanges(_ args: [String: Any]) -> [PickyToolHistoryEditChange] {
        if let edits = args["edits"] as? [[String: Any]], !edits.isEmpty {
            return edits.compactMap { change(from: $0) }
        }
        if let single = change(from: args) { return [single] }
        return []
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
