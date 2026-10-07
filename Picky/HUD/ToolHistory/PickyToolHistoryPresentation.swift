import AppKit

/// Compact history content derived from saved arguments, never their preview.
enum PickyToolHistoryPresentation {
    enum Detail: Equatable {
        case edit(file: String?, changes: [PickyToolHistoryEditChange])
        case write(file: String?, content: String)
        case todo(items: [PickyToolHistoryTodoItem], isSnapshot: Bool)
        case ask(questions: [Question], state: AnswerState)
    }

    struct Question: Equatable {
        let prompt: String
        let answers: [String]?
        let type: String
    }

    enum AnswerState: Equatable {
        case answered, awaiting, cancelled, unavailable
    }

    /// Short label for the row's name column. MCP tools drop the `mcp__<server>__`
    /// prefix the same way the inline tool row does; the server moves to `context`.
    static func displayName(for entry: PickyToolHistoryEntry) -> String {
        switch entry.name.lowercased() {
        case "ask_user_question": return "ask"
        case "todo_write", "todowrite": return "todo"
        default: return mcpParts(entry.name)?.tool ?? entry.name
        }
    }

    /// Dimmed secondary text after the title: the parent folder for file tools,
    /// the server for MCP tools. `nil` when there is nothing that disambiguates.
    static func context(for entry: PickyToolHistoryEntry) -> String? {
        switch entry.detail {
        case let .read(file, _), let .edit(file, _), let .write(file, _):
            guard let file, !file.isEmpty else { return nil }
            let parent = (file as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != "." else { return nil }
            return (parent as NSString).abbreviatingWithTildeInPath
        default:
            return mcpParts(entry.name)?.server
        }
    }

    /// Compact elapsed time for the row's trailing column, e.g. `0.8s`, `12s`, `2m 05s`.
    static func durationText(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds >= 0 else { return nil }
        if milliseconds < 10_000 {
            return String(format: "%.1fs", Double(milliseconds) / 1000)
        }
        let seconds = milliseconds / 1000
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }

    /// One name column per list: as wide as the longest visible name, capped so a
    /// long MCP tool name truncates instead of squeezing the title.
    static func nameColumnWidth(for names: [String], fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let minimum = ("bash" as NSString).size(withAttributes: [.font: font]).width
        let maximum = (String(repeating: "m", count: 15) as NSString).size(withAttributes: [.font: font]).width
        return ceil(min(maximum, max(minimum, widest)))
    }

    struct BashOutput: Equatable {
        let body: String
        let exitCode: Int?
    }

    /// Pi's bash tool appends `Command exited with code N` to the merged
    /// stdout/stderr. The status line becomes a header; the rest stays the body.
    static func bashOutput(_ text: String) -> BashOutput {
        let unchanged = BashOutput(body: text, exitCode: nil)
        guard let range = text.range(of: "Command exited with code ", options: .backwards),
              range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == "\n",
              let code = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return unchanged }
        var body = text[..<range.lowerBound]
        while let last = body.last, last.isWhitespace { body = body.dropLast() }
        return BashOutput(body: String(body), exitCode: code)
    }

