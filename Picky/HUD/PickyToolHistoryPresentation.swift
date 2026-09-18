import Foundation

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
            return entry.name
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
