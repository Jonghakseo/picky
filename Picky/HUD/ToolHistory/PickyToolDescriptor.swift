//
//  PickyToolDescriptor.swift
//  Picky
//
//  Per-tool display rules for tools that have no structured
//  `PickyToolHistoryDetail` case (bash_async, grep, web_search, MCP, ...).
//  Each descriptor reads the neutral call arguments and picks the one value a
//  user would scan for, so the inline tool row never falls back to the first
//  line of pretty-printed JSON (`{`).
//

import Foundation

struct PickyToolDescriptor: Equatable {
    enum Glyph: Equatable {
        case shell, search, web, memory
    }

    /// Short tool label for the row's name column.
    let displayName: String
    /// Optional icon family. `nil` keeps the category default.
    let glyph: Glyph?
    /// One-line argument summary, or `nil` when the arguments carry nothing
    /// worth showing.
    let summary: String?
}

enum PickyToolDescriptorRegistry {
    /// Returns a descriptor for a registered tool, or `nil` for unknown tools.
    static func descriptor(forToolNamed name: String, argsJSON: String?) -> PickyToolDescriptor? {
        let args = Arguments(json: argsJSON)
        let lowered = name.lowercased()
        if let mcp = mcpDescriptor(name: name, args: args) { return mcp }
        switch lowered {
        case "bash_async":
            return .init(displayName: name, glyph: .shell, summary: bashAsyncSummary(args))
        case "grep", "find":
            return .init(displayName: name, glyph: .search, summary: patternSummary(args))
        case "ls":
            return .init(displayName: name, glyph: .search, summary: args.string("path") ?? ".")
        case "web_search":
            return .init(displayName: name, glyph: .web, summary: listSummary(args, single: "query", list: "queries"))
        case "fetch_content":
            let url = listSummary(args, single: "url", list: "urls")
            return .init(displayName: name, glyph: .web, summary: url.map(stripScheme))
        case "get_search_content":
            let value = args.string("query") ?? args.string("url").map(stripScheme) ?? args.string("responseId")
            return .init(displayName: name, glyph: .web, summary: value)
        case "recall", "memory_recall":
            return .init(displayName: name, glyph: .memory, summary: args.string("query") ?? args.string("id"))
        case "vcc_recall", "session_recall":
            let expand = args.stringList("expand").map { $0.joined(separator: ", ") }
            return .init(displayName: name, glyph: .memory, summary: args.string("query") ?? expand ?? args.string("mode"))
        case "remember", "memory_remember":
            return .init(displayName: name, glyph: .memory, summary: args.string("title") ?? args.string("content"))
        case "forget", "memory_forget":
            return .init(displayName: name, glyph: .memory, summary: args.string("id"))
        case "subagent":
            // Structured subagent commands are parsed upstream; this covers
            // the remaining forms (`subagent help`, unrecognized flags).
            let command = args.string("command").map { stripPrefix("subagent", from: $0) }
            return .init(displayName: name, glyph: nil, summary: command)
        case "cron":
            let command = args.string("command").map { stripPrefix("cron", from: $0) }
            return .init(displayName: name, glyph: nil, summary: command)
        case "delay":
            let parts = [args.string("delay"), args.string("prompt")].compactMap { $0 }
            return .init(displayName: name, glyph: nil, summary: parts.isEmpty ? nil : parts.joined(separator: " · "))
        case "ask_user_question":
            let prompt = args.objectList("questions")?.first.flatMap { question in
                ["prompt", "question", "label"].lazy.compactMap { firstLine(question[$0] as? String) }.first
            }
            return .init(displayName: name, glyph: nil, summary: args.string("title") ?? prompt)
        case "show_widget":
            return .init(displayName: name, glyph: nil, summary: args.string("title"))
        case "todo_write", "todowrite":
            return .init(displayName: "todo", glyph: nil, summary: args.string("op"))
        default:
            return nil
        }
    }

    /// Neutral fallback for unknown tools: the first scalar argument rendered
    /// as `key: value`. It never promotes a free-form argument such as
    /// `title` to a label the tool did not declare.
    static func genericSummary(argsJSON: String?) -> String? {
        let args = Arguments(json: argsJSON)
        guard let object = args.object else { return nil }
        for key in orderedKeys(object) {
            if let value = scalarText(object[key]) { return "\(key): \(value)" }
        }
        return nil
    }