    /// Tools a codemode script calls, in first-use order (`tools.read(...)`).
    /// Reads the script text only; it does not claim how many calls ran.
    static func codemodeToolNames(argsJSON: String?) -> [String] {
        guard let argsJSON else { return [] }
        let code = object(argsJSON).flatMap { string($0, keys: ["code"]) } ?? argsJSON
        guard let regex = try? NSRegularExpression(pattern: #"\btools\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#) else { return [] }
        var names: [String] = []
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range(at: 1), in: code) else { continue }
            let raw = String(code[range])
            let name = mcpParts(raw)?.tool ?? raw
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func mcpParts(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2, let tool = parts.last, !tool.isEmpty, !parts[0].isEmpty else { return nil }
        return (parts[0], tool)
    }

    static func title(for entry: PickyToolHistoryEntry) -> String {
        switch entry.detail {
        case let .read(file, _), let .edit(file, _), let .write(file, _):
            guard let file, !file.isEmpty else { return entry.name }
            return (file as NSString).lastPathComponent
        case let .bash(command, title):
            return [title, command].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? entry.name
        case .todo:
            return L10n.t("hud.toolHistory.todo.updated")
        case let .subagent(_, agents, task):
            return task ?? (agents.isEmpty ? entry.name : agents.joined(separator: ", "))
        case let .generic(argsJSON):
            if entry.name.lowercased() == "ask_user_question", let args = object(argsJSON) {
                if let title = string(args, keys: ["title"]), !title.isEmpty { return title }
                if let questions = array(args["questions"]) as? [[String: Any]],
                   let first = questions.first, let prompt = string(first, keys: ["prompt", "question"]) {
                    return prompt
                }
            }
            if entry.name.lowercased() == "codemode" {
                let tools = codemodeToolNames(argsJSON: argsJSON)
                guard !tools.isEmpty else { return entry.name }
                let shown = tools.prefix(3).joined(separator: " · ")
                let list = tools.count > 3 ? "\(shown) +\(tools.count - 3)" : shown
                return L10n.t("hud.toolHistory.codemode.calls", list)
            }
            // Registered tools have a known argument meaning; unknown tools
            // keep their name so a free-form argument is never promoted to a label.
            return PickyToolDescriptorRegistry.descriptor(forToolNamed: entry.name, argsJSON: argsJSON)?.summary ?? entry.name
        }
    }

    static func detail(for entry: PickyToolHistoryEntry, arguments: String?, structuredResult: String?) -> Detail? {
        guard let args = object(arguments) else { return nil }
        let file = string(args, keys: ["path", "file", "file_path", "filePath"])
        switch entry.name.lowercased() {
        case "edit", "multiedit":
            let edits: [[String: Any]]
            if let raw = args["edits"] {
                guard let list = raw as? [[String: Any]], !list.isEmpty else { return nil }
                edits = list
            } else {
                edits = [args]
            }
            var changes: [PickyToolHistoryEditChange] = []
            for edit in edits {
                guard let old = string(edit, keys: ["oldText", "old_string", "oldString", "old"]),
                      let new = string(edit, keys: ["newText", "new_string", "newString", "new"])
                else { return nil }
                changes.append(.init(oldText: old, newText: new))
            }
            return .edit(file: file, changes: changes)
        case "write":
            guard let content = string(args, keys: ["content", "text", "body"]) else { return nil }
            return .write(file: file, content: content)
        case "todo_write", "todowrite":
            // Reject malformed patch fields rather than letting the preview renderer omit them.
            if args["todos"] == nil {
                for key in ["set", "add"] where args[key] != nil {
                    guard args[key] is [[String: Any]] else { return nil }
                }
                if args["remove"] != nil, !(args["remove"] is [String]) { return nil }
            } else if !(args["todos"] is [[String: Any]]) {
                return nil
            }
            let rebuilt = PickyToolHistoryRenderer.entry(from: .init(
                toolCallId: entry.id, name: entry.name, status: "succeeded",
                argsPreview: arguments
            ), index: entry.index)
            guard case let .todo(_, items) = rebuilt.detail else { return nil }
            let isSnapshot = args["todos"] != nil
            let visibleItems = isSnapshot ? items : items.map { item in
                guard [.done, .active, .pending].contains(item.marker) else { return item }
                let suffixes = [" → completed", " → in_progress", " → pending"]
                let suffix = suffixes.first(where: { item.text.hasSuffix($0) })
                return PickyToolHistoryTodoItem(marker: item.marker,
                    text: suffix.map { String(item.text.dropLast($0.count)) } ?? item.text)
            }
            return .todo(items: visibleItems, isSnapshot: isSnapshot)
        case "ask_user_question":
            return ask(args: args, status: entry.status, result: object(structuredResult))
        default:
            return nil
        }
    }

    private static func ask(args: [String: Any], status: PickyToolHistoryStatus, result: [String: Any]?) -> Detail? {
        guard let rawQuestions = array(args["questions"]) as? [[String: Any]], !rawQuestions.isEmpty else { return nil }
        let cancelled = result?["cancelled"] as? Bool == true
        let values = result?["value"] as? [String: Any]
        let state: AnswerState = cancelled ? .cancelled
            : status == .running ? .awaiting
            : result?["cancelled"] as? Bool == false && values != nil ? .answered : .unavailable
        var questions: [Question] = []
        for (index, raw) in rawQuestions.enumerated() {
            guard let type = raw["type"] as? String, ["radio", "checkbox", "text"].contains(type),
                  let prompt = string(raw, keys: ["prompt", "question", "label"])
            else { return nil }
            let suppliedID = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = suppliedID.flatMap { $0.isEmpty ? nil : $0 } ?? "q\(index + 1)"
            var labels: [String: String] = [:]
            if let rawOptions = raw["options"] {
                guard let options = array(rawOptions) else { return nil }
                for option in options {
                    if let text = option as? String {
                        if labels[text] == nil { labels[text] = text }
                    } else if let option = option as? [String: Any],
                              let value = option["value"] as? String, let label = option["label"] as? String {
                        if labels[value] == nil { labels[value] = label }
                    } else { return nil }
                }
            }
            let answers: [String]?
            if state == .answered, let value = values?[id] {
                if let text = value as? String {
                    answers = [type == "text" ? text : labels[text] ?? text]
                } else if let selections = value as? [String] {
                    answers = selections.map { type == "text" ? $0 : labels[$0] ?? $0 }
                } else {
                    answers = nil
                }
            } else {
                answers = nil
            }
            questions.append(.init(prompt: prompt, answers: answers, type: type))
        }
        return .ask(questions: questions, state: state)
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        keys.compactMap { object[$0] as? String }.first
    }

    private static func object(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any]? {
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        }
        return value as? [Any]
    }
}
