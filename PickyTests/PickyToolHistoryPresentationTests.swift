import Foundation
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
        #expect(Presentation.title(for: entry("edit")) == "edit")
        #expect(Presentation.title(for: entry("ask_user_question", preview: #"{"title":"Choose layout"}"#)) == "Choose layout")
        #expect(Presentation.title(for: entry("ask_user_question", preview: #"{"questions":[{"prompt":"Which layout?"}]}"#)) == "Which layout?")
    }

    private func entry(_ name: String, status: String = "succeeded", preview: String? = nil) -> PickyToolHistoryEntry {
        PickyToolHistoryRenderer.entry(from: .init(toolCallId: "call", name: name, status: status,
            argsPreview: preview, resultPreview: "User response: lossy, Markdown"), index: 1)
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