    /// Identifier-like arguments first, then the rest alphabetically, so
    /// `{"fields":"summary","issue_key":"COM-1"}` surfaces the issue key.
    private static let identifyingKeys = [
        "issue_key", "key", "query", "jql", "url", "path", "pageId", "recordId",
        "eventId", "channelId", "threadTs", "tableId", "datasetId", "baseId", "id", "name",
    ]

    private static func orderedKeys(_ object: [String: Any]) -> [String] {
        let preferred = identifyingKeys.filter { object[$0] != nil }
        let rest = object.keys.filter { !identifyingKeys.contains($0) }.sorted()
        return preferred + rest
    }

    // MARK: - Tool-specific summaries

    private static func bashAsyncSummary(_ args: Arguments) -> String? {
        let action = args.string("action") ?? "start"
        if action == "start" {
            return args.string("title") ?? args.string("command")
        }
        if let jobId = args.string("jobId") {
            return "\(action) · \(jobId)"
        }
        return action
    }

    private static func patternSummary(_ args: Arguments) -> String? {
        let pattern = args.string("pattern") ?? args.string("query") ?? args.string("glob")
        let path = args.string("path")
        switch (pattern, path) {
        case let (pattern?, path?) where path != ".": return "\(pattern) in \(path)"
        case let (pattern?, _): return pattern
        case let (nil, path?): return path
        default: return nil
        }
    }

    private static func listSummary(_ args: Arguments, single: String, list: String) -> String? {
        if let value = args.string(single) { return value }
        guard let values = args.stringList(list), let first = values.first else { return nil }
        return values.count > 1 ? "\(first) +\(values.count - 1)" : first
    }

    /// `mcp__<server>__<tool>`: shows the tool part as the name and the
    /// first scalar argument as the summary.
    private static func mcpDescriptor(name: String, args: Arguments) -> PickyToolDescriptor? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2, let tool = parts.last, !tool.isEmpty else { return nil }
        let summary = args.object.flatMap { object in
            orderedKeys(object).lazy.compactMap { scalarText(object[$0]) }.first
        } ?? args.firstRecoverableValue()
        return .init(displayName: tool, glyph: nil, summary: summary)
    }

    // MARK: - Helpers

    private static func stripScheme(_ url: String) -> String {
        guard let range = url.range(of: "://") else { return url }
        return String(url[range.upperBound...])
    }

    private static func stripPrefix(_ prefix: String, from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix + " ") else { return trimmed }
        return String(trimmed.dropFirst(prefix.count + 1))
    }

    fileprivate static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    private static func scalarText(_ value: Any?) -> String? {
        switch value {
        case let text as String: return firstLine(text)
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// Argument accessor that works on complete JSON and falls back to regex
    /// recovery when the preview was truncated mid-payload.
    private struct Arguments {
        let json: String?
        let object: [String: Any]?

        init(json: String?) {
            self.json = json
            let parsed = PickyToolHistoryRenderer.parseArgs(json)
            self.object = parsed.isEmpty ? nil : parsed
        }

        func string(_ key: String) -> String? {
            if let object {
                return PickyToolDescriptorRegistry.firstLine(object[key] as? String)
            }
            return PickyToolDescriptorRegistry.firstLine(PickyToolHistoryRenderer.recoverStringValue(from: json, key: key))
        }

        func stringList(_ key: String) -> [String]? {
            guard let raw = object?[key] else { return nil }
            let values = (raw as? [Any])?.compactMap { PickyToolDescriptorRegistry.firstLine($0 as? String) }
            return values?.isEmpty == false ? values : nil
        }

        func objectList(_ key: String) -> [[String: Any]]? {
            if let list = object?[key] as? [[String: Any]] { return list }
            // Some tools pass nested arrays as a JSON string.
            guard let text = object?[key] as? String, let data = text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        }

        /// First `"key":"value"` string pair in a truncated payload.
        func firstRecoverableValue() -> String? {
            guard object == nil, let json,
                  let regex = try? NSRegularExpression(pattern: #""[^"]+"\s*:\s*"((?:\\.|[^"])+)"#),
                  let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
                  let range = Range(match.range(at: 1), in: json)
            else { return nil }
            return PickyToolDescriptorRegistry.firstLine(String(json[range]))
        }
    }
}
