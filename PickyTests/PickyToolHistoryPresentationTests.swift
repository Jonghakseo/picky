import AppKit
import Testing
@testable import Picky

struct PickyToolHistoryPresentationTests {
    private typealias Presentation = PickyToolHistoryPresentation

    @Test func questionAnswersPreserveSelectionsAndFreeTextExactly() throws {
        let arguments = try json(["questions": [
            ["id": " choices ", "type": "checkbox", "question": "Choose", "options": [
                ["value": "a,b", "label": "First, second"], ["value": "c", "label": "Third"]
            ]],
            ["type": "text", "prompt": "Explain", "options": ["a,b"]],
            ["id": "empty", "type": "checkbox", "prompt": "Optional"],
            ["id": "missing", "type": "text", "prompt": "Missing"]
        ]])
        let result = try json(["cancelled": false, "value": [
            "choices": ["a,b", "c", "Other, exact"], "q2": "  a,b\nline | two  ", "empty": []
        ]])
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: arguments, structuredResult: result) == .ask(questions: [
            .init(prompt: "Choose", answers: ["First, second", "Third", "Other, exact"], type: "checkbox"),
            .init(prompt: "Explain", answers: ["  a,b\nline | two  "], type: "text"),
            .init(prompt: "Optional", answers: [], type: "checkbox"),
            .init(prompt: "Missing", answers: nil, type: "text")
        ], state: .answered))
    }

    @Test func serializedQuestionsAndOptionsUseRuntimeDefaultIDs() throws {
        let options = try json([["value": "one", "label": "One label"]])
        let questions = try json([["id": "  ", "type": "radio", "prompt": "Pick", "options": options]])
        let args = try json(["questions": questions])
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: args,
            structuredResult: #"{"cancelled":false,"value":{"q1":"one"}}"#) == .ask(
                questions: [.init(prompt: "Pick", answers: ["One label"], type: "radio")], state: .answered))
    }

    @Test func cancellationFailureAndAwaitingRemainDistinct() {
        let args = #"{"questions":[{"type":"text","prompt":"Why?"}]}"#
        let questions: [Presentation.Question] = [.init(prompt: "Why?", answers: nil, type: "text")]
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: args,
            structuredResult: #"{"cancelled":true}"#) == .ask(questions: questions, state: .cancelled))
        #expect(Presentation.detail(for: entry("ask_user_question", status: "failed"), arguments: args,
            structuredResult: nil) == .ask(questions: questions, state: .unavailable))
        #expect(Presentation.detail(for: entry("ask_user_question", status: "running"), arguments: args,
            structuredResult: nil) == .ask(questions: questions, state: .awaiting))
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: args,
            structuredResult: nil) == .ask(questions: questions, state: .unavailable))
    }

    @Test func missingOrMalformedOriginalsNeverFallBackToPreviews() {
        let preview = #"{"path":"file","content":"preview"}"#
        for arguments in [nil, "{", "[]", "{}"] as [String?] {
            #expect(Presentation.detail(for: entry("write", preview: preview), arguments: arguments, structuredResult: nil) == nil)
        }
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: nil,
            structuredResult: #"{"cancelled":false,"value":{"q1":"answer"}}"#) == nil)
        #expect(Presentation.detail(for: entry("unknown"), arguments: preview, structuredResult: nil) == nil)
        #expect(Presentation.detail(for: entry("edit"), arguments: #"{"oldText":"old"}"#, structuredResult: nil) == nil)
        #expect(Presentation.detail(for: entry("ask_user_question"), arguments: #"{"questions":"not JSON"}"#, structuredResult: nil) == nil)
    }

    @Test func editsAndWritesUseFullOriginalContentIncludingEmptyReplacements() throws {
        let original = String(repeating: "long original\n", count: 200)
        let write = try json(["path": "src/file.swift", "content": original])
        #expect(Presentation.detail(for: entry("write", preview: #"{"content":"short"}"#), arguments: write,
            structuredResult: nil) == .write(file: "src/file.swift", content: original))
        let edit = try json(["path": "src/file.swift", "edits": [["oldText": original, "newText": ""]]])
        #expect(Presentation.detail(for: entry("edit", preview: #"{"oldText":"short"}"#), arguments: edit,
            structuredResult: nil) == .edit(file: "src/file.swift", changes: [.init(oldText: original, newText: "")]))
        #expect(Presentation.detail(for: entry("write"), arguments: #"{"content":""}"#,
            structuredResult: nil) == .write(file: nil, content: ""))
    }

    @Test func todoPatchShowsOnlyRecordedChangesNotAnInferredList() {
        let patch = #"{"op":"patch","set":[{"id":"task-7","status":"completed"}],"add":[{"content":"New task"}],"remove":["task-2"]}"#
        #expect(Presentation.detail(for: entry("todo_write"), arguments: patch, structuredResult: nil) == .todo(items: [
            .init(marker: .done, text: "task-7"),
            .init(marker: .added, text: "New task"),
            .init(marker: .removed, text: "task-2")
        ], isSnapshot: false))
        #expect(Presentation.detail(for: entry("todo_write"), arguments: #"{"todos":[]}"#,
            structuredResult: nil) == .todo(items: [], isSnapshot: true))
        #expect(Presentation.detail(for: entry("todo_write"), arguments: #"{"op":"patch","set":"invalid","add":[{"content":"New"}]}"#,
            structuredResult: nil) == nil)
    }

    @Test func titlesUseNeutralArgumentsWithoutInventingIntent() {
        #expect(Presentation.title(for: entry("read", preview: #"{"path":"src/File.swift"}"#)) == "File.swift")
        #expect(Presentation.title(for: entry("bash", preview: #"{"command":"git status","title":"Check files"}"#)) == "Check files")
        #expect(Presentation.title(for: entry("bash", preview: #"{"command":"git status"}"#)) == "git status")
        #expect(Presentation.title(for: entry("custom_tool", preview: #"{"title":"Invented label"}"#)) == "custom_tool")
        #expect(Presentation.title(for: entry("bash_async", preview: #"{"action":"start","command":"pnpm test"}"#)) == "pnpm test")
        #expect(Presentation.title(for: entry("grep", preview: #"{"pattern":"TODO","path":"src"}"#)) == "TODO in src")
        #expect(Presentation.title(for: entry("edit")) == "edit")
        #expect(Presentation.title(for: entry("ask_user_question", preview: #"{"title":"Choose layout"}"#)) == "Choose layout")
        #expect(Presentation.title(for: entry("ask_user_question", preview: #"{"questions":[{"prompt":"Which layout?"}]}"#)) == "Which layout?")
    }

    @Test func rowLabelsKeepToolNamesShortAndMoveDisambiguationToContext() {
        let mcp = entry("mcp__creatrip__jira_getIssue", preview: #"{"issue_key":"COM-2605"}"#)
        #expect(Presentation.displayName(for: mcp) == "jira_getIssue")
        #expect(Presentation.title(for: mcp) == "COM-2605")
        #expect(Presentation.context(for: mcp) == "creatrip")

        let read = entry("read", preview: #"{"path":"frontend/apps/admin/src/page/Settlements.tsx"}"#)
        #expect(Presentation.title(for: read) == "Settlements.tsx")
        #expect(Presentation.context(for: read) == "frontend/apps/admin/src/page")
        #expect(Presentation.context(for: entry("read", preview: #"{"path":"AGENTS.md"}"#)) == nil)
        #expect(Presentation.displayName(for: entry("todo_write")) == "todo")
    }

    @MainActor @Test func codemodeTitleNamesCalledToolsInsteadOfRepeatingItsName() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let code = "const a = await tools.bash({command: 'ls'}); await tools.read({path}); "
                + "await tools.bash({command: 'pwd'}); await tools.mcp__creatrip__jira_getIssue({issue_key: 'X'})"
            let args = try json(["code": code])
            #expect(Presentation.title(for: entry("codemode", preview: args)) == "Calls bash \u{00B7} read \u{00B7} jira_getIssue")
            #expect(Presentation.title(for: entry("codemode", preview: try json(["code": "return 1"]))) == "codemode")
        }
    }

    @Test func bashExitStatusSeparatesFromMergedOutput() {
        let output = Presentation.bashOutput("a.ts\nlsof: no process\n\nCommand exited with code 1\n")
        #expect(output == .init(body: "a.ts\nlsof: no process", exitCode: 1))
        let plain = "echo Command exited with code 1 later\nok"
        #expect(Presentation.bashOutput(plain) == .init(body: plain, exitCode: nil))
    }

    @Test func nameColumnFitsCommonNamesOnOneLineButCapsLongOnes() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let fitted = Presentation.nameColumnWidth(for: ["bash", "codemode", "jira_getIssue"], fontSize: 12)
        #expect(fitted >= width("jira_getIssue"))
        let capped = Presentation.nameColumnWidth(for: ["notion_search_pages_by_title"], fontSize: 12)
        #expect(capped < width("notion_search_pages_by_title"))
        #expect(capped >= fitted)
    }

    @Test func durationTextStaysCompact() {
        #expect(Presentation.durationText(milliseconds: nil) == nil)
        #expect(Presentation.durationText(milliseconds: 840) == "0.8s")
        #expect(Presentation.durationText(milliseconds: 12_400) == "12s")
        #expect(Presentation.durationText(milliseconds: 125_000) == "2m 05s")
    }

    private func entry(_ name: String, status: String = "succeeded", preview: String? = nil) -> PickyToolHistoryEntry {
        PickyToolHistoryRenderer.entry(from: .init(toolCallId: "call", name: name, status: status,
            argsPreview: preview, resultPreview: "User response: lossy, Markdown"), index: 1)
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
